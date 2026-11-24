# Plan 010: Per-process system calls run on a reader thread, not the main thread

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `rg -n 'count_threads' src/procs.zig src/app.zig`
> It must print matches in both files. If it prints nothing, plan 009 has not
> landed: STOP. Then compare the "Current state" excerpts against the live
> code. On a mismatch, treat it as a STOP condition.

## At a glance

Every 2 seconds the main thread makes one or two system calls per running
process, which blocks the window for about 2 to 4 ms. This plan splits the
sample into a read step, which a reader thread runs, and an apply step, which
stays on the main thread. All sampler state stays on the main thread, and
tests and the direct `Sampler.sample` call keep working synchronously.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/009-hash-group-keys-once-and-count-threads-on-demand.md
- **Category**: perf
- **Planned at**: commit `b83f7d8`, 2026-11-17

## Why this matters

Measured on 2026-11-17 on the audited Mac, with 818 processes, ReleaseFast,
median of 20 runs: `Sampler.sample` takes 3.57 ms. Almost all of it is
`proc_pid_rusage` and `proc_pidinfo`, called once per process. Plan 009
removes the second call on most pages, which leaves about 2 ms.

That time fits inside one 120 Hz frame (8.3 ms), so the gain is small: a
scroll or an animation no longer shares a frame with the system calls. The
maintainer chose to do it anyway. The design below keeps the risk low by
sharing no sampler state between threads.

## The design in one picture

```text
main thread                     reader thread
-----------                     -------------
tick: sample is due
  Reader.request(t)  ───────▶  wakes up
  (returns at once)             Reading.read()   system calls, ~2-4 ms
                                dispatchMain(arrived)
arrived:              ◀───────  waits for the next request
  Sampler.apply(reading)   pure CPU work on main-thread state
  App.sampled(t)           metrics, tables, usage
  window.redraw()
```

One `Reading` buffer exists. The reader thread writes it only between a
request and its `arrived` call. The main thread reads it only inside
`arrived`. The main thread sends the next request only after `arrived` ran.
So the two threads never touch the buffer at the same time, and no lock
guards it.

## Current state

Files:

- `src/procs.zig`: `Sampler`. It imports only `std`. Keep it that way.
- `src/app.zig`: `App.sample`, `App.tick`, `App.heartbeat`, `App.deinit`.
- `src/main.zig`: `start`, which both the app and the bench call.
- `src/bench.zig`: `Bench.sampling` and the `budgets` table.
- `src/iokit.zig:184-275`: `Thermometer`, the existing example of a worker thread with a pthread mutex and condition. Read it before step 4.

`Sampler` fields in `src/procs.zig` that matter (plan 009 added `count_threads`):

```zig
    lookups: usize = 0,
    count_threads: bool = true,
    num: u64 = 0,
    den: u64 = 1,
    pids: []c_int = &.{},
```

`Sampler.init` ends with:

```zig
        return .{ .gpa = gpa, .num = tb[0], .den = @max(1, tb[1]), .uid = getuid(), .self_pid = getpid(), .home = home, .system = .{ .mem_total = total } };
```

`Sampler.deinit` ends with:

```zig
        if (s.pids.len > 0) s.gpa.free(s.pids);
```

`Sampler.sample`, as plan 009 leaves it:

