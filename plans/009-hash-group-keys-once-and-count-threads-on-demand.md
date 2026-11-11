# Plan 009: A table build hashes each process once, and thread counts are read only where shown

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/groups.zig` and `rg -n 'fn settleQuits' src/app.zig`
> `src/groups.zig` must show no change. The second command must print one
> match. If it prints nothing, plan 008 has not landed: STOP. Then compare the
> "Current state" excerpts against the live code. On a mismatch, STOP.

## At a glance

Every sample spends time on two things nobody sees: the group sort hashes a
path string on every comparison, and one system call per process reads a
thread count that only two pages show. This plan hashes each process once per
table build and reads thread counts only on the Processes and CPU pages. What
the tables show, their order and the search results stay the same.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/008-quit-asks-apps-and-confirms-exit.md (both edit `App.tick`)
- **Category**: perf
- **Planned at**: commit `b83f7d8`, 2026-11-17

## Why this matters

nanokeep samples every 2 seconds on the main thread, so sample time is time
the window cannot respond. Measured on 2026-11-17 on the audited Mac, with 818
processes, ReleaseFast, median of 20 runs:

| Part | Time |
|---|---|
| `Sampler.sample`, whole | 3.57 ms |
| The `PROC_PIDTASKINFO` call for every process, alone | 1.66 ms |

The thread-count call is close to half of the sampler's time. It feeds one
column on the Processes page and one line on the CPU page.

The sort cost is an estimate, not a measurement: a build of 818 processes
makes about 16,000 comparisons, and each comparison hashes two path strings.
Each sample builds two tables, and each keystroke in the search field builds
one.

## Current state

`src/groups.zig:42-44`:

```zig
pub fn keyOf(p: *const Proc) u64 {
    return std.hash.Wyhash.hash(0, if (p.bundle.len > 0) p.bundle else p.name);
}
```

`src/groups.zig:62-75`:

```zig
pub const Table = struct {
    gpa: std.mem.Allocator,
    groups: std.ArrayList(Group) = .empty,
    members: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(Row) = .empty,
    ranks: std.ArrayList(i32) = .empty,
    shown: usize = 0,

    pub fn deinit(t: *Table) void {
        t.ranks.deinit(t.gpa);
        t.groups.deinit(t.gpa);
        t.members.deinit(t.gpa);
        t.rows.deinit(t.gpa);
    }
```

`src/groups.zig:77-116`, the first half of `Table.build`:

```zig
    pub fn build(t: *Table, items: []const Proc, o: Options, expanded: *const std.AutoHashMapUnmanaged(u64, void)) !void {
        t.groups.clearRetainingCapacity();
        t.members.clearRetainingCapacity();
        t.rows.clearRetainingCapacity();
        t.shown = 0;
        var picked: std.ArrayList(u32) = .empty;
        defer picked.deinit(t.gpa);
        try t.ranks.resize(t.gpa, items.len);
        for (items, 0..) |*p, i| {
            if (!shown(p, o)) continue;
            t.ranks.items[i] = 0;
            if (o.query.len > 0) t.ranks.items[i] = match(p, o.query) orelse continue;
            try picked.append(t.gpa, @intCast(i));
        }
        t.shown = picked.items.len;
        const Ctx = struct {
            items: []const Proc,
            o: Options,
            fn lt(c: @This(), a: u32, b: u32) bool {
                const ka = keyOf(&c.items[a]);
                const kb = keyOf(&c.items[b]);
                if (ka != kb) return ka < kb;
                return before(c.items[a].cpu, c.items[a].memory, c.items[b].cpu, c.items[b].memory, c.o);
            }
        };
        std.mem.sort(u32, picked.items, Ctx{ .items = items, .o = o }, Ctx.lt);
        for (picked.items) |i| {
            const p = &items[i];
            const k = keyOf(p);
            if (t.groups.items.len == 0 or t.groups.items[t.groups.items.len - 1].key != k) {
```

`src/procs.zig`, inside `Sampler.sample` (line 273 at commit `b83f7d8`):

```zig
                if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) p.threads = @intCast(@max(0, ti.threadnum));
```

Who reads thread counts (`rg -n '\.threads' src` at commit `b83f7d8`):

- `src/view_procs.zig`: the Threads column on the Processes page, and sorting by it.
- `src/view_hw.zig:139`: one "Threads" line inside `cpuPage`.
- `src/groups.zig`: sums them into each group.

`App.tick` in `src/app.zig`, as plan 008 leaves it:

```zig
    pub fn tick(a: *App, t: f64) f32 {
        a.settleQuits(t);
        if (a.live and t - a.last >= interval) a.sample(t);
        a.refresh();
        const wait = @max(min_wait, interval - (t - a.last));
        return @floatCast(if (a.leaving_count > 0) @min(wait, quit_poll) else wait);
    }
```

`pub const Page = enum { overview, processes, cpu, memory, gpu, disk, network, energy, apps, cleanup, about };`
and `pub const never_sampled = -std.math.inf(f64);` are in the same file.
`a.page` is the current page. Setting `a.last = never_sampled` makes the next
`tick` sample at once.

The sampler already counts work for tests: `Sampler.lookups` is a counter that
the test `"a sample looks up names only for processes that are new since the last one"`
reads. This plan follows that pattern.

Conventions in this repo:

- Do not add comments. Names carry the meaning.
- Do not format whole files.
- Test names are full sentences that state the requirement.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| New tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="once per"` and `-Dtest-filter="thread counts"` | pass |

Do not use a bare `zig`.

## Scope

**In scope** (the only files you should modify):
- `src/groups.zig` (`Table`, `Table.build`)
- `src/procs.zig` (one field and one condition in `Sampler`)
- `src/app.zig` (`tick` and one new method)
- `src/tests.zig` (two new tests)

**Out of scope** (do NOT touch, even though they look related):
- `src/fuzzy.zig` and the `match` function. Search takes 0.04 ms per keystroke (commit `db4fb7a`). It is not a cost worth changing.
- `Proc` and `Known`. Do not add a key field to them. Tests build `Proc` values by hand, and a stored key would be 0 there.
- `App.heartbeat`. See "Maintenance notes".
- Every Markdown file except your status row in `plans/README.md`.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/009-cheaper-sample`
- Conventional commits, one per part. Use: `perf(groups): hash each process once per table build` and `perf(procs): read thread counts only on the pages that show them`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the table test and watch it fail

Add to `src/tests.zig`, after the test `"searching processes ranks groups by match, and a picked app wins a tie"`:

```zig
test "a table build hashes each shown process once per build" {
    const zed = "/Applications/Zed.app";
    const items = [_]procs.Proc{
        .{ .pid = 10, .uid = me_uid, .name = "Zed", .bundle = zed, .memory = 300 },
        .{ .pid = 11, .uid = me_uid, .name = "Zed Helper", .bundle = zed, .memory = 200 },
        .{ .pid = 12, .uid = me_uid, .name = "zsh", .memory = 100 },
        .{ .pid = 13, .uid = me_uid + 1, .name = "other", .memory = 50 },
    };
    var t: groups.Table = .{ .gpa = gpa };
    defer t.deinit();
    const none: std.AutoHashMapUnmanaged(u64, void) = .empty;
    try t.build(&items, .{ .show = .mine, .uid = me_uid }, &none);
    try std.testing.expectEqual(@as(usize, 3), t.hashes);
    try std.testing.expectEqual(@as(usize, 2), t.groups.items.len);
    try t.build(&items, .{ .show = .mine, .uid = me_uid }, &none);
    try std.testing.expectEqual(@as(usize, 6), t.hashes);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="once per"` → the build FAILS because `Table` has no field `hashes`. That is the expected red state.

### Step 2: Hash once in `Table.build`

In `src/groups.zig`:

1. Add two fields to `Table`, after `ranks`:

   ```zig
       keys: std.ArrayList(u64) = .empty,
       hashes: usize = 0,
   ```

2. Add `t.keys.deinit(t.gpa);` as the first line of `Table.deinit`.

3. In `build`, add `try t.keys.resize(t.gpa, items.len);` directly after `try t.ranks.resize(t.gpa, items.len);`.

4. In the first loop of `build`, add two lines directly before `try picked.append(t.gpa, @intCast(i));`:

   ```zig
               t.keys.items[i] = keyOf(p);
               t.hashes += 1;
   ```

5. Replace `Ctx` and the sort call with:

   ```zig
           const Ctx = struct {
               items: []const Proc,
               keys: []const u64,
               o: Options,
               fn lt(c: @This(), a: u32, b: u32) bool {
                   const ka = c.keys[a];
                   const kb = c.keys[b];
                   if (ka != kb) return ka < kb;
                   return before(c.items[a].cpu, c.items[a].memory, c.items[b].cpu, c.items[b].memory, c.o);
               }
           };
           std.mem.sort(u32, picked.items, Ctx{ .items = items, .keys = t.keys.items, .o = o }, Ctx.lt);
   ```

6. In the loop after the sort, replace `const k = keyOf(p);` with `const k = t.keys.items[i];`.

`keyOf` stays public and unchanged. Other files call it.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="once per"` → passes. Then `rg -n 'keyOf\(' src/groups.zig` → exactly two matches: the definition and the line from item 4.

### Step 3: Write the thread-count test and watch it fail

Add to `src/tests.zig`, after the test `"the sampler reads this machine"`:

```zig
test "thread counts are read only on the pages that show them, and at once when one opens" {
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    a.page = .overview;
    _ = a.tick(10);
    const me = a.sampler.self_pid;
    try std.testing.expectEqual(@as(u32, 0), a.sampler.find(me).?.threads);
    try std.testing.expectEqual(@as(u64, 0), a.sampler.system.threads);
    a.page = .processes;
    _ = a.tick(10.5);
    try std.testing.expectEqual(@as(usize, 2), a.sampler.samples);
    try std.testing.expect(a.sampler.find(me).?.threads >= 1);
    a.page = .cpu;
    _ = a.tick(10.6);
    try std.testing.expectEqual(@as(usize, 2), a.sampler.samples);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="thread counts"` → FAILS at the first `expectEqual`, because the thread count on the Overview page is 1 or more today.

### Step 4: Read thread counts on demand

1. In `src/procs.zig`, add a field to `Sampler` after `lookups`:

   ```zig
       count_threads: bool = true,
   ```

2. In `Sampler.sample`, change the `PROC_PIDTASKINFO` line to start with the flag:

   ```zig
                   if (s.count_threads and proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) p.threads = @intCast(@max(0, ti.threadnum));
   ```

3. In `src/app.zig`, add a method next to `tick`:

   ```zig
       fn showsThreads(a: *const App) bool {
           return a.page == .processes or a.page == .cpu;
       }
   ```

4. In `tick`, add three lines directly after `a.settleQuits(t);`:

   ```zig
           const wanted = a.showsThreads();
           if (wanted and !a.sampler.count_threads) a.last = never_sampled;
           a.sampler.count_threads = wanted;
   ```

   When the user opens a page that shows thread counts, the sampler has none
   yet. Setting `a.last` makes this same `tick` take a sample, so the page
   never shows zeros.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="thread counts"` → passes.

### Step 5: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests.

If an existing test now fails because one more sample or one more table
rebuild happened after a page change, STOP and report the test name. Do not
change that test.

### Step 6: Record the bench numbers when a display is available

This step needs a logged-in desktop with the display awake. The bench window
must stay uncovered for about 2 minutes. If you run without one, skip this
step and say so in your report.

Run `mise exec zig@0.17.0 -- zig build bench 2>&1 | rg 'sample_p|keystroke_p'`.

**Verify**: four lines print. Put the four values in your report. No value is required: this step records the effect, it does not gate the plan.

## Test plan

- `"a table build hashes each shown process once per build"`: 3 of 4 processes are shown, so 3 hashes per build. It cannot pass with a hash in the comparator, because the counter sits where the single hash is.
- `"thread counts are read only on the pages that show them, and at once when one opens"`: fails today at its first check.
- The existing tests on groups, search and the sampler are the check that behaviour did not change.

## Done criteria

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] `rg -n 'keyOf\(' src/groups.zig` prints exactly two matches
- [ ] `rg -n 'count_threads' src/procs.zig src/app.zig` prints matches in both files
- [ ] `git status --short` lists only `src/groups.zig`, `src/procs.zig`, `src/app.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `fn settleQuits` is missing from `src/app.zig`.
- An excerpt in "Current state" does not match the live code.
- A new test passes before its fix exists.
- An existing test fails after step 4.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `App.heartbeat` samples while the window is hidden and does not call `tick`, so the flag keeps the value of the last visible page. A window hidden on the Processes page keeps counting threads. That is a small cost, accepted to keep `heartbeat` unchanged.
- A new view that shows thread counts must be added to `showsThreads`, or it shows zeros.
- `Table.hashes` exists for the test, like `Sampler.lookups`. Nothing in the app reads it.
- Not done on purpose: caching search scores per name, a letter mask to skip non-matches, and merging the two system readers in `src/procs.zig:327` and `src/metrics.zig:311`. Each saves microseconds.
