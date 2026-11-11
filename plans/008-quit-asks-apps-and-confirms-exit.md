# Plan 008: Quit asks apps the AppKit way and confirms that the process exited

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `rg -n 'fn mayQuit' src/procs.zig`
> It must print one match. If it prints nothing, plan 007 has not landed: STOP.
> Then compare the "Current state" excerpts against the live code. On a
> mismatch, treat it as a STOP condition.

## At a glance

Quit sends SIGTERM to every process of a group and reports success at once,
so an app can lose unsaved work and nanokeep never learns whether it exited.
This plan asks an app's main process to quit through AppKit, signals a group's
root process first, and checks for up to 5 seconds that the process is gone.
Force Quit still sends SIGKILL, and the safety checks from plan 007 stay.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/007-quit-refuses-session-processes-and-reused-pids.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-17

## Why this matters

An AppKit app has no SIGTERM handler, so SIGTERM ends it immediately. It gets
no chance to show "Save changes?". The confirm dialog says the app "is asked
to quit, as Quit in its menu does", which is not what happens.

A group such as Google Chrome had 52 processes on the audited Mac. Quit
signals all 52, in memory order. Asking the main process is enough: its
helpers exit with it.

After the signal, nanokeep shows "Asked to quit" and forgets the request. The
row stays for up to 2 seconds. An app that ignores the request stays forever,
and the user gets no hint to use Force Quit.

## Current state

Files:

- `src/app.zig`: `App`, `tick`, `quitSelected`.
- `src/procs.zig`: `Sampler`, `mayQuit`, `quit`. It imports only `std`. Keep it that way.
- `src/view_procs.zig`: `dialog`, the confirm dialog.
- `src/tests.zig`: every test.

Constants at the top of `src/app.zig`:

```zig
pub const interval = 2.0;
pub const hidden_interval = 10.0;
const min_wait = 0.05;
const second_sample_after = 0.6;
const max_awake = 32;
pub const never_sampled = -std.math.inf(f64);
```

`pub const Selection = struct { group: u64, pid: ?i32 = null };` is in the same file.

Injected functions among the `App` fields (tests replace them):

```zig
    send: *const fn (c_int, c_int) callconv(.c) c_int = procs.sendKill,
    trash_app: cleaner.TrashFn = nanoui.shell.trash,
```

`App.tick`:

```zig
    pub fn tick(a: *App, t: f64) f32 {
        if (a.live and t - a.last >= interval) a.sample(t);
        a.refresh();
        return @floatCast(@max(min_wait, interval - (t - a.last)));
    }
```

The view calls `tick` once per frame and asks for the next frame after the
returned number of seconds.

`App.quitSelected`, as plan 007 leaves it:

```zig
    pub fn quitSelected(a: *App) void {
        var pids: std.ArrayList(i32) = .empty;
        defer pids.deinit(a.gpa);
        a.quitTargets(&pids);
        if (pids.items.len == 0) return;
        const name = a.selectionName();
        var failed: usize = 0;
        var why: []const u8 = "";
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
        var msg: [160]u8 = undefined;
        if (failed > 0) {
            const title = if (pids.items.len == 1) std.fmt.bufPrint(&msg, "Couldn't quit {s}", .{name}) else std.fmt.bufPrint(&msg, "Couldn't quit {d} of {d}", .{ failed, pids.items.len });
            a.toaster.push(.{ .status = .danger, .title = title catch "Couldn't quit", .message = why });
        } else {
            a.toaster.push(.{ .status = .success, .title = std.fmt.bufPrint(&msg, "{s} {s}", .{ if (a.force) "Force quit" else "Asked to quit", name }) catch "Quit" });
        }
        a.selected = null;
    }
```

Facts the steps rely on:

- `quitTargets` fills `pids` with one pid when a single process row is selected, or with every pid of the selected group.
- `a.table.group(key)` returns `?*const groups.Group`. `Group.bundle` is the path of the app's outer `.app` folder, or `""` when the group is not an app.
- `Sampler.cache` maps a pid to a `Known` record. `Known.start` is the process start time (0 when unreadable) and `Known.ppid` is the parent pid, a `u32`.
- `a.toaster.push` copies the title and message, so stack buffers are safe to pass.
- `nanoui.objc` offers `objc.class(name)`, `objc.msg(ReturnType, target, selector, args)`, `objc.fromNSString(?objc.Object) []const u8`, and `objc.Pool.push()` / `pool.pop()`. `src/fda.zig:131` shows `fromNSString` in use.

