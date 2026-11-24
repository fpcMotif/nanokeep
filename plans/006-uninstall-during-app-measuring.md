# Plan 006: Uninstalling an app while sizes are being measured is safe

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/apps.zig`
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
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/8

## Why this matters

After the app list loads, nanokeep measures the size of every app on background
threads. The threads read each app's path through a pointer borrowed from the
list. If the user uninstalls an app during that time, `Inventory.remove` frees
the path and shortens the list. The threads can then read freed memory, and
when they finish, the results (one per original app) are zipped with a list
that is one shorter. In a safe build that is a panic. In a release build the
sizes land on the wrong apps or memory is corrupted. After this plan, the
measurement owns its paths, and a removal restarts it.

## Current state

All code is in `src/apps.zig`.

- `Measure` (lines 93-110):

  ```zig
  const Measure = struct {
      inv: *Inventory,
      generation: u64,
      paths: [][:0]const u8,
      out: []walk.Size,
      pool: walk.Pool,
      thread: ?std.Thread = null,

      fn work(m: *Measure) void {
          m.pool.run();
          objc.dispatchMain(m, finished);
      }

      fn finished(ctx: ?*anyopaque) callconv(.c) void {
          const m: *Measure = @ptrCast(@alignCast(ctx));
          m.inv.measured(m);
      }
  };
  ```

- `Inventory` methods (lines 250-293):

  ```zig
      fn startMeasure(inv: *Inventory) void {
          const n = inv.apps.items.len;
          const paths = inv.gpa.alloc([:0]const u8, n) catch return;
          const out = inv.gpa.alloc(walk.Size, n) catch return inv.gpa.free(paths);
          @memset(out, .{});
          for (inv.apps.items, 0..) |a, i| paths[i] = a.path;
          const m = inv.gpa.create(Measure) catch {
              inv.gpa.free(paths);
              return inv.gpa.free(out);
          };
          m.* = .{ .inv = inv, .generation = inv.generation, .paths = paths, .out = out, .pool = .{ .gpa = inv.gpa, .paths = paths, .out = out } };
          inv.measuring = m;
          if (inv.sync) {
              m.pool.run();
              return inv.measured(m);
          }
          m.thread = std.Thread.spawn(.{}, Measure.work, .{m}) catch {
              m.pool.run();
              return inv.measured(m);
          };
      }

      fn measured(inv: *Inventory, m: *Measure) void {
          if (m.thread) |t| t.join();
          if (m.generation == inv.generation) for (inv.apps.items, m.out) |*a, s| {
              a.size = s;
              a.measured = true;
          };
          inv.freeMeasure(m);
          inv.tell();
      }

      fn freeMeasure(inv: *Inventory, m: *Measure) void {
          inv.gpa.free(m.paths);
          inv.gpa.free(m.out);
          inv.gpa.destroy(m);
          inv.measuring = null;
      }

      pub fn remove(inv: *Inventory, index: usize) void {
          const a = inv.apps.orderedRemove(index);
          a.free(inv.gpa);
          inv.tell();
      }
  ```

- Facts about the surrounding code:
  - `paths[i] = a.path` borrows the pointer. `a.free(inv.gpa)` in `remove` frees it.
  - `inv.generation` is only used in this file. `listed` increments it when a new list
    arrives, and `measured` compares it. Nothing else reads it.
  - `walk.Pool` has a field `cancel: std.atomic.Value(bool)`. Setting it to `true` makes
    the worker threads stop after their current item. `Inventory.deinit` already uses
    `m.pool.cancel.store(true, .monotonic);`.
  - `measured` always runs on the main thread, called through `objc.dispatchMain`.
  - `inv.tell()` calls the optional `on_change` callback: `pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };`.
    `listed` calls `inv.startMeasure()` and then `inv.tell()`, both on the main thread.
  - The only caller of `remove` is `App.uninstallSelected` in `src/app.zig:403`.
  - `Inventory` fields with defaults: only `gpa` and `dirs` must be given, so
    `apps.Inventory{ .gpa = gpa, .dirs = &dirs }` is a valid value.
  - App names: when an app has no `Info.plist`, its name is the folder name without `.app`.
    The list is sorted by name without regard to case.
- Test helpers in `src/tests.zig`: `Tmp` (temp folder with `t.sh` and `t.sub`),
  `duBytes(path)` (size on disk from `du`), `spin()` (runs the main run loop for 0.05
  seconds so `dispatchMain` callbacks run), and the constant `max_spins = 600`. The test
  `"the app list loads after the first frame, without blocking it"` shows the spin loop:

  ```zig
      var spins: usize = 0;
      while (!a.inventory.loaded and spins < max_spins) : (spins += 1) spin();
      while (a.inventory.measuring != null and spins < max_spins) : (spins += 1) spin();
  ```

- Conventions: all tests live in `src/tests.zig`, named as a sentence. `gpa` in tests is
  `std.testing.allocator` and fails a test that leaks. The code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| This test | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="still being measured"` | passes |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/apps.zig` (`startMeasure`, `measured`, `freeMeasure`, `remove`)
- `src/tests.zig` (add one test and one helper struct)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- `src/app.zig`, including `uninstallSelected`.
- `src/walk.zig` and `walk.Pool`.
- `Listing`, `load`, `listed` and `deinit` in `src/apps.zig`.
- Do not run `zig fmt` on whole files. `src/tests.zig` already differs from
  `zig fmt` output, and formatting it creates an unrelated diff.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/006-uninstall-during-measuring`
