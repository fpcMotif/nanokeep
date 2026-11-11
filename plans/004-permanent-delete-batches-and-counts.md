# Plan 004: Emptying the Trash works in batches and counts each item

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/cleaner.zig`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. Plan 003
> changes one string in this file, and that is expected. Line numbers can move,
> so find code by symbol name. On a mismatch in the code itself, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/002-run-capture-signal-and-read-errors.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-10
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/6

## Why this matters

The Trash category is the only place nanokeep deletes files for good. It passes
every Trash item to one `/bin/rm -rf --` command. Three things go wrong:

1. When one item cannot be deleted, `rm` exits 1 after deleting the others, and
   nanokeep then reports 0 bytes deleted and 1 failure.
2. A Trash with many thousands of items can exceed the system's argument size
   limit (about 1 MiB on macOS). The spawn fails and nothing is deleted.
3. When memory allocation fails while the action list is built, items are
   dropped without being counted. One path can also crash: an item marked as a
   worktree whose repo path failed to copy is later unwrapped with `a.repo.?`.

After this plan, deletion runs in batches of 100 paths, each item is counted by
whether it is really gone, and skipped items show up as failures.

## Current state

All code is in `src/cleaner.zig`.

- Constants and types (lines 20, 126-138):

  ```zig
  const rm_forever = [_][]const u8{ "/bin/rm", "-rf", "--" };
  ```

  ```zig
  pub const Result = struct {
      moved: u64 = 0,
      deleted: u64 = 0,
      failed: u32 = 0,
  };
  ...
  const How = enum { trash, forever, worktree };

  const Action = struct { path: [:0]u8, repo: ?[:0]u8, how: How, bytes: u64 };
  ```

- `perform` (lines 260-290):

  ```zig
  fn perform(gpa: std.mem.Allocator, actions: []const Action, trash_fn: TrashFn) Result {
      var r: Result = .{};
      var forever: std.ArrayList([]const u8) = .empty;
      defer forever.deinit(gpa);
      forever.appendSlice(gpa, &rm_forever) catch return r;
      var forever_bytes: u64 = 0;
      for (actions) |a| switch (a.how) {
          .trash => if (trash_fn(a.path)) {
              r.moved += a.bytes;
          } else {
              r.failed += 1;
          },
          .worktree => if (worktree.remove(gpa, a.repo.?, a.path)) {
              r.deleted += a.bytes;
          } else {
              r.failed += 1;
          },
          .forever => {
              forever.append(gpa, a.path) catch continue;
              forever_bytes += a.bytes;
          },
      };
      if (forever.items.len > rm_forever.len) {
          const done = run.capture(gpa, forever.items) catch null;
          if (done) |d| {
              d.deinit(gpa);
              if (d.code == 0) r.deleted += forever_bytes else r.failed += 1;
          } else r.failed += 1;
      }
      return r;
  }
  ```

- `Job` (starts at line 292) has these fields among others:
  `cl: *Cleaner, env: Env, clean: bool, actions: []Action = &.{}, result: Result = .{}`.
  In `Job.execute` (lines 311-315):

  ```zig
          if (j.clean) {
              j.result = perform(j.cl.gpa, j.actions, j.cl.trash_fn);
              return;
          }
  ```

- `Cleaner.clean` (lines 464-481):

  ```zig
      pub fn clean(cl: *Cleaner) void {
          if (cl.job != null) return;
          var actions: std.ArrayList(Action) = .empty;
          for (&cl.cats) |*c| {
              if (!c.selected) continue;
              for (c.items()) |it| {
                  const how: How = if (it.repo != null) .worktree else if (c.spec.forever) .forever else .trash;
                  const path = cl.gpa.dupeSentinel(u8, it.path, 0) catch continue;
                  const repo = if (it.repo) |r| cl.gpa.dupeSentinel(u8, r, 0) catch null else null;
                  actions.append(cl.gpa, .{ .path = path, .repo = repo, .how = how, .bytes = it.size.bytes }) catch {
                      cl.gpa.free(path);
                      if (repo) |r| cl.gpa.free(r);
                  };
              }
          }
          const owned = actions.toOwnedSlice(cl.gpa) catch return actions.deinit(cl.gpa);
          cl.start(.{ .cl = cl, .env = cl.env(), .clean = true, .actions = owned }, .cleaning);
      }
  ```

- `access` and `F_OK` are already declared at the top of the file (lines 10, 17):
  `extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;` and `const F_OK = 0;`.
- `Result.failed` feeds one toast in `src/app.zig:186`: any value above 0 shows
  "Cleaned, with some left". Changing what `failed` counts (items, not batches) does not break it.
- After a clean, `Cleaner.complete` stores the result in `cl.last` and starts a new scan.
  Tests read `cl.last.?` after `cl.clean()`.
- The test to copy as the pattern (`src/tests.zig:465-506`,
  `"cleaning trashes only selected categories, and stale temporary files only"`). Its setup lines:

  ```zig
      const t = try Tmp.make();
      defer t.remove();
      defer clearTrashed();
      try t.sh("mkdir -p home/Library/Caches/com.vendor.app ... tmp/fresh ...", .{});
      var hb: [128]u8 = undefined;
      var tb: [128]u8 = undefined;
      var cl: cleaner.Cleaner = .init(gpa, try t.sub(&hb, "home"), try t.sub(&tb, "tmp/"));
      defer cl.deinit();
      cl.trash_fn = recordTrash;
      cl.sync = true;
      cl.scan();
  ```

  `cl.sync = true` runs scan and clean on the calling thread. `recordTrash` records
  paths in the global list `trashed` and moves nothing. `duBytes(path)` returns the
  size on disk that `du` reports. `cl.cats[@intFromEnum(cleaner.Kind.trash)]` is the Trash category.
- Conventions: all tests live in `src/tests.zig`, named as a sentence. `gpa` in tests is
  `std.testing.allocator` and fails a test that leaks. The code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| These tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="Trash"` | all pass |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/cleaner.zig` (`perform`, a new helper, `Job`, `Cleaner.clean`)
- `src/tests.zig` (add tests only)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- `measureCategory`, `listSource`, `listSessions` and the `specs` table.
- `src/run.zig`, `src/worktree.zig`, `src/app.zig`, `src/view_clean.zig`.
- Rechecking items before deletion. Plan 005 does that.
- Do not run `zig fmt` on whole files. `src/cleaner.zig` and `src/tests.zig` already
  differ from `zig fmt` output, and formatting them creates unrelated diffs.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/004-permanent-delete-batches`