```zig
    pub fn sample(s: *Sampler, now: f64) void {
        if (s.pids.len == 0) s.pids = s.gpa.alloc(c_int, max_pids) catch return;
        const got = proc_listallpids(s.pids.ptr, @intCast(s.pids.len * @sizeOf(c_int)));
        const n: usize = @min(s.pids.len, @as(usize, @intCast(@max(0, got))));
        s.procs.clearRetainingCapacity();
        s.procs.ensureTotalCapacity(s.gpa, n) catch return;
        s.cache.ensureUnusedCapacity(s.gpa, @intCast(n)) catch return;
        s.gone.ensureTotalCapacity(s.gpa, s.cache.count()) catch return;
        const wall = now - s.prev_wall;
        const gen = s.samples + 1;
        s.system.power = 0;
        s.system.threads = 0;
        var ru: Rusage = undefined;
        var ti: TaskInfo = undefined;
        for (s.pids[0..n]) |pid| {
            if (pid <= 0) continue;
            const readable = proc_pid_rusage(pid, RUSAGE_INFO_V6, &ru) == 0;
            const k = s.lookUp(pid, if (readable) ru.proc_start_abstime else 0, if (readable) ru.uuid else @splat(0)) orelse continue;
            k.seen = gen;
            var p: Proc = .{ .pid = pid, .uid = k.uid, .name = k.name, .bundle = k.bundle, .user = k.user };
            if (readable) {
                const t = (ru.user_time + ru.system_time) * s.num / s.den;
                const disk = ru.diskio_bytesread + ru.diskio_byteswritten;
                p.memory = ru.phys_footprint;
                p.cpu_time_ns = t;
                p.known = true;
                if (s.count_threads and proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) p.threads = @intCast(@max(0, ti.threadnum));
                if (s.samples > 0 and wall > 0) if (k.prev) |before| {
                    const wall_ns = wall * std.time.ns_per_s;
                    p.cpu = @floatCast(@as(f64, @floatFromInt(t -| before.time_ns)) / wall_ns * percent);
                    p.disk_rate = @floatCast(@as(f64, @floatFromInt(disk -| before.disk)) / wall);
                    p.energy = @floatCast(@as(f64, @floatFromInt(ru.energy_nj -| before.energy)) / wall_ns);
                    s.system.power += p.energy;
                };
                k.prev = .{ .time_ns = t, .disk = disk, .energy = ru.energy_nj };
            }
            s.system.threads += p.threads;
            s.procs.appendAssumeCapacity(p);
        }
        s.forget(gen);
        s.prev_wall = now;
        s.readSystem();
        s.samples += 1;
    }
```

`App.sample` in `src/app.zig`:

```zig
    fn sample(a: *App, t: f64) void {
        a.sampler.sample(t);
        a.metrics.sample(t, a.sampler.system.power);
        a.awake_count = iokit.assertions(&a.awake);
        a.everyone.build(a.sampler.procs.items, .{ .show = .all, .sort = .memory, .uid = a.sampler.uid }, &no_expanded) catch {};
        a.noteUsage();
        a.last = t;
        if (a.sampler.samples == 1) a.last = t - interval + second_sample_after;
    }
```

`App.tick` and `App.heartbeat` both call `a.sample(t)`. `App.deinit` starts with:

```zig
    pub fn deinit(a: *App) void {
        if (a.guide) |*g| g.deinit();
```

`start` in `src/main.zig` begins with:

```zig
pub fn start(a: *App, app: *nanoui.App) !*nanoui.Window {
    a.listen();
    a.clock = seconds;
```

`Bench.sampling` in `src/bench.zig`:

```zig
    fn sampling(b: *Bench) !void {
        var times: [20]f64 = undefined;
        for (&times) |*s| {
            b.a.last = @import("app.zig").never_sampled;
            const t = seconds();
            _ = b.a.tick(t);
            s.* = ms(t);
        }
        try b.putStats("sample", &times);
    }
```

and two rows of its `budgets` table:

```zig
    .{ .name = "sample_p50_ms", .budget = 6, .target = 1.36 },
    .{ .name = "sample_p95_ms", .budget = 8, .target = 1.65 },
```

A bench metric with no row in `budgets` makes the bench fail.

Other facts:

- `nanoui.objc.dispatchMain(context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void)` queues `work` on the main queue. The main queue runs it when the run loop turns.
- Tests turn the run loop with the helper `spin()` in `src/tests.zig`. `max_spins` bounds a wait.
- `a.window` is `?*nanoui.Window`. `w.redraw()` asks for a frame.
- `App` is created once as a local variable in `main` and never moves after `start`, so a pointer to it stays valid.

Conventions in this repo:

