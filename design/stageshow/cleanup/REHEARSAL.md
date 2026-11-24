# Rehearsal: nanokeep Cleanup hero

## Brief

nanokeep's Cleanup page as an animated hero beside copy. Developer is ticked and the Clean button's size rolls up. Clean is pressed. The ticked rows empty one by one, the disk dots drain, and the found total rolls from 9.5 GB to 1.4 GB. The button ends as "Freed 8.1 GB". Scan Again is the reset: the scan finds the files again, and the page returns to its opening frame.

## Gold copied

- `hero-demo`: the stage size, the well, the pinned bottom bleed and the gutter.
- `table-edit`: a value that changes, then the total it feeds rolls a beat later.

## What changed from the gold

- The look comes from the Palindrome tokens in `src/theme.zig`, which `DESIGN.md` describes. The accent is violet `#9536D6`. The page is `#F6F5F8`.
- Each category takes a data hue, as `src/view_clean.zig` assigns it: Caches violet, Package Caches sand, Developer lime, Agent Sessions yellow. Logs is a fifth category, so its disk dots use half-strength sand.
- The sidebar has one-color icons. The selected item has a 12% accent fill and an accent icon and figure. Its label keeps the weight and color of the other labels.
- The summary card has an 18 px radius, a 0.5 px ring and a 1 px shadow. Rows have a 6 px radius and a stripe on every second row, with no divider lines.
- The window has no traffic lights, as in the app's own captures. Its foot fades out, so the stage never cuts a row through its text.
- Secondary text is `#626165`, darker than the app's `label-2`, so it reaches 4.5:1 on the page and the sidebar.
- The category names, descriptions and sidebar order come from `src/cleaner.zig` and `src/view.zig`.
- The disk dot grid is kept, because it is nanokeep's own mark.
- Icons are lucide, one stroke weight, standing in for the app's SF Symbols.

## Captured

| Check | Result |
|---|---|
| Wide loop, 720 x 400, `--gate` (`loop-wide.png`) | rehearsal passed |
| Phone loop, 390 (compact 358 x 340), `--gate` (`loop-390.png`) | rehearsal passed |
| Reduced-motion poster (`poster.png`) | the payoff frame: 1.4 GB, "Freed 8.1 GB", drained dots. The film reports no issues. |
| Typecheck (`tsc -p playground`) | no errors in this example |

The film ran in Chrome Canary through `CHROME_PATH`, because this Mac has no stable Chrome.

## Open film lines

- `jump` and `settle snap` on `Count`'s digit strips in the phone loop. They come from the kit.
- `lopsided` on the Clean button while it reads "Cleaning…". The kit's `Button` pads the icon side tighter on purpose.
- The film reports sampling gaps over 27 ms in both loops, so it calls the motion check inconclusive.

## Not checked

- Dark theme. The app now has one, but this demo is light only.
- Live pacing on a real page, and touch input.
- A fresh-eye review by a second agent.
