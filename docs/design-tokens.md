# Design tokens: WFP Design System → warehouse_web

Visual tokens (colour, typography, corner radius) ported from the WFP
Design System's published theme registry (`designsystem.wfp.org/r/theme.json`)
into `apps/warehouse_web`. This is a **token port**, not a component port —
the WFP Design System is a React/shadcn/Radix/Tailwind v4 library; Phoenix
renders server-side HTML, so only the underlying CSS custom properties were
carried over.

Tailwind setup detected: **v4** (CSS-first config — `@import "tailwindcss"`,
`@theme`, `@plugin`, `@source` in `assets/css/app.css`; no
`tailwind.config.js` and no Node/npm tooling in the project).

All tokens live in `assets/css/app.css`, inside the `@theme { ... }` block
(generates Tailwind utilities, e.g. `bg-danger-600`, `rounded-lg`) or the
top-level `:root { ... }` block (raw brand colours, intentionally **not**
wired into Tailwind's colour scale — see below).

## Raw brand colours (not for interactive use)

| Token | Hex | Use |
|---|---|---|
| `--wfp-blue` | `#007dbc` | Logo / marketing only |
| `--wfp-navy` | `#002f5a` | Logo / marketing only |
| `--wfp-green` | `#03924a` | Logo / marketing only |

These are **not** exposed as Tailwind utility classes on purpose. WFP
reserves them for logos and marketing because they are not
contrast-optimized. Every interactive component and text colour in this app
must come from the semantic scales below instead.

## Primary scale (`primary-50`…`primary-950`)

Brand blue. Used for links, buttons, and active/focus states.

| Step | Hex |
|---|---|
| 50 | `#f4f9fc` |
| 100 | `#e9f2fa` |
| 200 | `#d3e6f5` |
| 300 | `#aed1ec` |
| 400 | `#7bb5df` |
| 500 | `#3f94cc` |
| 600 | `#0078b8` |
| 700 | `#005795` |
| 800 | `#003b6d` |
| 900 | `#00274e` |
| 950 | `#001632` |

`primary-600` (`#0078b8`) is WFP's AA-tuned (4.5:1 on white) brand blue and
is also aliased as the semantic `--color-primary`. Used in this app for the
"New incident" primary action button and the `ring`/focus colour.

## Success scale (`success-50`…`success-950`)

Closed / resolved incidents.

| Step | Hex |
|---|---|
| 50 | `#f5faf6` |
| 100 | `#e8f4eb` |
| 200 | `#d2e9d7` |
| 300 | `#abd6b5` |
| 400 | `#7abe8a` |
| 500 | `#38a05b` |
| 600 | `#008442` |
| 700 | `#006147` |
| 800 | `#034332` |
| 900 | `#022d21` |
| 950 | `#011b12` |

Used for the "Resolved" severity badge (`success-100` background /
`success-700` text) and the remapped daisyUI `success`/`alert-success` theme
colour (`success-600`).

## Warning scale (`warning-50`…`warning-950`)

Elevated / trending-toward-breach states.

| Step | Hex |
|---|---|
| 50 | `#fff8e7` |
| 100 | `#fff0cf` |
| 200 | `#fee09c` |
| 300 | `#fcc524` |
| 400 | `#dea600` |
| 500 | `#ba8300` |
| 600 | `#9d6700` |
| 700 | `#7d4800` |
| 800 | `#602c00` |
| 900 | `#4a1500` |
| 950 | `#370100` |

Used for the "Warning" severity badge (`warning-100` background /
`warning-700` text) and the remapped daisyUI `warning` theme colour
(`warning-600`).

## Danger scale (`danger-50`…`danger-950`)

Critical incidents.

| Step | Hex |
|---|---|
| 50 | `#fff7f6` |
| 100 | `#ffedeb` |
| 200 | `#ffdad6` |
| 300 | `#ffbbb5` |
| 400 | `#ff8f89` |
| 500 | `#ff4b4f` |
| 600 | `#e4052c` |
| 700 | `#ad000c` |
| 800 | `#7c0001` |
| 900 | `#560000` |
| 950 | `#370000` |

`danger-600` (`#e4052c`) is also aliased as `--color-destructive`. Used for
the "Critical" severity badge (`danger-100` background / `danger-700` text)
and the remapped daisyUI `error`/`alert-error` theme colour.

## Neutral scale (`neutral-50`…`neutral-950`)

Chrome, borders, muted text.

| Step | Hex |
|---|---|
| 50 | `#f8f8f8` |
| 100 | `#f1f1f1` |
| 200 | `#e3e3e3` |
| 300 | `#cccccc` |
| 400 | `#aeaeae` |
| 500 | `#8d8d8d` |
| 600 | `#727272` |
| 700 | `#545454` |
| 800 | `#3a3a3a` |
| 900 | `#262626` |
| 950 | `#161616` |

Used for the fallback/"Unknown" severity badge (`neutral-100` /
`neutral-700`) and the remapped daisyUI `neutral`/`base-*` theme colours.

## Semantic aliases

Root-level tokens from WFP's `theme.json`, exposed as flat Tailwind colour
utilities (`bg-card`, `text-muted-foreground`, `border-border`, etc.) so
component code reads the same way WFP's own shadcn components do.

| Token | Hex | Use in this app |
|---|---|---|
| `--color-background` | `#ffffff` | Page background |
| `--color-foreground` | `#000000e9` | Primary body text |
| `--color-muted` | `#f8f8f8` | Muted surface fill |
| `--color-muted-foreground` | `#0000008d` | Secondary/muted text (empty-state copy, incident IDs) |
| `--color-border` | `#0000001c` | Hairline borders (incident row cards) |
| `--color-input` | `#8d8d8d` | Form input borders |
| `--color-ring` | `#0078b8` | Focus ring |
| `--color-card` | `#ffffff` | Card/row background |
| `--color-card-foreground` | `#000000e9` | Card/row text |
| `--color-primary` | `#0078b8` | Primary button fill, links |
| `--color-primary-foreground` | `#ffffff` | Text/icons on primary fill |
| `--color-secondary` | `#e9f2fa` | Secondary button/surface fill |
| `--color-secondary-foreground` | `#005795` | Text on secondary fill |
| `--color-destructive` | `#e4052c` | Destructive actions (delete, close-as-failed) |

## Corner radius

| Token | Value | Tailwind utility |
|---|---|---|
| `--radius-xs` | `0.125rem` | `rounded-xs` |
| `--radius-sm` | `0.1875rem` | `rounded-sm` |
| `--radius-md` | `0.25rem` | `rounded-md` |
| `--radius-lg` | `0.375rem` | `rounded-lg` (incident rows, primary button) |
| `--radius-xl` | `0.5rem` | `rounded-xl` |
| `--radius-2xl` | `0.75rem` | `rounded-2xl` |
| `--radius-3xl` | `1rem` | `rounded-3xl` |
| `--radius-4xl` | `1.5rem` | `rounded-4xl` |

## Typography

`--font-sans: "Open Sans", ui-sans-serif, system-ui, sans-serif`, applied
app-wide via `body { font-family: var(--font-sans); }` in `app.css`.

Self-hosted (not the Google Fonts CDN) for offline reliability, via
`@font-face` declarations in `assets/css/fonts.css` pointing at
`priv/static/fonts/open-sans-{400,500,600,700}.woff2`.

**Outstanding:** the four WOFF2 files themselves could not be downloaded in
this environment (no external network access) and still need to be added —
see `priv/static/fonts/PLACEHOLDER.md`. Until they're added, the browser
falls back to the `ui-sans-serif`/`system-ui` stack with no build or render
errors.

## Severity/status → token mapping

| State | Badge background | Badge text | Scale |
|---|---|---|---|
| Critical | `danger-100` | `danger-700` | danger |
| Warning / trending toward breach | `warning-100` | `warning-700` | warning |
| Closed / resolved | `success-100` | `success-700` | success |
| Unknown / other | `neutral-100` | `neutral-700` | neutral |

Implemented in `WarehouseWeb.IncidentLive.Index` (`severity_badge_class/1`).

## daisyUI theme remap

The scaffold's daisyUI light theme (`assets/css/app.css`) had its
`primary`, `success`, `warning`, `error`, `neutral`, and `base-*` colours
remapped to the WFP tokens above (`primary-600`, `success-600`,
`warning-600`, `danger-600`/`destructive`, `neutral-700`, `background`,
`neutral-50`, `neutral-200`, `foreground`) so daisyUI-classed elements
(`btn-primary`, `alert-error`, the site header) match the rest of the app.
`secondary`, `accent`, and `info` have no WFP-supplied equivalent in the
provided token set and were left as the Phoenix generator's original
values. The daisyUI **dark** theme was left untouched — WFP only published
light-theme tokens.