- Do not add comments. Names carry the meaning.
- Do not format whole files.
- Test names are full sentences that state the requirement.
- Work that needs a thread has a synchronous mode for tests. `Inventory.sync` in `src/apps.zig` is the example. Here the synchronous mode is the default.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| New tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="reading"` and `-Dtest-filter="reader thread"` | pass |
| Build | `mise exec zig@0.17.0 -- zig build` | exit 0 |
| Bench | `mise exec zig@0.17.0 -- zig build bench` | prints JSON; needs an awake display and an uncovered window |

Do not use a bare `zig`.

## Scope

**In scope** (the only files you should modify):
- `src/procs.zig` (`Raw`, `Reading`, `Sampler.sample`, `Sampler.apply`, `Sampler.init`, `Sampler.deinit`)
- `src/app.zig` (`Reader`, `App.sample`, two new methods, two fields, `App.deinit`)
- `src/main.zig` (one line in `start`)
- `src/bench.zig` (`Bench.sampling`, two `budgets` rows)
- `src/tests.zig` (two new tests)

**Out of scope** (do NOT touch, even though they look related):
- `Sampler.lookUp`, `Sampler.forget`, `Sampler.readSystem`, `Sampler.mayQuit`, `Sampler.quit`. They stay on the main thread, unchanged.
- `src/metrics.zig` and `src/iokit.zig`. Their reads take about 0.5 ms and stay on the main thread.
- Any mutex around `Sampler`. The design needs none.
- Every Markdown file except your status row in `plans/README.md`.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/010-reader-thread`
- Conventional commits. Use: `perf(procs): split the sample into read and apply`, then `perf(app): read processes on a reader thread`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Check that the work is still worth doing

This step needs a logged-in desktop with the display awake. If you run without
one, skip it, say so in your report, and continue with step 2.

Run `mise exec zig@0.17.0 -- zig build bench 2>&1 | rg '"sample_p50_ms"'`.

**Verify**: one line prints with a `"value"`. If the value is below 3, STOP and report it: the sample is already cheap and the maintainer must decide. Otherwise continue.

### Step 2: Write the read-and-apply test and watch it fail

Add to `src/tests.zig`, after the test `"the sampler reads this machine"`:

```zig
test "a reading taken apart from the sampler applies to the same result as a sample" {
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    var r: procs.Reading = .{ .gpa = gpa };
    defer r.deinit();
    r.read(true);
    s.apply(r.items.items, 0);
    r.read(true);
    s.apply(r.items.items, 1);
    const fewest_procs = 10;
    try std.testing.expect(s.procs.items.len > fewest_procs);
    try std.testing.expectEqual(@as(usize, 2), s.samples);
    const me = s.find(s.self_pid).?;
    try std.testing.expect(me.known);
    try std.testing.expect(me.threads >= 1);
    try std.testing.expect(me.cpu_time_ns > 0);
    try std.testing.expect(me.memory > 0);
    r.read(false);
    s.apply(r.items.items, 2);
    try std.testing.expectEqual(@as(u32, 0), s.find(s.self_pid).?.threads);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="reading"` → the build FAILS because `procs.Reading` does not exist.

### Step 3: Split `Sampler.sample` into `Reading.read` and `Sampler.apply`

In `src/procs.zig`:

1. Add at file level, directly before `pub const Sampler = struct {`:

   ```zig
   pub const Raw = struct {
       pid: i32,
       readable: bool = false,
       start: u64 = 0,
       uuid: [16]u8 = @splat(0),
       cpu_ticks: u64 = 0,
       disk: u64 = 0,
       energy: u64 = 0,
       memory: u64 = 0,
       threads: u32 = 0,
   };

   pub const Reading = struct {
       gpa: std.mem.Allocator,
       pids: []c_int = &.{},
       items: std.ArrayList(Raw) = .empty,

       pub fn deinit(r: *Reading) void {
           r.items.deinit(r.gpa);
           if (r.pids.len > 0) r.gpa.free(r.pids);
       }

       pub fn read(r: *Reading, count_threads: bool) void {
           r.items.clearRetainingCapacity();
           if (r.pids.len == 0) r.pids = r.gpa.alloc(c_int, max_pids) catch return;
           const got = proc_listallpids(r.pids.ptr, @intCast(r.pids.len * @sizeOf(c_int)));
           const n: usize = @min(r.pids.len, @as(usize, @intCast(@max(0, got))));
           r.items.ensureTotalCapacity(r.gpa, n) catch return;
           var ru: Rusage = undefined;
           var ti: TaskInfo = undefined;
           for (r.pids[0..n]) |pid| {
               if (pid <= 0) continue;
               var raw: Raw = .{ .pid = pid };
               if (proc_pid_rusage(pid, RUSAGE_INFO_V6, &ru) == 0) {
                   raw.readable = true;
                   raw.start = ru.proc_start_abstime;
                   raw.uuid = ru.uuid;
                   raw.cpu_ticks = ru.user_time + ru.system_time;
                   raw.disk = ru.diskio_bytesread + ru.diskio_byteswritten;
                   raw.energy = ru.energy_nj;
                   raw.memory = ru.phys_footprint;
                   if (count_threads and proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) raw.threads = @intCast(@max(0, ti.threadnum));
               }
               r.items.appendAssumeCapacity(raw);
           }
       }
   };
   ```

   `Reading.read` touches no `Sampler`. That is what makes it safe on another thread.

