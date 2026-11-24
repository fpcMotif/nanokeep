# Plan 011: The bench measures the first frame after rest, and the glass sidebar's cost is known

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat b83f7d8..HEAD -- src/bench.zig src/view.zig`
> Both files can differ: `src/view.zig` had uncommitted edits when this plan
> was written, and plan 010 edits `src/bench.zig`. Compare the "Current state"
> excerpts against the live code. On a mismatch in an excerpt, STOP.

## At a glance

The renderer frees its GPU queue 0.25 s after the last frame, so the next
frame must rebuild it, and nothing measures how long that takes or what the
glass sidebar adds. This plan adds a `wake` metric to the bench and records
memory and wake time with the glass sidebar on and off. It changes no
behaviour of the app: the glass decision stays with the maintainer.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-pin-zig-toolchain.md. Run it after plan 010 if 010 is planned, because both edit `src/bench.zig`.
- **Category**: perf
- **Planned at**: commit `b83f7d8`, 2026-11-17

## Why this matters

Commit `da7f87d` recorded these facts: a Metal command queue that has encoded
a render pass holds about 97 MB in the driver, and the glass blur adds 68 MB
once its compute pass has run. To keep idle memory low, the nanoui fork
releases the queue and the glass backdrops 0.25 s after the last frame.

Two costs follow, and neither is measured:

1. Every frame that comes after a pause of 0.25 s rebuilds the queue and the
   backdrops. That is the first hover, click or scroll after any pause. The
   bench's `hover` and `scroll` metrics draw frames back to back, so they
   never include a rebuild.
2. The app redraws every 2 seconds for new samples, so memory rises and falls
   every 2 seconds. Commit `da7f87d` reports an idle floor of 61 MB and a
   time-weighted mean of 116 MB. The sidebar is the only user of glass in
   `src/` (`rg -n '\.glass\(' src` prints one line).

With numbers for both, the maintainer can decide whether the sidebar keeps
real glass and whether the 0.25 s rest time is right.

## Current state

Files:

- `src/bench.zig`: the bench. `zig build bench` runs it in ReleaseFast.
- `src/view.zig`: `sidebar`, the only caller of `.glass`.
- `bench/baseline.json`: the last saved bench output. It is stale: it holds values from before commit `da7f87d`.

`Bench.idle` in `src/bench.zig` shows how the bench detects a resting renderer:

```zig
    fn idle(b: *Bench) !Idle {
        b.a.page = .overview;
        pump(6);
        var floor: ?u64 = null;
        var weighted: f64 = 0;
        const begin = seconds();
        const end = begin + sample_interval + 0.5;
        var last = begin;
        while (last < end) {
            const now = measure.footprint().now;
            if (b.surface().renderer.queue == null) floor = @min(floor orelse now, now);
            pumpOnce(0.01);
            const t = seconds();
            weighted += @as(f64, @floatFromInt(now)) * (t - last);
            last = t;
        }
        return .{ .floor = floor orelse return error.RendererNeverRested, .mean = weighted / (last - begin) };
    }
```

`b.surface().renderer.queue` is null while the renderer rests.

`Bench.timedFrame` draws one frame and returns `Timed{ .wall, .cpu }` in
milliseconds. `Bench.putFrames(name, frames)` records four metrics:
`<name>_p50_ms`, `<name>_p95_ms`, `<name>_cpu_p50_ms`, `<name>_cpu_p95_ms`.
Its buffers hold at most 256 frames.

Every metric needs a row in the `budgets` table at the top of the file, or the
bench fails with "no budget". Two existing rows as a pattern:

```zig
    .{ .name = "hover_p50_ms", .budget = 9, .target = 0.28 },
    .{ .name = "hover_cpu_p50_ms", .budget = 0.33, .target = 0.28 },
```

In `main`, the measurements run in this order:

```zig
    try b.sampling();
    try b.keystrokes();
    const idle = try b.idle();
```

The bench prints its JSON, writes it to the path given by `--out=`, and only
then returns `error.OverBudget` when a metric is over budget. So a failing
metric does not stop the file from being written.

`sidebar` in `src/view.zig` (find it by name) starts with:

```zig
    const frame = ui.div(c).column().w(232).hFull().p(10);
    defer frame.end();
    const backdrop = ui.div(c).column().wFull().grow().rounded(20).clip();
    defer backdrop.end();
    aurora(c);
    const side = ui.div(c).column().wFull().grow().px(8).pt(12).pb(12).gap(1).rounded(20).glass(.{});
    defer side.end();
