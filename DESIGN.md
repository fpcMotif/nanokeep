---
name: nanokeep
description: A Mac system monitor and cleaner drawn with the Palindrome tokens.
colors:
  win: "#FFFFFF"
  win-2: "#F6F5F8"
  label: "rgb(0 0 0 / 0.86)"
  label-2: "rgb(0 0 0 / 0.52)"
  label-3: "rgb(0 0 0 / 0.28)"
  sep: "rgb(0 0 0 / 0.09)"
  fill: "rgb(0 0 0 / 0.05)"
  fill-2: "rgb(0 0 0 / 0.08)"
  alt: "rgb(0 0 0 / 0.022)"
  accent: "#9536D6"
  accent-soft: "rgb(149 54 214 / 0.12)"
  on-accent: "#FFFFFF"
  sand: "#C9853A"
  lime: "#5E9A2C"
  red: "#FF3B30"
  yellow: "#F5A623"
  dark-win: "#1E1C21"
  dark-win-2: "#252229"
  dark-label: "rgb(255 255 255 / 0.88)"
  dark-label-2: "rgb(255 255 255 / 0.55)"
  dark-label-3: "rgb(255 255 255 / 0.26)"
  dark-sep: "rgb(255 255 255 / 0.09)"
  dark-fill: "rgb(255 255 255 / 0.06)"
  dark-fill-2: "rgb(255 255 255 / 0.10)"
  dark-alt: "rgb(255 255 255 / 0.025)"
  dark-accent: "#B66BF0"
  dark-accent-soft: "rgb(182 107 240 / 0.18)"
  dark-on-accent: "#1A0B26"
  dark-sand: "#EABD86"
  dark-lime: "#ABD86F"
  dark-red: "#FF453A"
  dark-yellow: "#FFD60A"
typography:
  title:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 700
  figure:
    fontFamily: SF Pro
    fontSize: 34px
    fontWeight: 700
  body:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: 400
  label:
    fontFamily: SF Pro
    fontSize: 11.5px
    fontWeight: 500
  table-figure:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
rounded:
  chip: 4px
  row: 6px
  control: 8px
  panel: 12px
  window: 16px
  card: 18px
  hero: 22px
spacing:
  hair: 2px
  xs: 4px
  sm: 6px
  md: 8px
  lg: 10px
  xl: 12px
  gutter: 14px
  card: 16px
  page: 20px
components:
  card:
    backgroundColor: "{colors.win}"
    rounded: "{rounded.card}"
    padding: "{spacing.card}"
  nav-item-selected:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.label}"
    rounded: "{rounded.row}"
    height: 28px
  table-row-selected:
    backgroundColor: "{colors.accent-soft}"
    rounded: "{rounded.row}"
    height: 26px
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
---

# Design System: nanokeep

## Overview

nanokeep uses the Palindrome system from `design/systems/palindrome`. Planisphere lost. Planisphere renames CPU to "stellar core" and sets figures in a display serif. Both choices slow a person who wants to read a number and act.

Palindrome follows macOS: the system font, a glass sidebar, pill controls, and system greys with a faint violet tint. One module holds every token: `src/theme.zig`. Screens must take colors, radii and spacing from that module.

The app follows the system appearance. Light and dark use the same token names.

## Colors

### Primary

Violet is the accent. It marks the selected item, the one primary button in a view, and the CPU and GPU data.

### Secondary

Sand marks memory, downloads, disk writes and system CPU time. Lime marks uploads, disk reads, compressed memory and a normal state.

### Tertiary

Yellow marks energy and a warning. Red marks a destructive action and a critical state.

### Neutral

`win` is a card. `win-2` is the page. `label`, `label-2` and `label-3` are three strengths of text. `sep` is a hairline. `fill` and `fill-2` are hover and track fills. `alt` is the stripe on odd table rows.

### Named Rules

- **Hue is data.** A hue appears on a chart, a bar, a dot or a small icon. Titles and body text use `label`.
- **Three hues first.** A view uses violet, sand and lime before it adds yellow. A fifth category uses a half-strength mix of the first hues.
- **Color has a partner.** A state that color shows also has a word or a shape.

## Typography

The system font sets all text. SF Mono sets table figures and sidebar figures, because SF Mono digits share one width.

### Hierarchy

- Page title: 17 px bold.
- Hero figure: 34 px bold, one per card.
- Card title: 13 px semibold.
- Body and navigation: 13 px.
- Table text: 12.5 px. Table figures: 12 px SF Mono.
- Labels and captions: 11 to 12 px in `label-2`.

### Named Rules

- **Figures hold their width.** Every live figure uses equal-width digits. Cards use `card.figure`, which sets each digit in a fixed cell. Tables use SF Mono.
- **Weight is not a state.** A selected row, tab or sort column keeps the weight it had. Fill and color show the selection.

## Layout

The window has a 228 px sidebar and one content column. The page inset is 20 px. Cards sit 14 px apart and have 16 px of padding. The spacing steps are 2, 4, 6, 8, 10, 12, 14, 16 and 20 px. The overview shows three tiles per row, and two when the window is under 1000 px wide.

## Elevation & Depth

Surfaces are flat. An edge ring separates a card from the page.

### Shadow Vocabulary

- Light card: a 0.5 px `sep` ring and a shadow of `0 1px 2px rgb(0 0 0 / 0.04)`.
- Dark card: a 1 px `dark-sep` ring and no shadow.
- Segmented thumb: `0 1px 3px rgb(0 0 0 / 0.14)`.

### Named Rules

- **Rings in the dark.** A dark surface never uses a shadow to lift itself.

## Shapes

The radii are 4, 6, 8, 12, 16, 18 and 22 px. A pill is fully round.

A shape inside a padded surface takes the outer radius minus the padding, with a floor of 4 px. `theme.inner` computes this value. A chart panel in a card is 18 − 16, which the floor raises to 4 px. A sidebar item is 12 − 6, which gives 6 px.

## Components

### Buttons

A view has one primary button in the accent. Other buttons are plain. A destructive button uses the kit's danger style.

### Chips

A tag has a hue dot, a 16% hue fill and `label` text. The text never takes the hue, because yellow and lime text fail contrast on a light card.

### Cards / Containers

`card.card` and `card.half` draw every card through `theme.surface`. The head is a 13 px hue icon and a `label` title. The About and Cleanup heroes use the 22 px radius.

### Inputs / Fields

Search fields and checkboxes come from the kit and take the theme colors. A checked box fills with the accent.

### Navigation

A sidebar item is 28 px tall with a one-color 13 px icon. The selected item has an `accent-soft` fill and an accent icon and figure. `card.segmented` is a pill track with a raised thumb.

### Dot chart

The dot grid is the app's own mark. A chart is a grid of dots on a 9% hue panel. Lit dots take the series hue. The Cleanup disk map and the memory ring use the same dots.

### Table

Rows are 26 px tall with a 6 px radius. Odd rows take `alt`. A zero value drops to `label-3`. The Memory column draws a sand bar scaled to the largest group, then the figure.

## Do's and Don'ts

### Do:

- Take every color from `theme.of(c)` or `theme.hue(c, hue)`.
- Draw a card with `theme.surface`.
- Set a live figure with `card.figure` or `table.value`.
- Check a change in light and in dark.

### Don't:

- Write a hex color in a screen file.
- Color a title or a body sentence with a hue.
- Change font weight to show selection.
- Add a shadow to a dark surface.