In `src/view_procs.zig`, inside `pub fn dialog`:

```zig
    const desc = if (a.force) "It stops at once. Unsaved changes are lost." else "It is asked to quit, as Quit in its menu does.";
```

Conventions in this repo:

- Do not add comments. Names carry the meaning.
- Do not format whole files.
- Test names are full sentences that state the requirement.
- Tests replace OS effects with injected functions. See `record` and `sent` above the test `"quitting refuses itself and other users' processes"` in `src/tests.zig`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| Quit tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quit"` | all pass |
| Build the app | `mise exec zig@0.17.0 -- zig build` | exit 0 |

Do not use a bare `zig`.

## Scope

**In scope** (the only files you should modify):
- `src/procs.zig` (three new functions)
- `src/app.zig` (`App` fields, `tick`, `quitSelected`, new helpers)
- `src/view_procs.zig` (the one `desc` line)
- `src/tests.zig` (four new tests and their fakes)

**Out of scope** (do NOT touch, even though they look related):
- `Sampler.mayQuit` and `Sampler.quit`. Call them. Do not change them.
- `src/groups.zig` and the table build.
- Any kernel event source for process exit. See "Maintenance notes".
- Every Markdown file except your status row in `plans/README.md`.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/008-graceful-quit`
- Conventional commits. Use: `fix(procs): ask apps to quit through AppKit and confirm the exit`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add three helpers to `src/procs.zig`

Add at file level, after `sendKill`:

```zig
pub fn alive(pid: i32, start: u64) bool {
    var ru: Rusage = undefined;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, &ru) != 0) return false;
    return start == 0 or ru.proc_start_abstime == start;
}

pub fn rootsFirst(pids: []i32, parents: []i32) void {
    var roots: usize = 0;
    for (0..pids.len) |i| {
        if (std.mem.indexOfScalar(i32, pids, parents[i]) != null) continue;
        std.mem.swap(i32, &pids[roots], &pids[i]);
        std.mem.swap(i32, &parents[roots], &parents[i]);
        roots += 1;
    }
}
```

`parents[i]` is the parent pid of `pids[i]`, or 0 when unknown. A root is a
process whose parent is not in the list.

Add inside `Sampler`, after `find`:

```zig
    pub fn startOf(s: *const Sampler, pid: i32) u64 {
        return if (s.cache.get(pid)) |k| k.start else 0;
    }

    pub fn parentOf(s: *const Sampler, pid: i32) i32 {
        return if (s.cache.get(pid)) |k| @intCast(k.ppid) else 0;
    }
```

**Verify**: `mise exec zig@0.17.0 -- zig build` → exit 0.

### Step 2: Write the four tests and watch them fail

Add to `src/tests.zig`, after the quit tests:

```zig
const chrome = "/Applications/Google Chrome.app";
const chrome_main = 7001;
const chrome_helper = 7002;
var asked: std.ArrayList(i32) = .empty;
var still_alive = true;

fn askChromeMain(pid: i32, bundle: []const u8) bool {
    asked.append(gpa, pid) catch return false;
    return pid == chrome_main and std.mem.eql(u8, bundle, chrome);
}

fn notAnApp(_: i32, _: []const u8) bool {
    return false;
}

fn fakeAlive(_: i32, _: u64) bool {
    return still_alive;
}

fn quitApp(a: *App) !void {
    a.live = false;
    a.send = record;
    a.alive = fakeAlive;
    try a.sampler.procs.append(gpa, .{ .pid = chrome_helper, .uid = a.sampler.uid, .name = "Google Chrome Helper", .bundle = chrome, .memory = 300, .known = true });
    try a.sampler.procs.append(gpa, .{ .pid = chrome_main, .uid = a.sampler.uid, .name = "Google Chrome", .bundle = chrome, .memory = 100, .known = true });
    a.order();
    a.selected = .{ .group = a.table.groups.items[0].key };
}