- Conventional commits. Use: `fix(apps): keep sizes right when an app is removed during measuring`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing test first

In `src/tests.zig`, directly after the test
`"the app list loads after the first frame, without blocking it"`, add:

```zig
const RemoveFirstWhileMeasuring = struct {
    inv: *apps.Inventory,
    done: bool = false,

    fn changed(ctx: *anyopaque) void {
        const r: *RemoveFirstWhileMeasuring = @ptrCast(@alignCast(ctx));
        if (r.done or r.inv.measuring == null) return;
        r.done = true;
        r.inv.remove(0);
    }
};

test "removing an app while sizes are still being measured keeps the list and the sizes in step" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("for n in One Two Three; do mkdir -p Apps/$n.app/Contents/MacOS && cp /usr/bin/true Apps/$n.app/Contents/MacOS/fake && dd if=/dev/urandom of=Apps/$n.app/Contents/blob bs=4096 count=6 2>/dev/null; done", .{});
    var ab: [128]u8 = undefined;
    const dirs = [_][]const u8{try t.sub(&ab, "Apps")};
    var inv: apps.Inventory = .{ .gpa = gpa, .dirs = &dirs };
    defer inv.deinit();
    var remover: RemoveFirstWhileMeasuring = .{ .inv = &inv };
    inv.on_change = .{ .ctx = &remover, .func = RemoveFirstWhileMeasuring.changed };
    inv.load();
    var spins: usize = 0;
    while ((!inv.loaded or inv.measuring != null) and spins < max_spins) : (spins += 1) spin();
    try std.testing.expect(remover.done);
    try std.testing.expect(inv.loaded and inv.measuring == null);
    try std.testing.expectEqual(@as(usize, 2), inv.apps.items.len);
    for (inv.apps.items) |a| {
        try std.testing.expect(a.measured);
        try std.testing.expectEqual(try duBytes(a.path), a.size.bytes);
    }
}
```

