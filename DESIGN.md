# Design

## Theme

Nautical instrument panel. Two custom DaisyUI themes (`cockpit-dark` default, `cockpit-light`), user-toggleable and persisted. Cool slate neutrals with a single teal/aqua accent (the sea), semantic status colors reserved for state. Restrained color strategy: accent for primary actions + current state only, never decoration.

## Color (OKLCH)

Dark (`cockpit-dark`):
- base-100 `oklch(0.20 0.02 240)`, base-200 `oklch(0.24 0.02 240)`, base-300 `oklch(0.29 0.025 240)`
- base-content `oklch(0.93 0.01 230)`
- primary (teal) `oklch(0.74 0.12 195)`, primary-content `oklch(0.19 0.03 210)`

Light (`cockpit-light`):
- base-100 `oklch(0.98 0.004 220)`, base-200 `oklch(0.955 0.007 220)`, base-300 `oklch(0.90 0.012 225)`
- base-content `oklch(0.26 0.03 245)`
- primary (teal) `oklch(0.52 0.11 205)`, primary-content `oklch(0.99 0 0)`

Semantic (both, tuned per theme for contrast): success = crew working (green), warning = needs decision (amber), error = blocked/failed (red), info = scout (cyan).

## Typography

One family: system-ui / SF stack. Fixed rem scale (not fluid), ratio ~1.2. Weights 400/500/600/700. Monospace (ui-monospace) for ids, paths, and pane output only.

## Components

- Stat tiles with a small line icon, semantic value color, quiet label.
- Fleet task rows: full 1px border + subtle surface; status shown by a labeled badge and a state dot (never color alone, never a side-stripe). Needs-decision row uses a full warning ring + tint.
- Empty state teaches ("crew idle - send a task"), not "nothing here".
- Chat bar: elevated panel, primary send.

## Motion

150-250ms ease-out on hover/state/theme transitions. A slow pulse only on genuinely live indicators (working dot, live badge). Everything behind `prefers-reduced-motion: reduce`.

## Layout

Max-width ~1200px. Top bar (brand + captain + theme toggle + health), stat row, then two-column: fleet (2fr) + side rail (backlog, projects) (1fr), chat bar below. Side rail collapses under the fleet on narrow screens.