2. In `Sampler`, replace the field `pids: []c_int = &.{},` with `reading: Reading,`.

3. In `Sampler.init`, add `.reading = .{ .gpa = gpa },` to the returned struct literal.

4. In `Sampler.deinit`, replace `if (s.pids.len > 0) s.gpa.free(s.pids);` with `s.reading.deinit();`.

5. Replace the whole `Sampler.sample` function with:

   ```zig
       pub fn sample(s: *Sampler, now: f64) void {
           s.reading.read(s.count_threads);
           s.apply(s.reading.items.items, now);
       }

       pub fn apply(s: *Sampler, raws: []const Raw, now: f64) void {
           s.procs.clearRetainingCapacity();
           s.procs.ensureTotalCapacity(s.gpa, raws.len) catch return;
           s.cache.ensureUnusedCapacity(s.gpa, @intCast(raws.len)) catch return;
           s.gone.ensureTotalCapacity(s.gpa, s.cache.count()) catch return;
           const wall = now - s.prev_wall;
           const gen = s.samples + 1;
           s.system.power = 0;
           s.system.threads = 0;
           for (raws) |raw| {
               const k = s.lookUp(raw.pid, raw.start, raw.uuid) orelse continue;
               k.seen = gen;
               var p: Proc = .{ .pid = raw.pid, .uid = k.uid, .name = k.name, .bundle = k.bundle, .user = k.user };
               if (raw.readable) {
                   const t = raw.cpu_ticks * s.num / s.den;
                   p.memory = raw.memory;
                   p.cpu_time_ns = t;
                   p.known = true;
                   p.threads = raw.threads;
                   if (s.samples > 0 and wall > 0) if (k.prev) |before| {
                       const wall_ns = wall * std.time.ns_per_s;
                       p.cpu = @floatCast(@as(f64, @floatFromInt(t -| before.time_ns)) / wall_ns * percent);
                       p.disk_rate = @floatCast(@as(f64, @floatFromInt(raw.disk -| before.disk)) / wall);
                       p.energy = @floatCast(@as(f64, @floatFromInt(raw.energy -| before.energy)) / wall_ns);
                       s.system.power += p.energy;
                   };
                   k.prev = .{ .time_ns = t, .disk = raw.disk, .energy = raw.energy };
               }
               s.system.threads += p.threads;
               s.procs.appendAssumeCapacity(p);
           }
           s.forget(gen);
           s.prev_wall = now;
           s.readSystem();
           s.samples += 1;
       }
   ```

   An unreadable process has `start` 0 and a zero `uuid` in `Raw`, which is
   what the old code passed to `lookUp`. The arithmetic is the old arithmetic.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests, including the new test from step 2. Commit this step on its own.

### Step 4: Write the reader-thread test and watch it fail

Add to `src/tests.zig`, after the test from step 2:

```zig
test "with a reader thread, a tick starts a sample and the main queue finishes it" {
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    a.async_sampling = true;
    _ = a.tick(10);
    try std.testing.expectEqual(@as(usize, 0), a.sampler.samples);
    var spins: usize = 0;
    while (a.sampler.samples == 0 and spins < max_spins) : (spins += 1) spin();
    try std.testing.expectEqual(@as(usize, 1), a.sampler.samples);
    try std.testing.expect(a.sampler.find(a.sampler.self_pid) != null);
    try std.testing.expect(a.everyone.groups.items.len > 0);
    _ = a.tick(20);
    spins = 0;
    while (a.sampler.samples == 1 and spins < max_spins) : (spins += 1) spin();
    try std.testing.expectEqual(@as(usize, 2), a.sampler.samples);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="reader thread"` → the build FAILS because `App` has no field `async_sampling`.

