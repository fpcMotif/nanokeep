# Plan 002: `run.capture` reports a killed child and a failed read as errors

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/run.zig`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. On a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-pin-zig-toolchain.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-10
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/4

## Why this matters

`run.capture` runs every child process in nanokeep, including `git status`
(which decides whether a worktree may be removed) and `/bin/rm -rf` (which
empties the Trash). Today a child killed by a signal is reported as exit code 0,
and a failed or interrupted `read` is treated as the end of output. A killed
`git status` therefore looks like "clean, no output", and the worktree is
offered for deletion. After this plan, both cases return an error, and every
caller already treats an error as failure.

## Current state

- `src/run.zig` is the only process runner. The body of `capture` after the spawn (lines 53-65):

  ```zig
      var out: std.ArrayList(u8) = .empty;
      errdefer out.deinit(gpa);
      var buf: [read_chunk]u8 = undefined;
      while (true) {
          const n = read(fds[0], &buf, buf.len);
          if (n <= 0) break;
          try out.appendSlice(gpa, buf[0..@intCast(n)]);
      }
      _ = close(fds[0]);
      var status: c_int = 0;
      _ = waitpid(pid, &status, 0);
      return .{ .out = try out.toOwnedSlice(gpa), .code = std.c.W.EXITSTATUS(@bitCast(status)) };
  }
  ```

  The externs `read`, `close` and `waitpid` are declared at lines 4-6 of the same file.
- Problems in that excerpt:
  - `n <= 0` treats `-1` (an error, including `EINTR`) as end of output.
  - `EXITSTATUS` is used without checking that the child exited. For a child killed by signal 9, it returns 0.
  - `waitpid` is not retried on `EINTR`.
  - When `appendSlice` fails, the function returns without closing the pipe or reaping the child.
- Callers, all of which already map an error to failure. You do not change them:
  - `src/worktree.zig:90` `isClean`: `catch return false`
  - `src/worktree.zig:116` `find`: `catch continue`
  - `src/worktree.zig:140` `remove`: `catch return false`
  - `src/cleaner.zig:283` `perform`: `catch null`, then counted as failed
  - `src/machine.zig:162`: `catch break :found false`
  - `src/bench.zig:288`: `try`
- Available in Zig 0.17 `std.c`: `std.c.W.IFEXITED(status: u32) bool`,
  `std.c.W.EXITSTATUS(status: u32) u8`, and `std.c.errno(rc) std.c.E`, which
  returns `.INTR` for `EINTR` when `rc == -1`.
- The existing test (`src/tests.zig:443-451`), which you extend and use as the pattern:

  ```zig
  test "run captures a child's output and exit code" {
      const ok = try run.capture(gpa, &.{ "/bin/echo", "hello" });
      defer ok.deinit(gpa);
      try std.testing.expectEqualStrings("hello\n", ok.out);
      try std.testing.expectEqual(@as(u8, 0), ok.code);
      const bad = try run.capture(gpa, &.{ "/bin/sh", "-c", "exit 3" });
      defer bad.deinit(gpa);
      try std.testing.expectEqual(@as(u8, 3), bad.code);
  }
  ```

- Conventions: all tests live in `src/tests.zig`. A test name is a sentence that
  states the behavior. `gpa` in tests is `std.testing.allocator`, which fails a test that leaks.
  The code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | ends with `N/N tests passed` |
| These tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="run "` | all pass |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/run.zig`
- `src/tests.zig` (add tests only)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- The callers listed above. Their `catch` handling is already correct.
- The `envp`, the spawn file actions and the `Output` struct in `src/run.zig`.
- Timeouts or cancellation for child processes. That is a separate finding.
- Do not run `zig fmt` on whole files. `src/tests.zig` already differs from
  `zig fmt` output, and formatting it creates an unrelated diff.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/002-run-capture-errors`
- Conventional commits. Use: `fix(run): report a signalled child and a failed read as errors`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing test first

In `src/tests.zig`, directly after the test `"run captures a child's output and exit code"`, add:

```zig
test "run reports a child killed by a signal as an error, not as exit 0" {
    try std.testing.expectError(error.Signaled, run.capture(gpa, &.{ "/bin/sh", "-c", "kill -9 $$" }));
}

test "run captures output larger than one read" {
    const big = try run.capture(gpa, &.{ "/usr/bin/head", "-c", "200000", "/dev/zero" });
    defer big.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 200000), big.out.len);
    try std.testing.expectEqual(@as(u8, 0), big.code);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="run "` →
the signal test FAILS (it gets a value with code 0 instead of `error.Signaled`).
The large-output test passes. If the signal test passes before you change `run.zig`, STOP.

### Step 2: Fix `capture`

Replace the excerpt shown in "Current state" (from `var out` to the end of
`capture`) with this shape, and add the two helpers below `capture`:

```zig
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const drained = drain(gpa, fds[0], &out);
    _ = close(fds[0]);
    const status = reap(pid) orelse return error.Wait;
    try drained;
    if (!std.c.W.IFEXITED(status)) return error.Signaled;
    return .{ .out = try out.toOwnedSlice(gpa), .code = std.c.W.EXITSTATUS(status) };
}

fn drain(gpa: std.mem.Allocator, fd: c_int, out: *std.ArrayList(u8)) !void {
    var buf: [read_chunk]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n == 0) return;
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.Read;
        }
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
}

fn reap(pid: c_int) ?u32 {
    var status: c_int = 0;
    while (true) {
        const rc = waitpid(pid, &status, 0);
        if (rc == pid) return @bitCast(status);
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        return null;
    }
}
```

The order matters: close the pipe and reap the child before any error returns,
so no path leaves an open descriptor or a zombie process. This snippet was not
compiled by the plan's author. If the compiler rejects a detail, make the
smallest syntax change that keeps this behavior.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="run "` → all pass, including both new tests.

### Step 3: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → ends with `61/61 tests passed`
(59 at baseline plus 2 new). If other plans landed first, the total is higher. What matters is zero failures.

## Test plan

- New tests in `src/tests.zig`, next to the existing run test:
  - a child killed by `SIGKILL` gives `error.Signaled` (the regression this plan fixes);
  - 200,000 bytes of output arrive whole with exit code 0.
- `EINTR` on `read` and `waitpid` cannot be forced in a unit test. It is covered by code review only.

## Done criteria

ALL must hold:

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] Both new tests exist and pass
- [ ] `grep -c "IFEXITED" src/run.zig` prints `1`
- [ ] `grep -c "n <= 0" src/run.zig` prints `0`
- [ ] `git status --porcelain` lists only `src/run.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The `src/run.zig` excerpt in "Current state" does not match the file.
- The signal test passes before the fix in step 2.
- Any test outside the `run` tests starts to fail after step 2. A caller may depend on the old behavior.
- `std.c.W.IFEXITED` or `std.c.errno` does not exist in the Zig you run. Check that `mise exec zig@0.17.0 -- zig version` prints `0.17.0`.

## Maintenance notes

- Callers must keep treating an error from `capture` as failure. A new caller that
  uses `catch` to assume success would bring the bug back.
- Deferred: a timeout and a stop flag for long-running children (a hung `git`
  blocks the cleanup scan). That needs a design for cancellation and is a separate plan.
- Reviewer: check the order in `capture`. The pipe is closed and the child reaped before any error returns.