- Conventional commits. Use: `fix(clean): delete for good in batches and count each item`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the tests first

In `src/tests.zig`, directly after the test
`"cleaning trashes only selected categories, and stale temporary files only"`, add:

```zig
test "emptying the Trash counts each item, and one that can't be deleted doesn't hide the rest" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p home/.Trash/stuck tmp && dd if=/dev/urandom of=home/.Trash/good bs=4096 count=5 2>/dev/null && dd if=/dev/urandom of='home/.Trash/-rf two words' bs=4096 count=3 2>/dev/null && touch home/.Trash/stuck/held && chflags uchg home/.Trash/stuck/held", .{});
    defer t.sh("chflags -R nouchg home", .{}) catch {};
    var hb: [128]u8 = undefined;
    var tb: [128]u8 = undefined;
    var cl: cleaner.Cleaner = .init(gpa, try t.sub(&hb, "home"), try t.sub(&tb, "tmp/"));
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    const trash = &cl.cats[@intFromEnum(cleaner.Kind.trash)];
    try std.testing.expectEqual(@as(usize, 3), trash.items().len);
    var gb: [160]u8 = undefined;
    var wb: [160]u8 = undefined;
    const freed = try duBytes(try t.sub(&gb, "home/.Trash/good")) + try duBytes(try t.sub(&wb, "home/.Trash/-rf two words"));
    for (&cl.cats) |*c| c.selected = c.spec.kind == .trash;
    cl.clean();
    try std.testing.expectEqual(freed, cl.last.?.deleted);
    try std.testing.expectEqual(@as(u32, 1), cl.last.?.failed);
    try std.testing.expectEqual(@as(usize, 0), trashed.items.len);
    try t.sh("test ! -e home/.Trash/good && test ! -e 'home/.Trash/-rf two words' && test -e home/.Trash/stuck/held", .{});
}

test "emptying a Trash with more items than one batch deletes all of them" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p home/.Trash tmp && cd home/.Trash && for i in $(seq 1 250); do touch f$i; done", .{});
    var hb: [128]u8 = undefined;
    var tb: [128]u8 = undefined;
    var cl: cleaner.Cleaner = .init(gpa, try t.sub(&hb, "home"), try t.sub(&tb, "tmp/"));
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    try std.testing.expectEqual(@as(usize, 250), cl.cats[@intFromEnum(cleaner.Kind.trash)].items().len);
    for (&cl.cats) |*c| c.selected = c.spec.kind == .trash;
    cl.clean();
    try std.testing.expectEqual(@as(u32, 0), cl.last.?.failed);
    try t.sh("test -z \"$(ls -A home/.Trash)\"", .{});
}
```

