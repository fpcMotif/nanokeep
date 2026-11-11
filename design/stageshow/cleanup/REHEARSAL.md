# Rehearsal: nanokeep Cleanup hero

## Brief

nanokeep's Cleanup page as an animated hero beside copy. Developer is ticked and the Clean button's size rolls up. Clean is pressed. The ticked rows empty one by one, the disk dots drain, and the found total rolls from 9.5 GB to 1.4 GB. The button ends as "Freed 8.1 GB". Scan Again is the reset: the scan finds the files again, and the page returns to its opening frame.

## Gold copied

- `hero-demo`: the stage size, the well, the pinned bottom bleed and the gutter.
- `table-edit`: a value that changes, then the total it feeds rolls a beat later.

## What changed from the gold

- The look comes from nanokeep's source: accent `#f5458f` (`src/view.zig`), category names, descriptions and colors (`src/cleaner.zig`), and the sidebar order (`src/view.zig`).
- The window is a sidebar app with a gray content column and a white summary card, as the app draws it.
- The disk dot grid is kept, because it is nanokeep's signature.
- Icons are lucide, one stroke weight, standing in for the app's SF Symbols.

## Captured

| Check | Result |
|---|---|
| Wide loop, 720 x 400, `--gate` | rehearsal passed |
| Phone loop, 390 (compact 358 x 340), `--gate` | rehearsal passed |
| Reduced-motion poster | the payoff frame: 1.4 GB, "Freed 8.1 GB", drained dots |
| Typecheck (`tsc -p playground`) | no errors in this example |

## Open film lines

- `jump` and `settle snap` on `Count`'s digit strips. The gold `subscriptions` example prints the same lines, so they come from the kit.
- `lopsided` on the Clean button while its icon slot opens. The kit's `Button` pads the icon side tighter on purpose.

## Not checked

- Dark theme. The app is light only, so none was built.
- Live pacing on a real page, and touch input.
- A fresh-eye review by a second agent.
