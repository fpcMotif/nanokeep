# Plan 001: Pin Zig 0.17 so the build and tests run the same way for everyone

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- build.zig build.zig.zon`
> If either file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. On a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `b83f7d8`, 2026-11-10
- **Issue**: https://github.com/fpcMotif/nanokeep/issues/3

## Why this matters

nanokeep builds only with Zig 0.17.x. The repo does not pin that version.
On a machine whose `zig` is 0.18-dev, `zig build test` fails inside the
nanoui dependency (`src/ui/shaper.zig:99`, "ambiguous operator precedence"),
with no hint that the toolchain is the cause. Every other plan in `plans/`
uses the test suite as its gate, so the gate must work first. After this plan,
a pinned toolchain exists, and a wrong Zig fails at once with a clear message.

## Current state

- `build.zig.zon` declares a floor, not a pin (line 5):

  ```zig
  .minimum_zig_version = "0.17.0",
  ```

- `build.zig` starts like this (lines 1-3, then line 21):

  ```zig
  const std = @import("std");

  const info_plist =
  ```

  ```zig
  pub fn build(b: *std.Build) void {
  ```

- There is no `mise.toml`, `.tool-versions`, `.zigversion`, CI config or README.
- Measured at this commit with Zig 0.17.0:
  `zig build test --summary all` prints `59/59 tests passed` in about 75 seconds.
- Measured at this commit with Zig 0.18.0-dev.852: the same command fails with
  3 compile errors in the nanoui dependency.
- Repo convention: the code has no comments. Do not add any.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Zig version | `mise exec zig@0.17.0 -- zig version` | prints `0.17.0` |
| Tests | `mise exec zig@0.17.0 -- zig build test --summary all` | ends with `59/59 tests passed` |

Do not use a bare `zig` command for tests. The `zig` on PATH can be a different version.

## Scope

**In scope** (the only files you should modify):
- `mise.toml` (create, repo root)
- `build.zig`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- `build.zig.zon`. The dependency pin and `minimum_zig_version` stay as they are.
- Anything under `src/`.
- `zig-pkg/` (the cached nanoui copy). Do not fix `shaper.zig`.
- Do not run `zig fmt` on any file. Seven files in `src/` already differ from
  `zig fmt` output at this commit, and formatting them creates unrelated diffs.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/001-pin-zig-toolchain`
- Commit message style is conventional commits. Example from `git log`:
  `fix(search): reorder a searched app list when an app runs, and tidy the matcher`.
  Use: `build: pin Zig 0.17 with mise and fail fast on another version`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `mise.toml`

Create `mise.toml` in the repo root with exactly this content:

```toml
[tools]
zig = "0.17.0"
```

**Verify**: from the repo root, `mise exec -- zig version` → prints `0.17.0`.

### Step 2: Add a version guard to `build.zig`

Directly below `const std = @import("std");` (line 1), add:

```zig
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) @compileError("nanokeep builds with Zig 0.17.x. Run `mise exec -- zig build`; mise.toml pins the version.");
}
```

**Verify**: `mise exec zig@0.17.0 -- zig build test --summary all` → ends with `59/59 tests passed`.

### Step 3: Confirm the guard fires on another Zig (only when one is available)

Run `zig version`. If it prints a version that does not start with `0.17`, run:

`zig build test 2>&1 | grep -c "nanokeep builds with Zig 0.17.x"`

**Verify**: prints `1` or more. If `zig version` starts with `0.17`, or `zig` is
not on PATH, skip this step and say so in your report.

## Test plan

No new unit tests. The gates are the commands in steps 1 to 3.

## Done criteria

ALL must hold:

- [ ] `mise exec -- zig version` prints `0.17.0` from the repo root
- [ ] `mise exec zig@0.17.0 -- zig build test --summary all` ends with `59/59 tests passed`
- [ ] `grep -c "nanokeep builds with Zig 0.17.x" build.zig` prints `1`
- [ ] `git status --porcelain` lists only `mise.toml`, `build.zig` and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:

- `mise` is not installed, or `mise exec` asks you to trust the config file. Do not run `mise trust` yourself.
- The test count at baseline is not 59, or tests fail before you change anything.
- In step 3, a non-0.17 Zig does not print the guard message.
- The `build.zig` excerpts in "Current state" do not match the file.

## Maintenance notes

- To move to a newer Zig: fix the nanoui fork first (`src/ui/shaper.zig:99` needs
  parentheses around `@as(u16, a) << 8`), then change `mise.toml`, the guard and
  `minimum_zig_version` in one commit.
- Deferred on purpose: a `zig fmt --check` gate and CI. At `b83f7d8`,
  `zig fmt --check src build.zig` reports `src/tests.zig`, `src/app.zig`,
  `src/view_clean.zig`, `src/iokit.zig`, `src/cleaner.zig`, `src/procs.zig` and
  `src/view_card.zig`. A format pass must land alone, after the other plans, so it does not cause drift.
- Reviewer: check that the guard message names the command a newcomer must run.