```

Conventions in this repo:

- Do not add comments. Names carry the meaning.
- Do not format whole files.
- Commit messages for measured changes quote the numbers. See `git show da7f87d --stat --format=%B`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Bench | `mise exec zig@0.17.0 -- zig build bench -- --out=/tmp/nanokeep-bench.json` | prints JSON and writes the file |
| Tests | `mise exec zig@0.17.0 -- zig build test --summary all` | zero failed tests |

Do not use a bare `zig`.

The bench needs a logged-in desktop, an awake display, and its window left
uncovered on the active Space for about 2 minutes. It prints
"the bench window must stay uncovered" when that fails. An exit with
`error.OverBudget` is not a failed run: the JSON is still complete.

## Scope

**In scope** (the only files you should modify):
- `src/bench.zig` (one new function, one call, four `budgets` rows)
- `bench/baseline.json` (replaced by a fresh bench output)
- `plans/011-measure-wake-frame-and-glass-sidebar.md` (fill in the "Results" section at the end)

**Out of scope** (do NOT touch, even though they look related):
- `src/view.zig` in any commit. Step 4 changes it for one bench run and then restores it.
- The nanoui package under `zig-pkg/`, including its `rest_after` constant. It is a separate repository.
- Any other budget in `src/bench.zig`.
- Every other Markdown file except your status row in `plans/README.md`.

## Git workflow

- This repo is a colocated jj and git repo. In your worktree, use plain `git` only. Do not run `jj`.
- Branch: `advisor/011-wake-metric`
- Conventional commits. Use: `feat(bench): measure the first frame after the renderer rests`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm that the bench can run here

Run `mise exec zig@0.17.0 -- zig build bench -- --out=/tmp/nanokeep-bench-before.json`.

**Verify**: `rg -c '"value"' /tmp/nanokeep-bench-before.json` prints 20 or more. If the bench reports that its window is covered, or the file is missing, STOP: this plan cannot run on this machine.

### Step 2: Add the `wake` measurement

In `src/bench.zig`, add this method to `Bench`, directly after `scrolls`:

```zig
    fn wakes(b: *Bench) !void {
        b.a.page = .overview;
        var frames: [10]Timed = undefined;
        for (&frames) |*f| {
            const waited = seconds();
            while (b.surface().renderer.queue != null) {
                if (seconds() - waited > 10) return error.RendererNeverRested;
                pumpOnce(0.01);
            }
            f.* = try b.timedFrame();
        }
        try b.putFrames("wake", &frames);
    }
```

Each of the 10 frames is drawn only after the renderer has rested, so each one
pays the rebuild.

In `main`, add `try b.wakes();` directly after `try b.keystrokes();`.

**Verify**: `mise exec zig@0.17.0 -- zig build bench -- --out=/tmp/nanokeep-bench-wake.json 2>&1 | rg 'wake'` → prints four JSON lines for `wake_p50_ms`, `wake_p95_ms`, `wake_cpu_p50_ms`, `wake_cpu_p95_ms`, and four lines starting with `no budget: wake_`. The "no budget" lines are expected at this point.

### Step 3: Give the four metrics budgets from the measured values

Read the four `wake_` values from `/tmp/nanokeep-bench-wake.json`. For each
one, compute the budget as the value times 1.5, rounded up to a whole number.
Add four rows to `budgets`, directly after the `scroll_cpu_p95_ms` row. The
targets are fixed. Example for measured values 21.3, 30.2, 6.1 and 9.4:

```zig
    .{ .name = "wake_p50_ms", .budget = 32, .target = 9 },
    .{ .name = "wake_p95_ms", .budget = 46, .target = 17 },
    .{ .name = "wake_cpu_p50_ms", .budget = 10, .target = 2.1 },
    .{ .name = "wake_cpu_p95_ms", .budget = 15, .target = 10.7 },
