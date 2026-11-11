# Plan 003: Cleanup never removes a worktree whose commits nothing else holds

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/worktree.zig src/cleaner.zig src/view_clean.zig`
> If any of these files changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. Line
> numbers can move when other plans land, so find code by symbol name. On a
> mismatch in the code itself, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/002-run-capture-signal-and-read-errors.md
- **Category**: bug
- **Planned at**: commit `b83f7d8`, 2026-11-10
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/5

## Why this matters

The Developer category of Cleanup removes git worktrees with
`git worktree remove`. nanokeep offers a worktree when `git status --porcelain`
prints nothing. That check misses two cases, both confirmed with git on
2026-11-10:

1. A worktree on a detached HEAD with commits that no branch or tag contains.
   `git worktree remove` succeeds, and those commits are then reachable only
   through the reflog. The UI promises "their branches and commits stay".
2. A repo with `status.showUntrackedFiles=no`. `git status --porcelain` prints
   nothing even when untracked files exist.

Agent tools create detached worktrees under `~/.codex/worktrees` and
`~/.claude/worktrees`, and both are scanned roots, so case 1 is realistic.
`git worktree remove` also deletes git-ignored files (for example a local
`.env`) without a warning, and the UI does not say so. After this plan,
unsafe worktrees are not offered, and the text tells the truth about ignored files.

## Current state

- `src/worktree.zig` finds and removes worktrees. `isClean` (lines 89-93):

  ```zig
  pub fn isClean(gpa: std.mem.Allocator, path: []const u8) bool {
      const st = run.capture(gpa, &.{ git, "-C", path, "status", "--porcelain" }) catch return false;
      defer st.deinit(gpa);
      return st.code == 0 and std.mem.trim(u8, st.out, " \n").len == 0;
  }
  ```

- The candidate filter inside `find` (lines 125-134):

  ```zig
          for (entries[1..]) |e| {
              if (e.locked or e.prunable or e.bare) continue;
              const path = try gpa.dupeSentinel(u8, e.path, 0);
              if (access(path, F_OK) != 0 or !isClean(gpa, path)) {
                  gpa.free(path);
                  continue;
              }
              const repo = try gpa.dupeSentinel(u8, main, 0);
              try out.append(gpa, .{ .path = path, .repo = repo });
          }
  ```

- `remove` (lines 139-143) runs `git -C <repo> worktree remove <path>`. Do not change it.
- `git` is the constant `pub const git = "/usr/bin/git";` (line 12). `run.capture(gpa, argv)`
  returns `!Output` with fields `out: []u8` and `code: u8`, and `deinit(gpa)`.
- `src/cleaner.zig:54`, the Developer spec. Its `.note` field reads:

  ```
  .note = "Xcode builds from scratch the next time. Git removes the worktrees; their branches and commits stay.",
  ```

- `src/view_clean.zig:374`, the confirm dialog text when something is deleted for good:

  ```zig
          "Caches, logs and other files move to the Trash. Git removes clean worktrees, and what is already in the Trash is deleted for good."
  ```

- The existing test to copy as the pattern (`src/tests.zig:424-441`):

  ```zig
  test "only clean, unlocked linked worktrees are found, and removing one keeps its branch" {
      const t = try Tmp.make();
      defer t.remove();
      try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q ../clean -b clean && git worktree add -q ../dirty -b dirty && printf x > ../dirty/new.txt && git worktree add -q ../held -b held && git worktree lock ../held", .{});
      var found = try worktree.find(gpa, t.path());
      defer {
          for (found.items) |f| {
              gpa.free(f.path);
              gpa.free(f.repo);
          }
          found.deinit(gpa);
      }
      try std.testing.expectEqual(@as(usize, 1), found.items.len);
      try std.testing.expect(std.mem.endsWith(u8, found.items[0].path, "/devv/clean"));
      ...
  }
  ```

  `Tmp.make()` creates a temp folder that acts as the home folder. `t.sh(fmt, args)`
  runs a shell command inside it. `devv` is one of the roots `worktree.find` scans.
- Git facts this plan relies on:
  - `git -C <worktree> for-each-ref --count=1 --contains HEAD` prints one line when a
    branch, tag or remote ref contains HEAD, and prints nothing when none does.
  - `git status --porcelain --untracked-files=normal` lists untracked files even when
    `status.showUntrackedFiles=no` is set.
- Conventions: all tests live in `src/tests.zig`, named as a sentence. `gpa` in tests
  is `std.testing.allocator` and fails a test that leaks. The code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |
| These tests | `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="worktree"` | all pass |

Do not use a bare `zig`. The `zig` on PATH can be a version that cannot build this repo.

## Scope

**In scope** (the only files you should modify):
- `src/worktree.zig`
- `src/cleaner.zig` (the one `.note` string of the Developer spec)
- `src/view_clean.zig` (the one dialog string)
- `src/tests.zig` (add tests only)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- `worktree.remove`, `worktree.parseList`, `worktree.candidates` and the `roots` list.
- Any rule that skips worktrees with ignored files. That is a product decision for
  the maintainer. This plan only makes the text honest.
- `cleaner.perform` and `Cleaner.clean`. Plans 004 and 005 change them.
- `design/`. Its text is reference material, not shipped UI.
- Do not run `zig fmt` on whole files. Several of these files already differ
  from `zig fmt` output, and formatting them creates unrelated diffs.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/003-worktree-unreferenced-commits`