test "quit asks an app's main process the AppKit way and signals no helper" {
    defer sent.clearAndFree(gpa);
    defer asked.clearAndFree(gpa);
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    try quitApp(&a);
    a.terminate_app = askChromeMain;
    a.quitSelected();
    try std.testing.expectEqual(@as(usize, 0), sent.items.len);
    try std.testing.expectEqual(@as(i32, chrome_main), asked.items[asked.items.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), a.leaving_count);
    try std.testing.expectEqual(@as(i32, chrome_main), a.leaving[0].pid);
}

test "quit signals a process that is not an app, and force quit never asks" {
    defer sent.clearAndFree(gpa);
    defer asked.clearAndFree(gpa);
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    try quitApp(&a);
    a.terminate_app = notAnApp;
    a.quitSelected();
    try std.testing.expectEqual(@as(usize, 2), sent.items.len);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.SIG.TERM)), sent.items[0][1]);
    sent.clearRetainingCapacity();
    a.selected = .{ .group = a.table.groups.items[0].key };
    a.terminate_app = askChromeMain;
    asked.clearRetainingCapacity();
    a.force = true;
    a.quitSelected();
    try std.testing.expectEqual(@as(usize, 0), asked.items.len);
    try std.testing.expectEqual(@as(usize, 2), sent.items.len);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.SIG.KILL)), sent.items[0][1]);
}

test "a group's root process comes first when its processes are signalled" {
    var pids = [_]i32{ 5, 3, 9 };
    var parents = [_]i32{ 3, 1, 5 };
    procs.rootsFirst(&pids, &parents);
    try std.testing.expectEqual(@as(i32, 3), pids[0]);
    try std.testing.expectEqual(@as(i32, 1), parents[0]);
}

