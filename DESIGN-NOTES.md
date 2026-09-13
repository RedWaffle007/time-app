# DealerPulse — UI Design Notes

A reference capture of the DealerPulse dashboard's visual/UI design, written to serve as
inspiration for other projects. It documents *what the design does and why*, not the app's
business logic. Stack for context: Next.js (App Router) + Tailwind CSS v4 + shadcn-style
primitives on Base UI, `lucide-react` icons.

---

## 1. Design personality in one line

A calm, "modern-SaaS analytics" surface with a **medical/vital-signs metaphor** ("DealerPulse ·
Feel your data") layered over an **automotive** subject. It reads as clean and executive, but
carries small, deliberate touches of character (a splash reveal, a faint themed backdrop, film
grain on the hero) that make it feel *designed* rather than generic.

**Principles worth stealing:**
- Every headline states the **one takeaway first** in plain language ("Delivered 412 of 500
  target cars · 82% of plan"), computed from live data — not a static title.
- **Health at a glance** through color + a thin colored rail, before the reader parses numbers.
- Cards and KPIs are **drill-downs** — the whole card is a link; the surface is navigable, not
  just readable.
- Restraint: real chroma is reserved for *meaning* (good/warn/bad, categorical series). Chrome is
  near-neutral.

---

## 2. Color system

Colors are defined as CSS custom properties in `:root` / `.dark`, mostly in **OKLCH** (perceptually
uniform lightness — light and dark stay balanced), with a few brand hexes. Tailwind v4 `@theme
inline` maps them to utility classes (`bg-brand`, `text-accent-red`, etc.).

### Brand
| Token | Light | Meaning |
|---|---|---|
| `--brand` | `#1B7A3D` (green) | DealerPulse primary — "healthy/pulse" |
| `--brand-secondary` | `#C2410C` (burnt orange) | Wordmark secondary accent |
| `--ring` | `#176833` | Focus ring, green |

The background carries a **faint green tint** rather than pure white: `--background: oklch(0.985
0.015 150)` — hue 150 (green) at very low chroma. Cards are a hair lighter/greener. This subtle
tint is a big part of the "branded but quiet" feel.

### Semantic accent palette (real chroma, used for meaning)
`--accent-pista` (green, "good"), `--accent-golden` (amber, "warn/caution"), `--accent-red`
("bad/alert"), plus `--accent-turquoise`, `--accent-pink`, `--accent-violet`, `--accent-orange`
for categorical contrast.

### Categorical chart palette
`--chart-1..5` map to brand-green → turquoise → golden → red → violet — chosen to stay distinct
from each other and to follow the theme accent for series 1.

### Neutrals
Foreground `oklch(0.145 0 0)` (near-black) on the tinted background; `--muted-foreground`
mid-gray for secondary text; hairline `--border` at low chroma green.

**Dark mode** redefines every token: near-black background, brand shifts to a lighter, more
chromatic green (`oklch(0.75 0.15 150)`) so it glows against dark. Borders become translucent white
(`oklch(1 0 0 / 16%)`). Semantic accents are re-tuned lighter for dark contrast.

**Theme handling:** three states — explicit `light` / `dark` (via `.dark` class on `<html>`) and
`system`. A tiny inline script in `<head>` applies the class **before paint** (no flash), reading
`localStorage("dp-theme")` and falling back to `prefers-color-scheme`. `color-scheme` is set so
native controls match.

---

## 3. Typography

- **Body / UI:** Geist Sans (`--font-geist-sans`).
- **Headings + big numbers:** **Space Grotesk** (`--font-heading`) — gives titles and KPI figures a
  "crisp modern-SaaS character the neutral body sans doesn't." Applied to `h1,h2,h3` and KPI values.
- **Mono:** Geist Mono, for the occasional monospaced need.
- Headings are `font-semibold tracking-tight`. Numbers use `tabular-nums` everywhere they're
  compared/aligned — a small detail that makes tables and KPIs feel precise.
- KPI value sizing: `text-[1.4rem]`→`sm:text-[1.6rem]`, `leading-none`, tight tracking.

---

## 4. Shape, spacing, elevation

- **Radius scale** built from one token: `--radius: 0.625rem`, with `sm/md/lg/xl/2xl…` derived as
  multiples. Cards are `rounded-xl`; buttons `rounded-lg`; chips `rounded-md`/`rounded-full`.
- **Elevation is quiet.** Almost no drop shadows. Separation comes from **hairline borders**
  (cards use `border border-brand/20` — a faint green-tinted edge), tint changes, and a hover ring
  rather than shadow lift.
- **Hover pattern (`hover-highlight` utility):** a *stationary* 2px `ring-ring` outline on hover,
  with a 150ms color/shadow transition. Nothing moves or lifts — it's a focus cue, not a bounce.
  Reused across cards, buttons, nav links, badges.
- Generous but compact padding; `--card-spacing` drives internal rhythm (default `spacing(4)`, `sm`
  variant `spacing(3)`).
- Layout is centered at `max-w-6xl` with `px-4` gutters and `py-6 md:py-8`.

---

## 5. Layout & navigation

- **Sticky header** (`sticky top-0 z-20`) with `bg-background/95 backdrop-blur` — translucent,
  blurred, hairline bottom border. Contains: brand lockup (a `DP` green tile + "DealerPulse"),
  primary nav, theme toggle, and a global filter bar. Collapses gracefully to stacked rows on
  small screens.
- **Primary nav** = pill tabs with an explicit "you are here": the active route is a **solid**
  `bg-foreground text-background` pill; others are muted with a hover fill. No ambiguity about the
  current view. Horizontally scrollable on mobile.
- **PageHero** — a headline band reused on every page:
  - `rounded-xl` with a **top accent border** (`border-t-2 border-t-brand/60`) and a soft brand
    gradient (`from-brand/10 via-card to-brand-secondary/[0.06]`).
  - A **brand glow** (blurred radial) in the corner + **film grain** (inline URL-encoded SVG
    fractal noise at ~4% opacity) for tactile depth.
  - Structure: optional back-link → title + a **period pill** (rounded-full, brand-tinted ring) +
    actions → a bold plain-language `lead` takeaway → a muted supporting line → CTA buttons →
    optional right-column `visual`. Switches to a two-column hero when a visual is present.

---

## 6. Signature components

- **KpiCard** — the workhorse. Compact card with:
  - a **thin colored left rail** (`before:` pseudo-element) coding health: brand/pista/golden/red
    for neutral/good/warn/bad;
  - uppercase micro-label, big tabular value (tone-colored), sub-caption;
  - an optional **delta chip** (▲/▼ with % or pts, green/red tinted) and an inline **sparkline**;
  - the entire card is a **drill-down link** with an `ArrowUpRight` affordance and a "by branch →"
    caption. On-page anchors expand collapsed sections and smooth-scroll; cross-page uses client nav.
- **Card** — `rounded-xl`, faint `border-brand/20`, `bg-card`, heading in brand color via Space
  Grotesk, quiet hover ring. Header/Content/Footer slots with container-query awareness.
- **Badge** — small pill; variants map to semantic tints (secondary = pista/green "good",
  destructive = red, outline = turquoise). Used for attainment %, statuses.
- **Button** — Base UI button, CVA variants (default solid, outline, secondary, ghost, destructive
  as a *tinted* not-loud red, link). Sizes down to `xs`/icon. Focus = 3px ring.
- **Tabs** — segmented control (bordered muted track, active tab gets a raised background) plus a
  `line` variant with an underline indicator.
- **Progress/pipeline bars** — `h-2.5 rounded-full bg-muted` track with a **brand gradient** fill
  (`from-brand to-brand/55`), width = share of max.
- **Sparkline / charts** — inline trend marks on KPIs; dedicated attainment & funnel charts use the
  categorical chart tokens.

---

## 7. Motion & "moments"

Motion is sparse and purposeful:
- **Cold-start splash** (`IntroSplash`): a full-screen pure-black reveal — the "DEALERPULSE"
  wordmark blooms out of black with a soft baked text-glow over two brand bars (green + burnt
  orange) and a spaced-out "FEEL YOUR DATA" tagline. ~3s emerge-and-hold, then a ~0.55s fade into
  the app. **Shown once per tab session** (sessionStorage gate stamped before paint so it never
  flashes on refresh); `?intro=1` forces it for demos.
- **Route progress** bar on navigation.
- Branded loading animation: a heartbeat "beat" + a sweeping ECG line (keyframes `dp-beat`,
  `dp-ecg`) — reinforces the pulse metaphor.
- Content `dp-rise` (fade + small translate-up) entrances.
- Everything else is 150ms color/ring transitions — no gratuitous movement.

## 8. Ambient backdrop

`AutomotiveBackdrop`: a fixed, `-z-10`, ~16% opacity SVG pattern of hand-drawn-style automotive
line marks (car, wheel, gauge, fuel pump, key, speed lines) tiled behind every route, tinted in
brand + accent colors. It's the subtle texture that ties the "car dealership" subject to the
otherwise-neutral dashboard without ever competing with content.

---

## 9. Accessibility & polish details

- Visible focus everywhere: `focus-visible` rings/outlines with offset; `outline-ring` default.
- `aria-current="page"` on active nav; `aria-hidden` on decorative layers (glow, grain, backdrop).
- `aria-label`s summarize drill-down cards ("Units delivered: 412. by branch").
- `tabular-nums` for all compared figures; `scroll-mt-*` so anchored sections clear the sticky header.
- `suppressHydrationWarning` + pre-paint theme script to avoid theme flash.
- Smooth scroll; reduced reliance on color alone (icons + text accompany the good/bad tints).

---

## 10. Cheat-sheet to reuse the vibe

1. Pick one brand hue; tint the *background* with a trace of it (very low chroma) instead of pure
   white. Define all colors in OKLCH so dark mode stays balanced.
2. Reserve saturated color for meaning (good/warn/bad + a small categorical set). Keep chrome near-neutral.
3. Two-typeface split: neutral sans for body, a characterful geometric sans for headings + big numbers; `tabular-nums` always.
4. Separate surfaces with hairline (brand-tinted) borders and a *stationary hover ring*, not shadows.
5. One radius token, derive the rest. `rounded-xl` cards.
6. Lead every page with the computed plain-language takeaway, plus a period pill.
7. Make cards navigable drill-downs with a small directional affordance.
8. Add exactly a few "moments" (a once-per-session splash, a themed ambient backdrop, hero grain) — and stop there.
9. Ship light/dark with a pre-paint no-flash theme script and a system option.