### Step 5: Add the reader thread to `src/app.zig`

1. Add at file level, at the end of the file:

   ```zig
   const Reader = struct {
       gpa: std.mem.Allocator,
       app: *App,
       reading: procs.Reading,
       thread: ?std.Thread = null,
       mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
       cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
       wanted: bool = false,
       stop: bool = false,
       count_threads: bool = true,
       posted: bool = false,
       busy: bool = false,
       orphan: bool = false,
       at: f64 = 0,

       fn request(r: *Reader, t: f64, count_threads: bool) void {
           if (r.busy) return;
           r.busy = true;
           _ = std.c.pthread_mutex_lock(&r.mutex);
           r.at = t;
           r.count_threads = count_threads;
           r.wanted = true;
           _ = std.c.pthread_cond_signal(&r.cond);
           _ = std.c.pthread_mutex_unlock(&r.mutex);
       }

       fn work(r: *Reader) void {
           while (true) {
               _ = std.c.pthread_mutex_lock(&r.mutex);
               while (!r.wanted and !r.stop) _ = std.c.pthread_cond_wait(&r.cond, &r.mutex);
               const stop = r.stop;
               const count_threads = r.count_threads;
               r.wanted = false;
               if (!stop) r.posted = true;
               _ = std.c.pthread_mutex_unlock(&r.mutex);
               if (stop) return;
               r.reading.read(count_threads);
               nanoui.objc.dispatchMain(r, arrived);
           }
       }

       fn arrived(ctx: ?*anyopaque) callconv(.c) void {
           const r: *Reader = @ptrCast(@alignCast(ctx));
           if (r.orphan) return r.free();
           r.posted = false;
           r.busy = false;
           r.app.finishSample(r.reading.items.items, r.at);
           if (r.app.window) |w| w.redraw();
       }

       fn close(r: *Reader) void {
           if (r.thread) |th| {
               _ = std.c.pthread_mutex_lock(&r.mutex);
               r.stop = true;
               _ = std.c.pthread_cond_signal(&r.cond);
               _ = std.c.pthread_mutex_unlock(&r.mutex);
               th.join();
           }
           if (r.posted) r.orphan = true else r.free();
       }

       fn free(r: *Reader) void {
           r.reading.deinit();
           r.gpa.destroy(r);
       }
   };
   ```

   Why `posted` and `orphan` exist: `close` can run while an `arrived` call is
   already queued on the main queue. The queue still holds the pointer, so
   `close` must not free the reader. It marks it, and the queued call frees it.
   After `th.join()` the thread is gone, so reading `r.posted` on the main
   thread is safe.

2. Add two `App` fields, directly after the `alive` field that plan 008 added:

   ```zig
       async_sampling: bool = false,
       reader: ?*Reader = null,
   ```

3. Replace `App.sample` with these four methods:

   ```zig
       fn sample(a: *App, t: f64) void {
           if (a.async_sampling) if (a.readerThread()) |r| {
               r.request(t, a.sampler.count_threads);
               a.last = t;
               return;
           };
           a.sampler.sample(t);
           a.sampled(t);
       }

       fn readerThread(a: *App) ?*Reader {
           if (a.reader) |r| return r;
           const r = a.gpa.create(Reader) catch return null;
           r.* = .{ .gpa = a.gpa, .app = a, .reading = .{ .gpa = a.gpa } };
           r.thread = std.Thread.spawn(.{}, Reader.work, .{r}) catch {
               a.gpa.destroy(r);
               return null;
           };
           a.reader = r;
           return r;
       }

       pub fn finishSample(a: *App, raws: []const procs.Raw, t: f64) void {
           a.sampler.apply(raws, t);
           a.sampled(t);
       }

       fn sampled(a: *App, t: f64) void {
           a.metrics.sample(t, a.sampler.system.power);
           a.awake_count = iokit.assertions(&a.awake);
           a.everyone.build(a.sampler.procs.items, .{ .show = .all, .sort = .memory, .uid = a.sampler.uid }, &no_expanded) catch {};
           a.noteUsage();
           a.last = t;
           if (a.sampler.samples == 1) a.last = t - interval + second_sample_after;
       }
   ```

   When the thread cannot start, `sample` falls back to the synchronous path.
   `a.last = t` after a request keeps `tick` from asking again for 2 seconds.