test "a quit is forgotten when the process exits, and offered for Force Quit when it stays" {
    const app = @import("app.zig");
    defer sent.clearAndFree(gpa);
    defer asked.clearAndFree(gpa);
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    try quitApp(&a);
    a.terminate_app = askChromeMain;
    const chosen = a.selected.?;
    still_alive = true;
    defer still_alive = true;
    a.quitSelected();
    try std.testing.expect(a.selected == null);
    try std.testing.expect(a.tick(100) <= app.quit_poll);
    try std.testing.expectEqual(@as(usize, 1), a.leaving_count);
    _ = a.tick(100 + app.quit_grace + 0.1);
    try std.testing.expectEqual(@as(usize, 0), a.leaving_count);
    try std.testing.expectEqual(chosen.group, a.selected.?.group);

    a.quitSelected();
    a.last = 100;
    still_alive = false;
    _ = a.tick(200);
    try std.testing.expectEqual(@as(usize, 0), a.leaving_count);
    try std.testing.expect(a.selected == null);
    try std.testing.expectEqual(app.never_sampled, a.last);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quit"` → the build FAILS with errors about `a.alive`, `a.terminate_app`, `a.leaving_count` or `quit_poll` not existing. That is the expected red state. If it builds, STOP.

### Step 3: Add the state and the AppKit request to `src/app.zig`

1. Add below `const max_awake = 32;`:

   ```zig
   pub const quit_grace = 5.0;
   pub const quit_poll = 0.1;
   const max_leaving = 8;

   pub const Leaving = struct {
       pid: i32,
       start: u64,
       force: bool,
       selection: Selection,
       since: ?f64 = null,
       name: [48]u8 = @splat(0),
   };
   ```

   `Selection` is declared lower in the file. Zig resolves that. Leave it where it is.

2. Add these `App` fields directly after the `trash_app` field:

   ```zig
       terminate_app: *const fn (i32, []const u8) bool = terminateApp,
       alive: *const fn (i32, u64) bool = procs.alive,
       leaving: [max_leaving]Leaving = undefined,
       leaving_count: usize = 0,
   ```

3. Add this file-level function at the end of the file:

   ```zig
   fn terminateApp(pid: i32, bundle: []const u8) bool {
       const objc = nanoui.objc;
       const pool = objc.Pool.push();
       defer pool.pop();
       const running = objc.msg(?objc.Object, objc.class("NSRunningApplication"), "runningApplicationWithProcessIdentifier:", .{@as(c_int, pid)}) orelse return false;
       const url = objc.msg(?objc.Object, running, "bundleURL", .{}) orelse return false;
       if (!std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{})), bundle)) return false;
       return objc.msg(objc.BOOL, running, "terminate", .{});
   }
   ```

   It returns true only when the pid is the main process of the app at
   `bundle` and AppKit accepted the request. A helper process has a nested
   bundle path, so it returns false for a helper.

**Verify**: `mise exec zig@0.17.0 -- zig build` → exit 0.

### Step 4: Rewrite `quitSelected` and add its helpers

Replace the whole `quitSelected` function with:

```zig
    pub fn quitSelected(a: *App) void {
        var pids: std.ArrayList(i32) = .empty;
        defer pids.deinit(a.gpa);
        var parents: std.ArrayList(i32) = .empty;
        defer parents.deinit(a.gpa);
        a.quitTargets(&pids);
        if (pids.items.len == 0) return;
        const sel = a.selected orelse return;
        const name = a.selectionName();
        for (pids.items) |pid| parents.append(a.gpa, a.sampler.parentOf(pid)) catch return;
        procs.rootsFirst(pids.items, parents.items);
        var failed: usize = 0;
        var why: []const u8 = "";
        var lead: ?i32 = if (a.force) null else a.askApp(sel.group, pids.items);
        if (lead == null) for (pids.items) |pid| {
            if (a.sampler.quit(pid, if (a.force) .force else .quit, a.send)) |_| {
                if (lead == null) lead = pid;
            } else |err| {
                if (err == error.Gone) continue;
                failed += 1;
                why = switch (err) {
                    error.NotYours => "It belongs to another user.",
                    error.Itself => "nanokeep can't quit itself here.",
                    error.Failed => "The process didn't take the signal.",
                    error.Protected => "macOS needs it running. Quitting it would log you out.",
                    error.Gone => unreachable,
                };
            }
        };
        if (lead) |pid| a.expectExit(pid, sel, name);
        var msg: [160]u8 = undefined;
        if (failed > 0) {
            const title = if (pids.items.len == 1) std.fmt.bufPrint(&msg, "Couldn't quit {s}", .{name}) else std.fmt.bufPrint(&msg, "Couldn't quit {d} of {d}", .{ failed, pids.items.len });
            a.toaster.push(.{ .status = .danger, .title = title catch "Couldn't quit", .message = why });
        } else {
            a.toaster.push(.{ .status = .success, .title = std.fmt.bufPrint(&msg, "{s} {s}", .{ if (a.force) "Force quit" else "Asked to quit", name }) catch "Quit" });
        }
        a.selected = null;
    }

    fn askApp(a: *App, group: u64, pids: []const i32) ?i32 {
        const g = a.table.group(group) orelse return null;
        if (g.bundle.len == 0) return null;
        for (pids) |pid| {
            a.sampler.mayQuit(pid) catch continue;
            if (a.terminate_app(pid, g.bundle)) return pid;
        }
        return null;
    }

    fn expectExit(a: *App, pid: i32, sel: Selection, name: []const u8) void {
        if (a.leaving_count == a.leaving.len) return;
        var l: Leaving = .{ .pid = pid, .start = a.sampler.startOf(pid), .force = a.force, .selection = sel };
        const n = @min(name.len, l.name.len - 1);
        @memcpy(l.name[0..n], name[0..n]);
        a.leaving[a.leaving_count] = l;
        a.leaving_count += 1;
    }
```

The toast texts and the error texts are unchanged. Copy them exactly.

**Verify**: `mise exec zig@0.17.0 -- zig build` → exit 0.

### Step 5: Check for the exit in `tick`

Replace `tick` with:

```zig
    pub fn tick(a: *App, t: f64) f32 {
        a.settleQuits(t);
        if (a.live and t - a.last >= interval) a.sample(t);
        a.refresh();
        const wait = @max(min_wait, interval - (t - a.last));
        return @floatCast(if (a.leaving_count > 0) @min(wait, quit_poll) else wait);
    }

    fn settleQuits(a: *App, t: f64) void {
        var i: usize = 0;
        while (i < a.leaving_count) {
            const l = &a.leaving[i];
            const since = l.since orelse t;
            l.since = since;
            const gone = !a.alive(l.pid, l.start);
            if (!gone and t - since < quit_grace) {
                i += 1;
                continue;
            }
            if (gone) a.last = never_sampled else a.stillRunning(l.*);
            a.leaving[i] = a.leaving[a.leaving_count - 1];
            a.leaving_count -= 1;
        }
    }

    fn stillRunning(a: *App, l: Leaving) void {
        const name = std.mem.sliceTo(&l.name, 0);
        var msg: [160]u8 = undefined;
        if (l.force) {
            a.toaster.push(.{ .status = .danger, .title = std.fmt.bufPrint(&msg, "Couldn't force quit {s}", .{name}) catch "Couldn't force quit", .message = "macOS did not stop it." });
            return;
        }
        a.toaster.push(.{ .status = .warning, .title = std.fmt.bufPrint(&msg, "{s} is still running", .{name}) catch "Still running", .message = "It may be asking you to save. Force Quit stops it at once.", .duration = 8 });
        if (a.selected == null) a.selected = l.selection;
    }
```

How it works:

- While a quit is pending, `tick` returns at most 0.1 s, so the view checks 10 times a second.
- When the process is gone, `a.last = never_sampled` makes the same `tick` take a fresh sample, so the row disappears at once.
- After 5 s the request is dropped, a toast explains it, and the group is selected again so the Force Quit button is enabled.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="quit"` → all quit tests pass, including the four new ones.

### Step 6: Make the confirm dialog say what happens

In `src/view_procs.zig`, replace the `desc` line with:

```zig
    const desc = if (a.force) "It stops at once. Unsaved changes are lost." else "An app is asked to quit, as Quit in its menu does. Other processes get a terminate signal and can lose unsaved work.";
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests.

### Step 7: Check the real AppKit request once by hand

This step needs a logged-in desktop. If you run without one, skip it and say so in your report.

1. Run `mise exec zig@0.17.0 -- zig build run`.
2. Open TextEdit and type a letter in a new document.
3. In nanokeep, open Processes, select the TextEdit group, choose Quit, and confirm.

**Verify**: TextEdit shows its own "Do you want to keep this new document?" sheet. After about 5 seconds nanokeep shows "TextEdit is still running" and the TextEdit row is selected.

## Test plan

- The four tests in step 2 cover: the AppKit request, the signal fallback and Force Quit, the signalling order, and the exit check with its timeout.
- Each one fails to build before step 3 and passes after step 5.
- The pattern is the existing test `"quitting refuses itself and other users' processes"`: fake functions that record what was asked.

## Done criteria

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] `rg -n 'as Quit in its menu does\."' src/view_procs.zig` prints no match for the old sentence `"It is asked to quit, as Quit in its menu does."`
- [ ] `rg -n 'fn settleQuits|fn askApp|fn expectExit|fn terminateApp' src/app.zig` prints four matches
- [ ] `rg -n 'nanoui' src/procs.zig` prints nothing
- [ ] `git status --short` lists only `src/procs.zig`, `src/app.zig`, `src/view_procs.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `fn mayQuit` is missing from `src/procs.zig`.
- An excerpt in "Current state" does not match the live code.
- The tests build in step 2, before the new fields exist.
- `objc.msg` rejects the `terminateApp` code at compile time. Report the exact error. Do not replace the AppKit call with a signal.
- In step 7, TextEdit closes with no save sheet. That means the AppKit request did not go to the app.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Exit detection is a check 10 times a second for at most 5 seconds. A kernel process event (`DISPATCH_SOURCE_TYPE_PROC` with `DISPATCH_PROC_EXIT` on the main queue) would react without the check. It was left out because the check is one system call, runs only inside the 5 second window, and tests can drive it with a fake clock. Add the event source only if the 0.1 s delay shows in use.
- `terminateApp` compares the app's bundle path with the group's bundle path. If macOS reports the app under a different path than the process path (a cryptex or firmlink path), the comparison fails and Quit falls back to SIGTERM. That is the old behaviour, so it is safe, but the app then gets no save prompt.
- `rootsFirst` moves roots to the front. It does not order deeper levels. That is enough for app groups, where helpers are children of the main process.
- A reviewer must confirm that the two error `switch` blocks and the toast texts in `quitSelected` are unchanged from plan 007.
- `docs/state-machines.md` describes the quit flags. It needs a paragraph on `leaving` after this lands. The executor does not edit it.
