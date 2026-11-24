# Plan 005: Cleanup rechecks every item just before it acts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: this plan is written against the code as plans
> 003 and 004 leave it, not against commit `b83f7d8`. Run
> `grep -c "pub fn isRemovable" src/worktree.zig` and
> `grep -c "fn deleteForever" src/cleaner.zig`. Both must print `1`. If either
> prints `0`, plans 003 and 004 have not landed: STOP. Then compare the
> "Current state" excerpts against the live code. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/003-worktree-keep-unreferenced-commits.md, plans/004-permanent-delete-batches-and-counts.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-10
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/7

## Why this matters

Cleanup acts on the last scan, however old it is. The window can stay open for
hours between the scan and the click on "Clean". In that time a temporary file
that was "unchanged for three days" can be in use again, an agent session can
be resumed, and a clean worktree can gain work. nanokeep still moves or removes
them, because `Cleaner.clean` builds its action list from the old scan with no
recheck. After this plan, each item is checked again at the moment of action,
and an item that no longer qualifies is left alone and counted as kept.

## Current state

All excerpts show the code after plans 003 and 004. Line numbers are omitted
because they have moved. Find code by symbol name.

- `src/cleaner.zig`, age rules inside `measureCategory`:

  ```zig
      const age: ?i64 = switch (spec.kind) {
          .temporary => stale_seconds,
          .agents => session_age,
          else => null,
      };
  ```

  `stale_seconds` is 3 days and `session_age` is 30 days. Later in the same
  function, an item is dropped when `env.now - it.size.newest < min_age`.
  `it.size.newest` is the newest modification time found anywhere inside the item.

- `src/cleaner.zig`, the result and action types:

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

- `src/cleaner.zig`, `perform` as plan 004 leaves it:

  ```zig
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
      while (rest.len > 0) { ... deleteForever(gpa, rest[0..n], &r); ... }
      return r;
  }
  ```

- `src/cleaner.zig`, in `Job.execute`:

  ```zig
          if (j.clean) {
              j.result = perform(j.cl.gpa, j.actions, j.cl.trash_fn);
              j.result.failed += j.skipped;
              return;
          }
  ```

  `j.env.now` holds the time (seconds since 1970) when the clean started. It is set by `cl.env()` in `Cleaner.clean`.

- `src/cleaner.zig`, in `Cleaner.clean`, each action is appended like this:

  ```zig
                  actions.append(cl.gpa, .{ .path = path, .repo = repo, .how = how, .bytes = it.size.bytes }) catch {
  ```

  `c.spec.kind` is the category kind of the item in that loop.

- `src/worktree.zig` has, from plan 003:

  ```zig
  pub fn isRemovable(gpa: std.mem.Allocator, path: []const u8) bool {
      return isClean(gpa, path) and headIsReferenced(gpa, path);
  }
  ```

- `src/walk.zig` has a one-shot measure function:

  ```zig
  pub fn measure(gpa: std.mem.Allocator, p: [*:0]const u8) Size {
  ```

  The returned `Size` has the fields `bytes: u64`, `files: u64` and `newest: i64`.
  `src/cleaner.zig` already imports it as `const walk = @import("walk.zig");`.
- `access` and `F_OK` are declared at the top of `src/cleaner.zig`.
- The scan keeps its working memory in an arena on `std.heap.page_allocator`
  instead of the general allocator. `Job.execute` does this:

  ```zig
          var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
          defer scratch.deinit();
  ```

  Follow the same pattern for the re-measure in this plan.
- Test patterns in `src/tests.zig`:
  - `"cleaning trashes only selected categories, and stale temporary files only"` shows a
    cleaner on a temp home with `cl.trash_fn = recordTrash; cl.sync = true;`. `recordTrash`
    records each path in the global list `trashed` and always reports success.
  - `"cleaning the developer category removes clean worktrees with git"` shows a repo with a
    worktree under `devv/`, a cleaner built with `.init(gpa, t.path(), "")`, and
    `for (&cl.cats) |*c| c.selected = c.spec.kind == .developer;`.
- Conventions: all tests live in `src/tests.zig`, named as a sentence. `gpa` in tests is
  `std.testing.allocator` and fails a test that leaks. The code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| These tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="after the scan"` | all pass |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/cleaner.zig`
- `src/tests.zig` (add tests only)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- `src/worktree.zig`, `src/walk.zig`, `src/run.zig`.
- `src/app.zig` and `src/view_clean.zig`. Showing the kept count in the UI is a later decision.
- Any age rule for worktrees (for example "skip worktrees touched in the last day"). That is a product decision for the maintainer.
- Refusing to clean when the scan is old. The per-item recheck replaces that idea.
- Do not run `zig fmt` on whole files. `src/cleaner.zig` and `src/tests.zig` already
  differ from `zig fmt` output, and formatting them creates unrelated diffs.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/005-recheck-before-cleaning`
- Conventional commits. Use: `fix(clean): recheck each item just before it is cleaned`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the `kept` counter and write the failing tests

1. In `src/cleaner.zig`, add a field to `Result`: `kept: u32 = 0,`.
   This alone changes no behavior. It lets the new tests compile.

2. In `src/tests.zig`, directly after the test
   `"cleaning the developer category removes clean worktrees with git"`, add:

```zig
test "a temporary file changed after the scan is left alone, and one that vanished is not counted as failed" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p home tmp && printf a > tmp/busy.log && printf b > tmp/old.log && printf c > tmp/gone.log && touch -t 202001010000 tmp/busy.log tmp/old.log tmp/gone.log", .{});
    var hb: [128]u8 = undefined;
    var tb: [128]u8 = undefined;
    var cl: cleaner.Cleaner = .init(gpa, try t.sub(&hb, "home"), try t.sub(&tb, "tmp/"));
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    try std.testing.expectEqual(@as(usize, 3), cl.cats[@intFromEnum(cleaner.Kind.temporary)].items().len);
    try t.sh("touch tmp/busy.log && rm tmp/gone.log", .{});
    cl.clean();
    try std.testing.expectEqual(@as(usize, 1), trashed.items.len);
    try std.testing.expect(std.mem.endsWith(u8, trashed.items[0], "tmp/old.log"));
    try std.testing.expectEqual(@as(u32, 2), cl.last.?.kept);
    try std.testing.expectEqual(@as(u32, 0), cl.last.?.failed);
}