```

The targets are today's budgets for a page switch, which is the nearest
existing full redraw. Use your own measured values for the budgets, not the
example values.

**Verify**: `mise exec zig@0.17.0 -- zig build bench -- --out=/tmp/nanokeep-bench-glass.json 2>&1 | rg 'wake'` → four JSON lines, each with `"ok": true`, and no line starting with `no budget`. Commit `src/bench.zig` now.

### Step 4: Measure once without glass, then restore the file

1. Run `git status --short src/view.zig`. It must print nothing. If it prints a line, STOP.
2. In `src/view.zig`, in `sidebar`, change only the end of one line: replace `.rounded(20).glass(.{});` with `.rounded(20).bg(th.surface.alpha(0.6));`.
3. Run `mise exec zig@0.17.0 -- zig build bench -- --out=/tmp/nanokeep-bench-plain.json`.
4. Run `git checkout -- src/view.zig`.

**Verify**: `git status --short src/view.zig` prints nothing, and `rg -n '\.glass\(' src/view.zig` prints one line.

### Step 5: Record the results in this plan

Fill the table in the "Results" section at the end of this file. Take each
value from `/tmp/nanokeep-bench-glass.json` (glass on) and
`/tmp/nanokeep-bench-plain.json` (glass off).

**Verify**: `rg '^\| .*UNMEASURED' plans/011-measure-wake-frame-and-glass-sidebar.md` prints nothing.

### Step 6: Save the fresh baseline

Run `cp /tmp/nanokeep-bench-glass.json bench/baseline.json`.

**Verify**: `rg -n 'wake_p50_ms' bench/baseline.json` prints one line. `mise exec zig@0.17.0 -- zig build test --summary all` → zero failed tests. Commit `bench/baseline.json` and this plan file.

## Test plan

- No unit test. The bench is the test: `wake_p50_ms` exists, has a budget, and reads `"ok": true` in step 3.
- The metric cannot pass by accident: `wakes` returns `error.RendererNeverRested` when the renderer never rests, so a run that did not pay the rebuild fails.

## Done criteria

- [ ] `rg -n 'fn wakes' src/bench.zig` prints one match
- [ ] `rg -c 'wake_' src/bench.zig` prints 4
- [ ] `rg -n 'wake_p50_ms' bench/baseline.json` prints one match
- [ ] `rg '^\| .*UNMEASURED' plans/011-measure-wake-frame-and-glass-sidebar.md` prints nothing
- [ ] `git diff b83f7d8..HEAD --stat -- src/view.zig` shows no change made by this plan
- [ ] `git status --short` lists nothing after the last commit
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The bench cannot keep its window visible in step 1.
- `wakes` returns `error.RendererNeverRested`. That means the renderer no longer rests, and the facts in "Why this matters" have changed.
- `src/view.zig` has uncommitted changes before step 4.
- The glass-off run in step 4 fails to build. Restore the file with `git checkout -- src/view.zig` and report the error.
- You are tempted to commit the glass-off change. The maintainer decides that.

## Maintenance notes

- The decision this plan prepares: keep real glass on the sidebar, or use a plain translucent fill. The "Results" table gives the memory and wake-time price of the glass. The sidebar design comes from commit `10e3401`.
- A second decision uses the same numbers: the 0.25 s rest time lives in the nanoui fork (`src/ui/surface.zig`, constant `rest_after`). A longer rest while the pointer is inside the window would remove most wake frames, at the price of a higher idle mean. That change belongs to the nanoui repository.
- `wake` budgets were set from one machine. Tighten them after any win, as the comment above `budgets` says.

## Results

Filled in by the executor in step 5. Values in MB or ms, from the bench JSON.

| Metric | Glass on | Glass off |
|---|---|---|
| `idle_mb` | UNMEASURED | UNMEASURED |
| `idle_mean_mb` | UNMEASURED | UNMEASURED |
| `hidden_mb` | UNMEASURED | UNMEASURED |
| `peak_mb` | UNMEASURED | UNMEASURED |
| `wake_p50_ms` | UNMEASURED | UNMEASURED |
| `wake_p95_ms` | UNMEASURED | UNMEASURED |
| `wake_cpu_p50_ms` | UNMEASURED | UNMEASURED |
| `page_switch_p50_ms` | UNMEASURED | UNMEASURED |