4. In `App.deinit`, add as the first two lines:

   ```zig
           if (a.reader) |r| r.close();
           a.reader = null;
   ```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="reader thread"` → passes. Run it five times in a row. All five runs must pass, with no leak report.

### Step 6: Turn it on for the app and keep the bench honest

1. In `src/main.zig`, in `start`, add directly after `a.clock = seconds;`:

   ```zig
       a.async_sampling = true;
   ```

2. In `src/bench.zig`, replace `Bench.sampling` with:

   ```zig
       fn sampling(b: *Bench) !void {
           var times: [20]f64 = undefined;
           var applies: [20]f64 = undefined;
           b.a.async_sampling = false;
           defer b.a.async_sampling = true;
           for (&times, &applies) |*s, *m| {
               b.a.last = @import("app.zig").never_sampled;
               const t = seconds();
               _ = b.a.tick(t);
               s.* = ms(t);
               b.a.sampler.reading.read(b.a.sampler.count_threads);
               const applied = seconds();
               b.a.finishSample(b.a.sampler.reading.items.items, applied);
               m.* = ms(applied);
           }
           try b.putStats("sample", &times);
           try b.putStats("sample_main", &applies);
       }
   ```

   `sample` stays the cost of a whole synchronous sample. `sample_main` is the
   new number that matters: the time the main thread spends per sample.

3. In the `budgets` table, add two rows directly after the `sample_p95_ms` row:

   ```zig
       .{ .name = "sample_main_p50_ms", .budget = 4, .target = 1 },
       .{ .name = "sample_main_p95_ms", .budget = 6, .target = 1.5 },
   ```

**Verify**: `mise exec zig@0.17.0 -- zig build` → exit 0. Then `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests.

### Step 7: Run the bench when a display is available

Skip this step without a logged-in desktop, and say so in your report.

Run `mise exec zig@0.17.0 -- zig build bench 2>&1 | rg 'sample_'`.

**Verify**: `sample_main_p50_ms` and `sample_main_p95_ms` print with `"ok": true`. Put all `sample_` values in your report.

## Test plan

- `"a reading taken apart from the sampler applies to the same result as a sample"`: the split keeps the sampler's results, with and without thread counts.
- `"with a reader thread, a tick starts a sample and the main queue finishes it"`: `tick` returns before any sample exists, the sample arrives through the main queue, and a second request works after the first arrived.
- Every existing test runs the synchronous path, which is the default. They are the check that behaviour did not change.

## Done criteria

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests, five runs in a row
- [ ] `rg -n 'pthread_mutex' src/procs.zig` prints nothing
- [ ] `rg -n 'nanoui' src/procs.zig` prints nothing
- [ ] `rg -n 'async_sampling = true' src/main.zig` prints one match
- [ ] `rg -n 'sample_main_p50_ms' src/bench.zig` prints one match
- [ ] `git status --short` lists only `src/procs.zig`, `src/app.zig`, `src/main.zig`, `src/bench.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `count_threads` is missing from `src/procs.zig`.
- An excerpt in "Current state" does not match the live code.
- Step 1 reports a `sample_p50_ms` value below 3.
- A new test builds before its fix exists.
- The reader-thread test fails or reports a leak in any of the five runs. Report the output. Do not add sleeps or retries to the test.
- You find a reason to read or write `a.sampler` from `Reader.work`. The design forbids it.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The rule that keeps this safe: `Reader.work` touches only `r.reading` and the fields under `r.mutex`. Everything else in `Reader`, and all of `Sampler`, belongs to the main thread. A reviewer must check `work` line by line against that rule.
- A process can exit between the read and the apply. `Sampler.lookUp` then fails for a new pid and the process is skipped, or a cached pid shows its last numbers for one sample. Both are harmless.
- CPU percentages use the time passed to `apply`. With the thread, that is the request time, a few milliseconds before the read. The error is under 1% of a 2 second interval.
- After `App.run` returns, a queued `arrived` call never runs, and the orphaned reader is not freed. The process exits right after, so nothing is lost. `plans/README.md` lists this class of queued callback under "Findings considered and rejected".
- `docs/state-machines.md` describes the worker-thread pattern. It needs a row for the reader after this lands. The executor does not edit it.