How it works: `listed` starts the measurement and then calls `tell()` on the main
thread. The callback removes the first app at that moment, while the measurement is
still registered. This makes the timing the same on every run.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="still being measured"` →
the test FAILS. Expect a panic about a `for` loop over objects with non-equal
lengths, or a failed expectation. If it passes before the fix, STOP.

### Step 2: Make the measurement own its paths

In `src/apps.zig`:

1. In `startMeasure`, copy each path instead of borrowing it. Free the copies on every early return:

   ```zig
       fn startMeasure(inv: *Inventory) void {
           const n = inv.apps.items.len;
           const paths = inv.gpa.alloc([:0]const u8, n) catch return;
           var copied: usize = 0;
           for (inv.apps.items) |a| {
               paths[copied] = inv.gpa.dupeSentinel(u8, a.path, 0) catch break;
               copied += 1;
           }
           if (copied < n) return inv.freePaths(paths, copied);
           const out = inv.gpa.alloc(walk.Size, n) catch return inv.freePaths(paths, n);
           @memset(out, .{});
           const m = inv.gpa.create(Measure) catch {
               inv.freePaths(paths, n);
               return inv.gpa.free(out);
           };
           ...the rest is unchanged...
   ```

2. Add the helper and use it in `freeMeasure`:

   ```zig
       fn freePaths(inv: *Inventory, paths: [][:0]const u8, copied: usize) void {
           for (paths[0..copied]) |p| inv.gpa.free(p);
           inv.gpa.free(paths);
       }

       fn freeMeasure(inv: *Inventory, m: *Measure) void {
           inv.freePaths(m.paths, m.paths.len);
           inv.gpa.free(m.out);
           inv.gpa.destroy(m);
           inv.measuring = null;
       }
   ```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="app list loads"` → passes with no leak report.

### Step 3: Restart the measurement when an app is removed

1. Replace `remove`:

   ```zig
       pub fn remove(inv: *Inventory, index: usize) void {
           if (inv.measuring) |m| m.pool.cancel.store(true, .monotonic);
           inv.generation += 1;
           const a = inv.apps.orderedRemove(index);
           a.free(inv.gpa);
           inv.tell();
       }
   ```

2. Replace `measured`:

   ```zig
       fn measured(inv: *Inventory, m: *Measure) void {
           if (m.thread) |t| t.join();
           const current = m.generation == inv.generation;
           if (current) for (inv.apps.items, m.out) |*a, s| {
               a.size = s;
               a.measured = true;
           };
           inv.freeMeasure(m);
           if (!current) inv.startMeasure();
           inv.tell();
       }
   ```

This snippet was not compiled by the plan's author. If the compiler rejects a
detail, make the smallest syntax change that keeps this behavior.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="still being measured"` → passes.

### Step 4: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests. The total is the earlier total plus 1.

## Test plan

- One new test in `src/tests.zig` (step 1): three fake apps, the first is removed while the
  measurement is registered, and the two that remain end up measured with the sizes `du` reports.
- The existing tests `"the app list loads after the first frame, without blocking it"` and
  `"the window shows every page, asks before cleaning and before uninstalling"` must pass unchanged.

## Done criteria

ALL must hold:

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] The new test exists and passes
- [ ] `grep -c "paths\[i\] = a.path" src/apps.zig` prints `0`
- [ ] `grep -c "fn freePaths" src/apps.zig` prints `1`
- [ ] `git status --porcelain` lists only `src/apps.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The `src/apps.zig` excerpts in "Current state" do not match the file.
- The new test passes before the fix.
- The new test is flaky: run it 5 times after step 3, and stop if any run fails.
- Any code outside `src/apps.zig` reads `inv.generation` (check with `grep -rn "generation" src --include=*.zig`). At `b83f7d8` only `src/apps.zig` does.
- The test allocator reports a leak that you cannot trace to the path copies.

## Maintenance notes

- A removal during measuring now measures every remaining app again. That costs one
  extra walk of the app folders. It was chosen because it is simple and correct.
- `Measure.finished` is still queued on the main thread with a pointer to `m`. This plan
  never frees `m` before that callback runs. Keep it that way: only `measured` and `deinit` free it.
- Any future method that adds, removes or reorders `inv.apps` during a measurement must
  bump `inv.generation` in the same way.
- Reviewer: check that every early return in `startMeasure` frees the copied paths.
