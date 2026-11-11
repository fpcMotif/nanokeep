# Plan 007: Quit refuses session processes and never signals a reused pid

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/procs.zig src/app.zig src/tests.zig`
> `src/procs.zig` must show no change. `src/app.zig` and `src/tests.zig` had
> uncommitted edits when this plan was written, so they can differ. Compare the
> "Current state" excerpts against the live code before proceeding. On a
> mismatch in an excerpt, treat it as a STOP condition.

## At a glance

Quit and Force Quit signal any process the user owns, using a pid read up to
2 seconds earlier. This plan makes `Sampler.quit` refuse `loginwindow` and
check that the pid still names the same process before it signals. Which
signal is sent, the confirm dialog and the selection logic stay as they are.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-pin-zig-toolchain.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-17

## Why this matters

`loginwindow` runs under the logged-in user's account. On the audited Mac,
`ps` shows it owned by the user, with pid 452. Selecting it on the Processes
page and choosing Quit sends it SIGTERM, and macOS then ends the login session
at once. Every open app closes without a save prompt.

The second problem is pid reuse. The pids to signal come from the latest
sample, which is up to 2 seconds old. If that process exited and the kernel
gave its pid to a new process, nanokeep signals the new process. The sampler
already stores each process's start time and executable UUID, so one system
call can confirm identity before the signal.

## Current state

- `src/procs.zig` holds the sampler and the quit function. It imports only `std`.
- `src/app.zig` holds `App.quitSelected`, which calls `Sampler.quit` for each pid.
- `src/tests.zig` holds every test in the repo.

`src/procs.zig:176-194`:

```zig
pub const Signal = enum(c_int) { quit = @intFromEnum(std.c.SIG.TERM), force = @intFromEnum(std.c.SIG.KILL) };

pub const QuitError = error{ NotYours, Itself, Failed };

const Prev = struct { time_ns: u64, disk: u64, energy: u64 };

const Known = struct {
    start: u64,
    uuid: [16]u8,
    ppid: u32,
    uid: u32,
    comm: [16]u8,
    path: []u8,
    name: []const u8,
    bundle: []const u8,
    user: []const u8,
    prev: ?Prev = null,
    seen: usize,
};
```

`Known.start` and `Known.uuid` come from `proc_pid_rusage` during a sample
(`src/procs.zig:263-264`). `start` is 0 when the process was not readable.
The sampler keeps one `Known` per pid in `Sampler.cache`, a
`std.AutoHashMapUnmanaged(i32, Known)`.

`src/procs.zig:370-375`:

```zig
    pub fn quit(s: *const Sampler, pid: i32, sig: Signal, send: *const fn (c_int, c_int) callconv(.c) c_int) QuitError!void {
        if (pid == s.self_pid) return error.Itself;
        const p = s.find(pid) orelse return error.Failed;
        if (p.uid != s.uid) return error.NotYours;
        if (send(pid, @intFromEnum(sig)) != 0) return error.Failed;
    }
```

`Proc.bundle` is the path of the outermost `.app` folder of the executable,
or `""`. For `loginwindow` it is `/System/Library/CoreServices/loginwindow.app`.

In `src/app.zig`, inside `pub fn quitSelected(a: *App) void` (find it by name):

```zig
        for (pids.items) |pid| a.sampler.quit(pid, if (a.force) .force else .quit, a.send) catch |err| {
            failed += 1;
            why = switch (err) {
                error.NotYours => "It belongs to another user.",
                error.Itself => "nanokeep can't quit itself here.",
                error.Failed => "The process didn't take the signal.",
            };
        };