test "a worktree that gained unreferenced commits after the scan is kept" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q ../spare -b spare", .{});
    var cl: cleaner.Cleaner = .init(gpa, t.path(), "");
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    try std.testing.expectEqual(@as(usize, 1), cl.cats[@intFromEnum(cleaner.Kind.developer)].items().len);
    try t.sh("git -C devv/spare checkout -q --detach && git -C devv/spare -c user.email=t@t -c user.name=t commit -q --allow-empty -m lost", .{});
    for (&cl.cats) |*c| c.selected = c.spec.kind == .developer;
    cl.clean();
    try t.sh("test -e devv/spare", .{});
    try std.testing.expectEqual(@as(u32, 1), cl.last.?.kept);
    try std.testing.expectEqual(@as(u32, 0), cl.last.?.failed);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="after the scan"` →
both new tests FAIL (the first trashes 3 items, the second removes the worktree).
If either passes before step 2, STOP.

### Step 2: Carry the age rule on each action

In `src/cleaner.zig`:

1. Add a helper near `stale_seconds` and `session_age`:

   ```zig
   fn minAge(kind: Kind) ?i64 {
       return switch (kind) {
           .temporary => stale_seconds,
           .agents => session_age,
           else => null,
       };
   }
   ```

2. In `measureCategory`, replace the `switch` shown in "Current state" with
   `const age: ?i64 = minAge(spec.kind);`.

3. Add a field to `Action`: `min_age: ?i64 = null`.

4. In `Cleaner.clean`, add `.min_age = minAge(c.spec.kind)` to the action literal in the `actions.append` call.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="cleaning"` → the existing cleaning tests pass. The two new tests still fail.

### Step 3: Recheck inside `perform`

1. Add this function above `perform`:

   ```zig
   fn stillWanted(gpa: std.mem.Allocator, a: Action, now: i64) bool {
       if (a.how == .worktree) return worktree.isRemovable(gpa, a.path);
       if (access(a.path, F_OK) != 0) return false;
       const min_age = a.min_age orelse return true;
       return now - walk.measure(gpa, a.path).newest >= min_age;
   }
   ```

2. Change `perform` to take the time and to skip items that no longer qualify.
   Change only the signature and the first loop. Keep the batch loop for `forever` as it is.

   ```zig
   fn perform(gpa: std.mem.Allocator, actions: []const Action, trash_fn: TrashFn, now: i64) Result {
       var r: Result = .{};
       var forever: std.ArrayList(Action) = .empty;
       defer forever.deinit(gpa);
       var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
       defer scratch.deinit();
       for (actions) |a| {
           _ = scratch.reset(.retain_capacity);
           if (!stillWanted(scratch.allocator(), a, now)) {
               r.kept += 1;
               continue;
           }
           switch (a.how) {
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
           }
       }
       ...
   ```

3. In `Job.execute`, pass the time: `j.result = perform(j.cl.gpa, j.actions, j.cl.trash_fn, j.env.now);`.

This snippet was not compiled by the plan's author. If the compiler rejects a
detail, make the smallest syntax change that keeps this behavior.

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="after the scan"` → both new tests pass.

### Step 4: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests. The total is the earlier total plus 2.

## Test plan

- Two new tests in `src/tests.zig` (step 1):
  - temporary files: one touched after the scan is kept, one deleted after the scan is kept and not failed, one still old is trashed;
  - worktree: detached and given an unreferenced commit after the scan, it is not removed.
- These existing tests must pass unchanged. They prove that items that still qualify are cleaned as before:
  `"cleaning trashes only selected categories, and stale temporary files only"`,
  `"cleaning the developer category removes clean worktrees with git"`, and the two Trash tests from plan 004.

## Done criteria

ALL must hold:

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] Both new tests exist and pass
- [ ] `grep -c "fn stillWanted" src/cleaner.zig` prints `1`
- [ ] `grep -c "minAge(" src/cleaner.zig` prints `3` (the definition and two calls)
- [ ] `git status --porcelain` lists only `src/cleaner.zig`, `src/tests.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `isRemovable` or `deleteForever` does not exist (plans 003 and 004 have not landed).
- The excerpts in "Current state" do not match the code.
- A new test passes before step 3.
- An existing cleaning test fails after step 3. The recheck must not reject an item that still qualifies.
- The whole suite takes more than twice as long as before this plan (baseline is about 75 seconds). The recheck may be re-measuring more than intended.

## Maintenance notes

- The recheck re-walks each temporary item and agent session once. Sessions are
  single files, so that is cheap. A very large temporary folder is walked twice in total.
- An item that no longer exists now counts as kept, not failed. Before this plan a
  vanished item made the Trash call fail and showed "Cleaned, with some left".
- `Result.kept` is not shown in the UI yet. A toast such as "Left 2 items that changed" is a sensible follow-up.
- Open product decision, not made here: a worktree created minutes ago by an agent is
  clean and referenced, so it is still offered. A minimum age for worktrees would stop that.
- Reviewer: check that `stillWanted` runs before every destructive call, including the `forever` branch.