- Conventional commits. Use: `fix(clean): keep worktrees whose commits no branch or tag holds`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing tests first

In `src/tests.zig`, directly after the test
`"only clean, unlocked linked worktrees are found, and removing one keeps its branch"`, add:

```zig
test "a detached worktree is offered only when a branch or tag holds its commits" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q --detach ../pinned && git worktree add -q --detach ../loose && git -C ../loose -c user.email=t@t -c user.name=t commit -q --allow-empty -m lost", .{});
    var found = try worktree.find(gpa, t.path());
    defer {
        for (found.items) |f| {
            gpa.free(f.path);
            gpa.free(f.repo);
        }
        found.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.endsWith(u8, found.items[0].path, "/devv/pinned"));
}

test "a worktree with untracked files is not offered when the repo hides untracked files from status" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git config status.showUntrackedFiles no && git worktree add -q ../quiet -b quiet && touch ../quiet/new.txt", .{});
    var found = try worktree.find(gpa, t.path());
    defer {
        for (found.items) |f| {
            gpa.free(f.path);
            gpa.free(f.repo);
        }
        found.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 0), found.items.len);
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="worktree"` →
both new tests FAIL (the first finds 2 worktrees, the second finds 1). If either passes before the fix, STOP.

### Step 2: Tighten the checks in `src/worktree.zig`

1. In `isClean`, add `"--untracked-files=normal"` as the last argument of the `git status` call:

   ```zig
   const st = run.capture(gpa, &.{ git, "-C", path, "status", "--porcelain", "--untracked-files=normal" }) catch return false;
   ```

2. Below `isClean`, add:

   ```zig
   pub fn headIsReferenced(gpa: std.mem.Allocator, path: []const u8) bool {
       const refs = run.capture(gpa, &.{ git, "-C", path, "for-each-ref", "--count=1", "--contains", "HEAD" }) catch return false;
       defer refs.deinit(gpa);
       return refs.code == 0 and std.mem.trim(u8, refs.out, " \n").len > 0;
   }

   pub fn isRemovable(gpa: std.mem.Allocator, path: []const u8) bool {
       return isClean(gpa, path) and headIsReferenced(gpa, path);
   }
   ```

3. In `find`, change `!isClean(gpa, path)` to `!isRemovable(gpa, path)`.

Keep `isClean` public. Any failure of git means "not removable".

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all -Dtest-filter="worktree"` → all pass,
including the two new tests and the two existing worktree tests.

### Step 3: Make the UI text honest

1. In `src/cleaner.zig`, in the spec with `.kind = .developer`, replace the `.note` value with:

   ```
   "Xcode builds from scratch the next time. Git removes the worktrees and the ignored files in them. Commits on a branch or tag stay."
   ```

2. In `src/view_clean.zig`, in `dialog`, replace the first description string with:

   ```
   "Caches, logs and other files move to the Trash. Git removes clean worktrees with their ignored files, and what is already in the Trash is deleted for good."
   ```

**Verify**: `grep -c "ignored files" src/cleaner.zig src/view_clean.zig` → each file prints `1`.

### Step 4: Run the whole suite

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests. The total is the earlier total plus 2.

## Test plan

- Two new tests in `src/tests.zig` (step 1): the detached-HEAD regression and the hidden-untracked-files regression.
- The existing tests `"only clean, unlocked linked worktrees are found, and removing one keeps its branch"`
  and `"cleaning the developer category removes clean worktrees with git"` must keep passing unchanged.
  They prove that normal branch worktrees are still offered and removed.

## Done criteria

ALL must hold:

- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` reports zero failed tests
- [ ] Both new tests exist and pass
- [ ] `grep -c "isRemovable" src/worktree.zig` prints `2`
- [ ] `grep -c "commits stay" src/cleaner.zig` prints `0`
- [ ] `git status --porcelain` lists only the five in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- The excerpts in "Current state" do not match the code (other than line numbers).
- A new test passes before the fix in step 2.
- An existing worktree test fails after step 2. The new check must not exclude a normal branch worktree.
- A test in `src/tests.zig` asserts the old dialog or note text and fails after step 3.

## Maintenance notes

- Open product decision, not made here: a "clean" worktree can still hold ignored
  files that matter (a local `.env`, a local database). Options are to skip
  worktrees that have ignored files, to show the ignored size, or to keep the
  current behavior with the honest text from step 3.
- `headIsReferenced` adds one git process per clean worktree to each scan. Worktree
  discovery is already serial and uncached. If scan time becomes a problem, cache per repo.
- Plan 005 calls `isRemovable` again just before removal. Keep the name and signature.
- Reviewer: open the Cleanup page and the confirm dialog once. Check that the longer text is not cut off.