```

The existing test, in `src/tests.zig` (find it by its name):

```zig
test "quitting refuses itself and other users' processes" {
    defer sent.clearAndFree(gpa);
    const launchd = 1;
    const root = 0;
    const mine = 4242;
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    try s.procs.append(gpa, .{ .pid = s.self_pid, .uid = s.uid });
    try s.procs.append(gpa, .{ .pid = launchd, .uid = root });
    try s.procs.append(gpa, .{ .pid = mine, .uid = s.uid });
    try std.testing.expectError(error.Itself, s.quit(s.self_pid, .quit, record));
    if (s.uid != root) try std.testing.expectError(error.NotYours, s.quit(launchd, .force, record));
    try s.quit(mine, .force, record);
    try s.quit(mine, .quit, record);
    try std.testing.expectEqualSlices([2]c_int, &.{ .{ mine, @intFromEnum(std.c.SIG.KILL) }, .{ mine, @intFromEnum(std.c.SIG.TERM) } }, sent.items);
    try std.testing.expectError(error.Failed, s.quit(mine, .quit, refuse));
}
```

`record` is a fake sender defined just above that test. It appends
`{ pid, sig }` to the global list `sent` and returns 0. It signals nothing.

Conventions in this repo:

- Do not add comments. Names carry the meaning.
- Do not format whole files. `zig fmt` would change unrelated lines.
- Test names are full sentences that state the requirement.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| Quit tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quitting"` | all pass |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/procs.zig` (`QuitError`, `Sampler.quit`, two new functions, one new method)
- `src/app.zig` (the error `switch` in `quitSelected` only)
- `src/tests.zig` (two new tests)

**Out of scope** (do NOT touch, even though they look related):
- `src/view_procs.zig`: the confirm dialog. Plan 008 changes its text.
- Which signal Quit sends. Plan 008 changes that.
- `docs/state-machines.md` and every other Markdown file except your status row in `plans/README.md`.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/007-safe-quit-targets`
- Conventional commits. Use: `fix(procs): refuse session processes and reused pids when quitting`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the two tests and watch them fail

Add `extern "c" fn getppid() c_int;` next to the other `extern "c"` lines at
the top of `src/tests.zig`. Add these tests directly after the test
`"quitting refuses itself and other users' processes"`:

```zig
test "quitting refuses loginwindow, which would end the login session" {
    defer sent.clearAndFree(gpa);
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    s.sample(1);
    const window = procNamed(&s, "loginwindow") orelse return error.SkipZigTest;
    if (window.uid != s.uid) return error.SkipZigTest;
    const pid = window.pid;
    try std.testing.expectError(error.Protected, s.quit(pid, .quit, record));
    try std.testing.expectError(error.Protected, s.quit(pid, .force, record));
    try std.testing.expectEqual(@as(usize, 0), sent.items.len);
    const copy = 4243;
    try s.procs.append(gpa, .{ .pid = copy, .uid = s.uid, .name = "loginwindow", .bundle = "/Users/someone/Applications/loginwindow.app" });
    try s.quit(copy, .quit, record);
    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
}

test "quitting signals nothing when the pid now names a different process" {
    defer sent.clearAndFree(gpa);
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    s.sample(1);
    const parent = getppid();
    const p = s.find(parent) orelse return error.SkipZigTest;
    if (p.uid != s.uid) return error.SkipZigTest;
    const known = s.cache.getPtr(parent) orelse return error.SkipZigTest;
    if (known.start == 0) return error.SkipZigTest;
    try s.quit(parent, .quit, record);
    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    known.start += 1;
    try std.testing.expectError(error.Gone, s.quit(parent, .quit, record));
    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
}
```

Both tests use real processes only as pids that are alive. `record` signals
nothing. The first test reads `loginwindow`'s path from the live sample on
purpose. The test `"nothing in nanokeep can call Spotlight"` fails when the
test binary contains the word `CoreServices`, and `loginwindow` lives in
`/System/Library/CoreServices/`. So neither the tests nor the source may
spell that path out. `procNamed` is an existing helper in `src/tests.zig`.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quitting"` → both new tests FAIL (the first gets no error, the second gets no error on the last `quit`). The existing quit test passes. If a new test passes before step 2, STOP.

### Step 2: Add the checks to `src/procs.zig`

1. Replace the `QuitError` line with:

   ```zig
   pub const QuitError = error{ NotYours, Itself, Failed, Protected, Gone };

   const system_root = "/System/";
   const session_apps = [_][]const u8{"loginwindow.app"};

   pub fn endsSession(p: *const Proc) bool {
       if (p.pid <= 1) return true;
       if (!std.mem.startsWith(u8, p.bundle, system_root)) return false;
       const app = std.fs.path.basename(p.bundle);
       for (session_apps) |b| if (std.mem.eql(u8, app, b)) return true;
       return false;
   }

   pub fn sameProcess(pid: i32, start: u64, uuid: [16]u8) bool {
       var ru: Rusage = undefined;
       if (proc_pid_rusage(pid, RUSAGE_INFO_V6, &ru) != 0) return false;
       return ru.proc_start_abstime == start and std.mem.eql(u8, &ru.uuid, &uuid);
   }
   ```

   `Proc` is declared earlier in the file than this line, so this placement compiles.