`chflags uchg` makes a file immutable, so `rm` cannot delete it. The `defer` with
`chflags -R nouchg` runs before `t.remove()` and lets the temp folder be cleaned up.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="Trash"` →
the first new test FAILS on `cl.last.?.deleted` (it is 0). The second new test passes.
If the first new test passes before the fix, STOP.

### Step 2: Batch the deletion and count per item

In `src/cleaner.zig`:

1. Below the `rm_forever` constant, add `const forever_batch = 100;`.

2. Replace `perform` with this shape, and add `deleteForever` above it:

   ```zig
   fn deleteForever(gpa: std.mem.Allocator, batch: []const Action, r: *Result) void {
       var argv: std.ArrayList([]const u8) = .empty;
       defer argv.deinit(gpa);
       const ran = ran: {
           argv.appendSlice(gpa, &rm_forever) catch break :ran false;
           for (batch) |a| argv.append(gpa, a.path) catch break :ran false;
           const done = run.capture(gpa, argv.items) catch break :ran false;
           done.deinit(gpa);
           break :ran true;
       };
       for (batch) |a| {
           if (ran and access(a.path, F_OK) != 0) r.deleted += a.bytes else r.failed += 1;
       }
   }

   fn perform(gpa: std.mem.Allocator, actions: []const Action, trash_fn: TrashFn) Result {
       var r: Result = .{};
       var forever: std.ArrayList(Action) = .empty;
       defer forever.deinit(gpa);
       for (actions) |a| switch (a.how) {
           .trash => if (trash_fn(a.path)) {
               r.moved += a.bytes;
           } else {
               r.failed += 1;
           },
           .worktree => if (worktree.remove(gpa, a.repo.?, a.path)) {
               r.deleted += a.bytes;
           } else {
               r.failed += 1;
           },
           .forever => forever.append(gpa, a) catch {
               r.failed += 1;
           },
       };
       var rest: []const Action = forever.items;
       while (rest.len > 0) {
           const n = @min(rest.len, forever_batch);
           deleteForever(gpa, rest[0..n], &r);
           rest = rest[n..];
       }
       return r;
   }
   ```

   The exit code of `rm` is not used on purpose. An item counts as deleted when
   its path no longer exists. This snippet was not compiled by the plan's
   author. If the compiler rejects a detail, make the smallest syntax change that keeps this behavior.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="Trash"` → all pass.

### Step 3: Count items skipped while the action list is built

1. In `Job`, add the field `skipped: u32 = 0,` next to `result`.
2. In `Job.execute`, after `j.result = perform(...)`, add `j.result.failed += j.skipped;`.
3. In `Cleaner.clean`, replace the inner loop body so that a failed copy skips the whole item and is counted:

   ```zig
       pub fn clean(cl: *Cleaner) void {
           if (cl.job != null) return;
           var actions: std.ArrayList(Action) = .empty;
           var skipped: u32 = 0;
           for (&cl.cats) |*c| {
               if (!c.selected) continue;
               for (c.items()) |it| {
                   const how: How = if (it.repo != null) .worktree else if (c.spec.forever) .forever else .trash;
                   const path = cl.gpa.dupeSentinel(u8, it.path, 0) catch {
                       skipped += 1;
                       continue;
                   };
                   const repo: ?[:0]u8 = if (it.repo) |from| cl.gpa.dupeSentinel(u8, from, 0) catch {
                       cl.gpa.free(path);
                       skipped += 1;
                       continue;
                   } else null;
                   actions.append(cl.gpa, .{ .path = path, .repo = repo, .how = how, .bytes = it.size.bytes }) catch {
                       cl.gpa.free(path);
                       if (repo) |r| cl.gpa.free(r);
                       skipped += 1;
                   };
               }
           }
           const owned = actions.toOwnedSlice(cl.gpa) catch return actions.deinit(cl.gpa);
           cl.start(.{ .cl = cl, .env = cl.env(), .clean = true, .actions = owned, .skipped = skipped }, .cleaning);
       }
   ```

   After this change an action with `how == .worktree` always has a non-null `repo`.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests. The total is the earlier total plus 2.

## Test plan

- Two new tests in `src/tests.zig` (step 1):
  - partial failure: one immutable item stays, the others are deleted and their bytes are counted. A name that starts with `-rf` and contains spaces is deleted like any other;
  - 250 items, more than two batches, are all deleted with zero failures.
- The allocation-failure paths of step 3 have no test. Forcing them needs a failing
  allocator inside `Cleaner`, which is out of scope. Code review covers them.
- Existing tests `"cleaning trashes only selected categories, and stale temporary files only"`
  and `"cleaning the developer category removes clean worktrees with git"` must pass unchanged.

## Done criteria

ALL must hold:

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] Both new tests exist and pass
- [ ] `grep -c "forever_bytes" src/cleaner.zig` prints `0`
- [ ] `grep -c "forever_batch" src/cleaner.zig` prints `2`
- [ ] `grep -c "catch null else null" src/cleaner.zig` prints `0`
- [ ] `git status --porcelain` lists only `src/cleaner.zig`, `src/tests.zig` and `plans/README.md`
- [ ] No folder named `nanokeep-test-*` that you created is left in `/tmp` with an immutable file
      (`ls -d /tmp/nanokeep-test-* 2>/dev/null` prints nothing after the tests end)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The excerpts in "Current state" do not match the code (other than line numbers and the Developer `.note` string).
- The first new test passes before the fix in step 2.
- `chflags uchg` does not stop `rm` on your machine (the test then cannot prove partial failure).
- An existing cleaner test fails after step 2 or step 3.

## Maintenance notes

- `access` follows symbolic links. A dangling symbolic link that `rm` failed to
  remove would count as deleted. That case is rare and was accepted.
- `Result.failed` now counts items, not `rm` runs. If the UI ever shows the number, that is the meaning.
- `actions.toOwnedSlice` failing still drops the whole list without freeing the copied paths. It was left as it is, because it needs an allocation failure at one exact point.
- Plan 005 adds a recheck inside `perform` before each action. It builds on the shape from step 2.
- Reviewer: check that no test leaves an immutable file behind in `/tmp`.