2. Replace `Sampler.quit` with a new method `mayQuit` followed by `quit`:

   ```zig
       pub fn mayQuit(s: *const Sampler, pid: i32) QuitError!void {
           if (pid == s.self_pid) return error.Itself;
           const p = s.find(pid) orelse return error.Gone;
           if (p.uid != s.uid) return error.NotYours;
           if (endsSession(p)) return error.Protected;
           if (s.cache.get(pid)) |k| if (k.start != 0 and !sameProcess(pid, k.start, k.uuid)) return error.Gone;
       }

       pub fn quit(s: *const Sampler, pid: i32, sig: Signal, send: *const fn (c_int, c_int) callconv(.c) c_int) QuitError!void {
           try s.mayQuit(pid);
           if (send(pid, @intFromEnum(sig)) != 0) return error.Failed;
       }
   ```

   Keep the order of the checks. The existing test expects `NotYours` for
   pid 1 when the tests do not run as root, so the owner check must come
   before `endsSession`.

   Only a bundle under `/System/` counts, so a copy named `loginwindow.app`
   elsewhere is not protected. The system volume is read-only, so a user
   cannot place a bundle there.

**Verify**: `mise exec zig@0.17.0 -- zig build` → the build fails in `src/app.zig` with an error that the `switch` does not handle `Protected` and `Gone`. That is expected. Go to step 3. (The test build does not compile `quitSelected`, so use `zig build` here.)

### Step 3: Handle the new errors in `quitSelected`

In `src/app.zig`, replace the `for` loop quoted in "Current state" with:

```zig
        for (pids.items) |pid| a.sampler.quit(pid, if (a.force) .force else .quit, a.send) catch |err| {
            if (err == error.Gone) continue;
            failed += 1;
            why = switch (err) {
                error.NotYours => "It belongs to another user.",
                error.Itself => "nanokeep can't quit itself here.",
                error.Failed => "The process didn't take the signal.",
                error.Protected => "macOS needs it running. Quitting it would log you out.",
                error.Gone => unreachable,
            };
        };
```

A process that is already gone is what the user asked for, so it is not a failure.

**Verify**: `mise exec zig@0.17.0 -- zig build` → exit 0. Then `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quitting"` → all three quit tests pass.

### Step 4: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests.

## Test plan

- The two tests in step 1 are the whole test plan. Each fails before step 2 and passes after step 3.
- The pattern they follow is the existing test `"quitting refuses itself and other users' processes"`.

## Done criteria

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] `rg -n 'error.Protected' src/procs.zig src/app.zig src/tests.zig` shows at least one match in each file
- [ ] `rg -n 'fn mayQuit' src/procs.zig` shows one match
- [ ] `rg -n 'CoreServices' src/procs.zig src/tests.zig src/app.zig` prints nothing
- [ ] `mise exec zig@0.17.0 -- zig build` exits 0
- [ ] `git status --short` lists only `src/procs.zig`, `src/app.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- An excerpt in "Current state" does not match the live code.
- A new test passes in step 1, before the fix exists.
- The second new test reports "skipped" on your machine. Report it. Do not weaken the test.
- A verification fails twice after a reasonable fix attempt.
- The fix appears to need a file outside the in-scope list.

## Maintenance notes

- A gap of microseconds remains between `sameProcess` and the signal. macOS has no call that signals by process identity, so this gap cannot be closed.
- Never write a path under `/System/Library/CoreServices/` into the source or the tests. The Spotlight guard test counts that word in the test binary and fails.
- `session_apps` holds one entry on purpose. Finder, the Dock and SystemUIServer restart on their own, so quitting them is safe. Add an entry only for a process whose exit ends the session.
- Plan 008 calls `mayQuit` before it asks an app to quit through AppKit. Keep `mayQuit` free of side effects.
- `plans/README.md` listed "PID reuse between sample and quit" as rejected on 2026-11-10 because the likelihood is low. This plan reopens it because the check costs one system call.
