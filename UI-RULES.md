# UI-RULES.md

**This document governs every pixel in this app. Read it before writing any screen code.**

`DECISIONS.md` records *why*. This file states *what you must do*. If a screen
disagrees with this file, the screen is wrong.

Approved 2026-09-13. This document records the implemented CHECKMATE UI system.

---

## 1. The one-helper rule

Every visual value comes from `lib/core/theme/`. There are no exceptions.

```
lib/core/theme/
  app_colors.dart     raw hex values, light + dark — the ONLY file where a hex literal may appear
  app_theme.dart      ThemeData light + dark, all component themes
  app_tokens.dart     spacing, radius, elevation, duration
  app_text.dart       the TextTheme
  app_icons.dart      concept -> glyph — the ONE icon vocabulary (§6.6)
  status_style.dart   status/outcome -> (label, colour, treatment) — the ONE mapping
```

**Banned in `lib/features/**` and `lib/core/widgets/**`:**

| Never write | Write instead |
|---|---|
| `Colors.green`, `Colors.grey`, any `Colors.*` | a `colorScheme` role, or `context.attention` |
| `Color(0xFF...)` | a role in `app_colors.dart` |
| `fontSize: 17` | `Theme.of(context).textTheme.titleMedium` |
| `fontWeight:` inline on a themed style | the token already carries its weight |
| `EdgeInsets.all(16)` | `EdgeInsets.all(Space.lg)` |
| `SizedBox(height: 12)` | `SizedBox(height: Space.md)` |
| `BorderRadius.circular(12)` | `Radii.md` |
| `elevation: 2` | see §5 — flat by default |
| emoji as status (`✅`, `⏭️`) | an `Icon` from the status style |
| `Icons.check`, any bare `Icons.*` | a concept from `AppIcons` — see §6.6 |

This mirrors the existing hard rule that all date/time rendering goes through
`core/format/datetime_format.dart`. Same reasoning, same enforcement.

---

## 2. Colour

### 2.1 The two-job doctrine

The app has two colours of **equal presence** and **divided duty**.

> **Green owns action and affirmation. Orange owns attention and pending state.**

| | Green (`primary`) | Orange (`attention`) |
|---|---|---|
| **Job** | what you press; what went well | what is waiting on you; what to look at |
| **Owns** | filled buttons, FAB, selected nav, Approve, Mark done, Approved + Done badges, success — **plus structural chrome: app bar, list icons, section rules, empty states (§2.7)** | Pending badges, needs-decision counts, DST + quiet-hours warnings, unread markers — **and structure only where it labels real attention (§2.7)** |
| **Register** | resolved, settled | unresolved, live |

Presence stays balanced without sprinkling: this app is *about* the gap between
proposed and resolved, so pending states are as common on screen as actions are.

**Green is not "primary" in the sense of outranking orange.** Neither colour is
subordinate. If you find yourself reaching for orange to add emphasis to an
action, or green to mark something as waiting, you have the doctrine backwards.

### 2.2 Roles

Light:

| Role | Hex |
|---|---|
| `background` | `#F3F7F3` |
| `surface` (cards, sheets) | `#FFFFFF` |
| `surfaceContainer` | `#EAF1EB` |
| `surfaceContainerHigh` | `#DFE9E0` |
| `onSurface` | `#141A15` |
| `onSurfaceVariant` | `#4B574D` |
| `outline` | `#6E7A70` |
| `outlineVariant` | `#D1DCD2` |
| `primary` | `#1B7A3D` |
| `onPrimary` | `#FFFFFF` |
| `primaryContainer` | `#C5EBD1` |
| `onPrimaryContainer` | `#04250F` |
| `attention` | `#B4400C` |
| `onAttention` | `#FFFFFF` |
| `attentionContainer` | `#F3C29A` |
| `attentionContainerStrong` | `#E9863F` |
| `onAttentionContainer` | `#441C06` |
| `error` | `#B3261E` |
| `onError` | `#FFFFFF` |
| `errorContainer` | `#F9DEDC` |
| `onErrorContainer` | `#410E0B` |

Dark — re-picked, not inverted. Chroma drops and lightness rises, because
saturated hues vibrate on dark surfaces.

| Role | Hex |
|---|---|
| `background` | `#0F1511` |
| `surface` (cards, sheets) | `#18201A` |
| `surfaceContainer` | `#18201A` |
| `surfaceContainerHigh` | `#232D25` |
| `onSurface` | `#E6EEE7` |
| `onSurfaceVariant` | `#AFBBB1` |
| `outline` | `#8A958C` |
| `outlineVariant` | `#39453B` |
| `primary` | `#56CE7E` |
| `onPrimary` | `#00391B` |
| `primaryContainer` | `#1E5233` |
| `onPrimaryContainer` | `#B6F2C6` |
| `attention` | `#F0A56E` |
| `onAttention` | `#491E05` |
| `attentionContainer` | `#A5551E` |
| `attentionContainerStrong` | `#9C531C` *(same — see §2.4)* |
| `onAttentionContainer` | `#FCE7D6` |
| `error` | `#F2B8B5` |
| `onError` | `#601410` |
| `errorContainer` | `#8C1D18` |
| `onErrorContainer` | `#F9DEDC` |

**Note on `surface`.** In light, cards are `#FFFCF8` on a `#FAF5EE` scaffold — a
1.06 tonal step, so the border carries the edge. In dark, cards are `#2B2421` on
a `#1F1916` scaffold — a 1.14 step. Both are deliberate: separation comes from
the border, not from a large tonal jump.

**Both neutral ramps carry a terracotta cast — this is deliberate (§2.7).** They
are not grey. Dark's is roughly 2.4x the warm chroma of the original ramp; a
subtler first pass rendered as indistinguishable from neutral, which defeated
the point. Never "correct" these toward grey.

**`attention` is not a Material role.** M3 has no such slot. It is mapped onto
`tertiary`/`tertiaryContainer` so Material widgets can reach it, and exposed as
`attention` via a `ThemeExtension` so call sites read semantically. Prefer
`context.attention`; never reach for `tertiary` by name.

### 2.3 Status colours — one mapping, in `status_style.dart`

| Status | Colour | Treatment |
|---|---|---|
| Pending | orange | `attentionContainer` fill + `onAttentionContainer` text |
| Approved | green | `primaryContainer` fill + `onPrimaryContainer` text |
| Done | green | **solid** `primary` fill + `onPrimary` text — strongest, this is the win state |
| Rejected | neutral | transparent fill + `outline` border + `onSurfaceVariant` text |
| Skipped | neutral | *(same as Rejected)* |
| Cancelled | neutral | *(same as Rejected)* |
| Withdrawn | neutral | *(same as Rejected)* |

**All four neutral statuses share one treatment.** The label differentiates them;
the colour does not need to. A "dimmed" variant was designed and **rejected** —
it measured 4.43:1 in dark mode, under AA. Do not reintroduce tonal dimming to
distinguish neutral statuses. (See §7.)

Rejected and Skipped are **not** errors. A target rejecting a plan or skipping an
item is a legitimate outcome — the consent model says so. Neither is ever red.

### 2.4 Warning is orange, not a third hue

DST gaps, overlaps, and quiet-hours warnings use the **attention** family, pitched
up from pending: solid left rule + icon + heavier weight, versus pending's flat
tint. Both mean "look at this," so they share a hue honestly.

**Amber is banned.** It sits ~10° from our orange and reads as a muddy near-miss.

**`attentionContainerStrong` is the panel's fill — never a badge's.** Same hue
(26°) and saturation (69%) as `attentionContainer`; only lightness is pitched
up. It exists because the panel is the largest attention fill in the app and
needs the same separation from its background in both modes, while a badge at
that strength would out-shout Approved. Measured pull over `primaryContainer`:

| vs card | `primaryContainer` | `attentionContainer` | `attentionContainerStrong` |
|---|---|---|---|
| light | 1.27 | 2.05 | **2.71** |
| dark | 1.64 | 2.66 | **2.66** *(same value)* |

In **dark the two roles hold the same value** — dark already had the separation,
so only light diverges. That is the seam where the modes legitimately differ
(§8), not a redundant token. Text, rule and icon on either fill use
`onAttentionContainer`; there is no separate `on*Strong`.

### 2.5 Red is rationed

`error` appears only for:

- destructive confirmations (Withdraw, Leave group, Delete)
- authentication and system failures
- form validation errors

**Red never appears as a status badge.** Rationing is what keeps it forceful.

### 2.6 Hard colour constraints

1. **`outline` is never a text colour.** It measures 3.65 (light) / 3.89 (dark)
   against the darkest containers — fine for a border, a fail for text. Use
   `onSurfaceVariant` for muted text.
2. **`outlineVariant` is decorative only** (1.51 light / 1.60 dark). Hairline
   dividers and card edges. Any border that carries meaning on its own — a
   neutral badge's outline, a focus ring, a selected state — uses `outline`.
   A neutral badge bordered in `outlineVariant` measures **1.42** in dark: its
   only structure, invisible.
3. **Never encode state in colour alone.** Every status badge carries a text
   label. Colour reinforces; it does not inform.

### 2.7 Structure vs state — the filled-vs-line firewall

Colour enters this app in **three** categories, not two. Know which one you are
reaching for before you type a colour.

| Category | What it is | Rule |
|---|---|---|
| **State** | Pending, Approved, Done, warning | **filled shapes only** — pills, panels |
| **Structure** | app bar, section rules, list icons, empty-state icons, focus | **line work and text only** — never a fill |
| **Temperature** | the neutral ramp's own terracotta cast (§2.2) | not an element at all |

> **The firewall: a filled shape is state. Line work and text are structure.**

This is what lets both colours be present everywhere without orange going
decorative where it must stay semantic. "An orange **filled pill or panel** means
something is waiting on you" stays true and learnable, because structural orange
is never a fill.

**Enforced.** `ui_rules_lint_test.dart` rejects any `attention*` role used as a
`Container`/`BoxDecoration` colour outside `status_style.dart` and
`warning_panel.dart`. If you need a new orange fill, it is a new *state* — add it
to `status_style.dart`, don't inline it.

**Which colour for structure.** Green by default: the app bar title and icons,
list-tile icons, ordinary section rules, empty-state icons. Orange **only** where
the structure labels genuinely attention-bearing content — a "Waiting on you"
section rule, a pending count badge. Structure never invents a new meaning for
orange; it only ever points at attention that is really there.

**Temperature is the honest always-on orange.** Both neutral ramps are cast warm
(§2.2). Nothing *becomes* orange, so nothing can be misread as state. This is
where "orange is present on every screen" is actually paid for.

**Accepted limitation.** A screen with no pending state and no warning shows
orange only as temperature. That is correct, not a gap — orange means attention,
so always-on orange elements would spend the trust that makes the badge readable.
An always-on orange app-bar rule was mocked, costed, and **held** (DECISIONS.md,
2026-07-25); taking it would require amending §2.1.

### 2.8 Data-viz colour — charts are not an exception to the two hues

Charts, meters and sparklines pull colour from ONE place:
`AppDataVizColors` in `lib/core/theme/dataviz_tokens.dart`, an extension over the
scheme. A chart never invents a palette, and it introduces **no new hex** — every
role maps onto an already-verified colour (§7), so adding data-viz adds nothing
to check.

| Role | Maps to | Use |
|---|---|---|
| `seriesPrimary` | `primary` (sage) | The main series; every progress fill; "completed / good". |
| `seriesAttention` | `tertiary` (terracotta) | The pending / attention series — **line or marker only**. |
| `seriesMuted` | `primaryContainer` | A comparison series, when one is not enough. Not a third hue. |
| `chartGrid` | `outlineVariant` | Gridlines, ticks — decorative structure. |
| `chartAxisLabel` | `onSurfaceVariant` | Axis labels, legends. |
| `progressTrack` | `surfaceContainerHigh` | The unfilled part of a meter/ring. |

**The §2.7 firewall extends onto charts.** A filled area is state; a filled
*orange* area is the "waiting on you" signal. So the attention series is drawn as
a **line, dot or label**, never a filled region — a filled region uses
`seriesPrimary` (sage), which §2.7 does not restrict. There is deliberately no
orange-fill getter in `dataviz_tokens.dart`: adding one would both spend the
signal on decoration and launder the banned `tertiaryContainer` past the §2.7
lint. If a chart needs a filled "pending" area, that is a new state — it belongs
in `status_style.dart` (§2.3), not inlined into a chart.

More than two series: add neutral *shape* (dashed vs solid, marker glyph), never a
new hue. The palette stays two.

---

## 3. Type

System font. No custom family: `supportedLocales` covers ~80 locales, and the
system font is the only thing guaranteed to have the glyphs.

| Token | Size / line | Weight | Use |
|---|---|---|---|
| `displaySmall` | 32 / 40 | 700 | heroes only — the auth screen, and the schedule hero band |
| `titleLarge` | 20 / 28 | 600 | screen section headers |
| `titleMedium` | 17 / 24 | 600 | card titles |
| `bodyLarge` | 16 / 24 | 400 | default body |
| `bodyMedium` | 14 / 20 | 400 | dense body |
| `labelLarge` | 14 / 20 | 600 | buttons |
| `bodySmall` | 13 / 18 | 400 | hints, secondary prose |
| `labelSmall` | 12 / 16 | 500 | timestamps, timezone labels, metadata |
| `codeDisplay` | 22 / 28 | 700, ls 3 | invite codes and any code-like string |

`codeDisplay` lives on the `AppTypeExtension`, reached via `context.codeDisplay`.

**Rules:**

- Never write `fontSize`. Never write `fontWeight` on a themed style — the token
  carries it.
- **`displaySmall` is for heroes, and there are exactly two.** Its remit was
  widened from "auth hero only" on 2026-08-20 when the schedule hero band needed
  a size above `titleLarge` — at `titleLarge` the band was the same size as the
  "Today" section header directly beneath it, so it did not out-rank the list it
  introduces. Adding a tenth token was the alternative and bought nothing: both
  call sites are the largest thing on their screen, which is what this slot
  means. It is still not a general-purpose "big text" — a third use needs a
  `DECISIONS.md` entry, per §9.
- Card titles are `titleMedium`. All of them. (The old UI had 18 on two screens
  and 17 on a third for the same element; that is the drift this prevents.)
- Secondary prose is `bodySmall`. Metadata — timestamps, tz labels, counts — is
  `labelSmall`. Do not use `labelSmall` for anything a user reads as a sentence.
- **Prose wins.** When a line mixes metadata into a sentence — "for Sam · Tue 9:00
  (Asia/Kolkata, their local time)" — it is prose, so it is `bodySmall`.
  `labelSmall` is for bare metadata standing on its own: a timestamp in a corner,
  a count on a badge.
- **Italic is not in the scale.** Quoted user content — notes, skip reasons,
  rejection reasons — is distinguished by `onSurfaceVariant` colour, not by
  italics. Long italic runs hurt legibility and pile a second axis of emphasis on
  top of a system that already has colour and weight.
- Colour a text token by passing `.copyWith(color: ...)` with a role, never by
  wrapping in a differently-styled `TextStyle`.

---

## 4. Spacing, radius, motion

### Spacing — 4pt grid, `Space` in `app_tokens.dart`

| Token | Value |
|---|---|
| `Space.xs` | 4 |
| `Space.sm` | 8 |
| `Space.md` | 12 |
| `Space.lg` | 16 |
| `Space.xl` | 24 |
| `Space.xxl` | 32 |
| `Space.xxxl` | 48 |

`6`, `10`, and `20` are **off-grid and banned**. Migration: `6 → xs`, `10 → md`,
`20 → xl`.

Conventions: screen padding `xl` for forms, `lg` for lists. Card margin
`symmetric(horizontal: md, vertical: sm)`. Card interior padding `lg`.

### Radius — `Radii` in `app_tokens.dart`

| Token | Value | Use |
|---|---|---|
| `Radii.sm` | 8 | inputs, small tints, warning panel |
| `Radii.md` | 12 | cards, containers |
| `Radii.lg` | 16 | dialogs, bottom sheets |
| `Radii.pill` | 999 | badges, chips, filled buttons |

### Motion

`Motion.fast` 150ms, `Motion.normal` 250ms. Curve `Curves.easeOutCubic`.
Calm means short and unfussy — no bounce, no overshoot.

---

## 5. Elevation — flat by default

**Elevation 0 + a 1px `outlineVariant` border. Everywhere.**

Definition comes from structure — border and spacing — not from shadow. Shadows
are the fastest way to lose "calm," and a muted palette under drop shadows reads
washed-out rather than deliberate.

**The only exceptions.** Anything that floats *over* content gets a shadow;
anything that sits *in* the flow does not.

| Surface | Elevation |
|---|---|
| Cards, list rows, badges, panels, inputs | **0** + `outlineVariant` border |
| Navigation bar | M3 tonal level 2 |
| Dialogs | level 3 |
| Bottom sheets | level 3 |
| Snackbar | level 3 |

`Card` must never be constructed bare — use the recipe in §6.1, which sets
elevation 0 and the border. A bare `Card` inherits Material's default shadow.

---

## 6. Component recipes

Copy these. Drift starts the moment someone rebuilds a card from scratch.

### 6.1 Card

```
Card(
  margin: EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
  elevation: 0,                                  // from cardTheme; never override
  shape: RoundedRectangleBorder(
    borderRadius: Radii.md,
    side: BorderSide(color: colorScheme.outlineVariant),
  ),
  child: Padding(padding: EdgeInsets.all(Space.lg), child: ...),
)
```

`app_theme.dart` sets this as the global `CardTheme`, so in practice a screen
writes `Card(child: Padding(...))` and inherits the rest.

### 6.2 Status badge

Always via `statusStyle(status)` from `status_style.dart` — never a local
`switch`. Padding `symmetric(horizontal: Space.md, vertical: Space.xs)`, radius
`Radii.pill`, text `labelSmall`. Neutral variants carry a 1px `outline` border;
tinted and solid variants carry no border.

### 6.3 Warning panel

Always via `WarningPanel` from `core/widgets/warning_panel.dart` — never rebuilt
inline, same rule as the status badge.

Radius `Radii.sm`, fill **`attentionContainerStrong`** (§2.4 — not the badge
tint), a 3px solid left rule and an icon — **both in `onAttentionContainer`, not
`attention`** — text `bodySmall` in `onAttentionContainer`, padding `Space.md`,
margin-top `Space.md`.

The rule and icon match the text because they sit on the container fill, and
`attention` on `attentionContainer` measures only 2.69:1 in dark since that
container was raised — below even the 3:1 non-text floor. `onAttentionContainer`
clears it on both fills and in both modes (4.99 dark / 5.13 light strong /
11.46 light tint).

### 6.4 Buttons

- Primary action → `FilledButton` (green, `Radii.pill`)
- Secondary → `OutlinedButton` (`outline` border)
- Tertiary / inline → `TextButton`
- Destructive → `FilledButton` with `error` fill, only per §2.5

One primary action per screen. Minimum touch target 48dp.

### 6.5 Empty state

Icon at 40px in **`primary`** (structure — §2.7), `Space.md` gap, `titleMedium`
headline, `Space.sm` gap, `bodySmall` in `onSurfaceVariant`, `Space.lg` gap, then
an optional action.

The icon was `onSurfaceVariant` until 2026-07-25. That rule existed to keep
`outline` out of a text-adjacent role (§2.6); `primary` does not reintroduce that
problem — it measures 6.50 (light) / 8.92 (dark) on the scaffold against a 3:1
non-text floor. An empty state is a resting state, not a failure, so green is
honest there.

**The error and timeout states are NOT green.** Green means action and
affirmation; a failure is neither. `AsyncView`'s `_Retryable` icon stays
`onSurfaceVariant`. Only the genuine empty state takes `primary`.

### 6.6 Icons

Always via a concept name from `app_icons.dart` — **never a bare `Icons.*` at a
call site**, same rule as the status badge and the warning panel. Names are
semantic, not glyph-named: `AppIcons.pending`, never `AppIcons.schedule`. The call
site reads the meaning; the glyph can be re-picked without touching a screen.

**Two rules govern the vocabulary.**

> **1. One concept, one glyph.** A glyph means exactly one thing in this app.

Before this file existed, `Icons.check` was the Approved badge, the Done badge and
"this row is selected"; `Icons.inbox_outlined` was both "there is nothing here"
and "go to your queue"; and `Icons.login` was both sign-in and join-a-group. If
you need a glyph for a new concept, add the concept — do not reuse a neighbour.

> **2. Filled = selected or active. Outlined = available or at rest.**

Only the navigation bar has a selected state today, so in practice nav
destinations carry both variants and **everything else is outlined**. Fill weight
is not available to encode anything else — the schedule builder previously used
`person_outline` vs `person` to mean *self vs other*, a private convention no user
could decode. This is the icon-axis form of §2.6(3): the label informs, the glyph
reinforces.

**Colour** — §2.7 restated, no new rules:

| Icon | Colour | From |
|---|---|---|
| Structural (app bar, list tiles, empty state) | `primary` | `appBarTheme` / `listTileTheme` / §6.5 |
| Status and outcome badges | per status | `statusStyle()` |
| Error and timeout | `onSurfaceVariant` | §6.5 — a failure is not affirmation |
| Warning panel | `onAttentionContainer` | §6.3 |

**No icon is given an inline colour at a call site.**

**Archive is never drawn or worded as deletion.** `AppIcons.archive` /
`AppIcons.unarchive` are the archive-box pair, and no archive affordance may use a
bin glyph or the word "Delete"/"Remove". The document is untouched and the other
party still sees it — copy or a glyph implying otherwise would be the exact
dishonesty "delete for me" was rejected for (DECISIONS.md "Group D").
`AppIcons.emptyArchive` is a **third** glyph on purpose: "hide this" and "you have
hidden nothing" are opposite messages, and rule 1 applies.

**Secondary card actions go behind `AppIcons.overflow` (⋮), not inline.** Cards
live in scrollable lists, so an exposed control — especially one that makes the row
disappear — is a mis-tap waiting to happen. Inline is for a card's *primary*
action only.

**Size** — `Sizes.listIcon` / `Sizes.appBarIcon` (24), `Sizes.emptyStateIcon` (40),
`Sizes.inlineIcon` (20), `Sizes.badgeIcon` (14). Never a literal.

**Note on `AppIcons.warning`.** Its glyph is Material's
`warning_amber_rounded`. The name is a Material naming artifact and has nothing to
do with the amber banned in §2.4 — the icon renders in `onAttentionContainer` on
the attention fill. Naming the concept `warning` is precisely so no call site ever
types "amber" again.

**Enforced.** `ui_rules_lint_test.dart` rejects any bare `Icons.` in a governed
file, `lib/dev/` included — the preview harness demonstrates the system rather than
sitting outside it.

---

### 6.7 Progress

Two shapes, and which one you use is a statement about what you know.

**Determinate — you know the total.** A `LinearProgressIndicator` with a real
`value`:

```
LinearProgressIndicator(
  value: received / total,          // never null here
  minHeight: Sizes.progressBar,     // 8
  borderRadius: Radii.pill,
)
```

`primary` for the bar (theme default), `surfaceContainerHighest` for the track.
Always paired with the same fact in words underneath — `bodySmall` in
`onSurfaceVariant`, e.g. "48.2 MB of 130 MB". A bar alone tells someone that
something is happening; the line underneath is what tells them whether to wait.

**Indeterminate — you do not.** A `CircularProgressIndicator`, sized to whatever
it replaces (`Sizes.buttonSpinner` inside a button). Never a *linear*
indeterminate bar: a sliding stripe reads as a stalled determinate one.

Rules:

- **Progress is green, never orange.** Work in flight is action, which is what
  `primary` means. A progress bar is a filled shape, and under §2.7 an orange
  fill means "waiting on you" — the one signal the app cannot afford to spend
  on a spinner. A failure during that work is a `WarningPanel` (§6.3); that is
  where the orange belongs.
- **Never fake a total.** If the size is unknown, the indicator is
  indeterminate. A bar that crawls to 90% and sits there is worse than a
  spinner, because it made a promise.
- **A determinate bar never goes backwards.** Retrying part of a longer job
  restarts *that segment's* number, so name the segment ("File 2 of 4") rather
  than letting the percentage jump down with nothing to explain it.

---

### 6.8 Avatars

**One widget: `AvatarImage`.** Every profile picture in the app draws through it
— list rows, profile headers, the edit form. Three sizes and no more, because
each is a place a picture actually appears:

| Token | Value | Where |
|---|---|---|
| `Sizes.avatarRow` | 40 | A list row's leading slot |
| `Sizes.avatarHeader` | 72 | The profile screen header |
| `Sizes.avatarEditable` | 96 | The edit form, with its controls beside it |

`avatarRow` is deliberately under `Sizes.touchTarget`: the ROW supplies the 48pt
target, so sizing the image to it would make every row taller.

**The fallback is a letter, not a glyph.** No picture → the display name's first
grapheme on a `primaryContainer` tint. A container tint and line work, never an
orange fill (§2.7) — a person without a photo is not a state waiting on you.

**`AppText.avatarInitial(diameter)` sizes that letter, and it is NOT a tenth
entry in the type scale (§3).** The scale is nine sizes for text people read;
this is a letterform used as a graphic, filling a circle whose diameter is a
layout token. A fixed style cannot serve all three — `titleMedium` is right at
40 and becomes a letter adrift at 96 — so the size is derived from the diameter
and the optical weight stays constant.

**Never wrap an avatar in anything that re-decodes it.** No `cacheWidth`,
`cacheHeight`, crop or compression pass. Flutter animates GIF and WebP natively;
re-encoding is how a multi-frame image silently becomes a still, and animated
pictures are a supported feature, not an accident. Size is enforced by *refusing*
an oversized file (`avatar.dart`), never by shrinking one behind the user's back.

**A failed load falls back to the initial**, never a broken-image glyph. A
stored URL can 404 — object deleted, bucket moved, network down mid-scroll — and
a moderated picture resolves to null by the same path, so there is exactly one
code path for "no picture to draw".

---

### 6.9 Stat tiles

Flat, outlined, no fill — a card by §6.1's rules. A tile HOLDS a number; it is
not a state to act on, so it gets a hairline `outlineVariant` border and no
shadow.

**They reflow, they do not break.** The stats grid computes its column count
from the available width against `Sizes.statTileMinWidth` (148), so three
columns become two become one as the screen narrows. No breakpoint, and no
clipped labels.

**Absence is an em dash, never a zero.** A stat with no value renders `—`, in
`onSurfaceVariant` so it cannot compete with the real numbers beside it. Two
different absences exist and each carries its own explanation rather than its
own glyph:

| State | Tile | Explained by |
|---|---|---|
| `placeholder` | `—` | "Coming soon" caption under the label |
| `hidden` | `—` | A line above the grid: this profile is private |

A zero would be a lie in both cases — indistinguishable from a measured zero,
and confidently wrong.

### 6.10 Calendar

The calendar (`lib/features/calendar/`) is a **view over the item stream**, and
its recipes exist so it stays one — nothing here invents a colour, a status or a
second rendering of an item's controls.

**Sizes.**

| Token | Value | Use |
|---|---|---|
| `Sizes.calendarCellHeight` | 48 | One day cell in the month/week grid |
| `Sizes.calendarMarkerDot` | 6 | One item's dot in a day cell |
| `Sizes.calendarMarkerRow` | 16 | Height reserved for the marker row |
| `Sizes.calendarHourGutter` | 56 | The hour-label column in the day view |
| `Sizes.calendarHourRow` | 56 | Minimum height of one hour row |

`calendarCellHeight` is the touch target, not a layout preference — a cell is
how a date is selected, so it meets the 48dp floor in §7 exactly. Do not shrink
it to fit more weeks.

**Day markers take their colour from the ONE status mapping.** A dot is *state*,
so its fill comes from `statusStyle()` / `outcomeStyle()` in `status_style.dart`
— `style.background` for the tinted and solid treatments, `style.border` for the
neutral one, whose background is transparent by design. The calendar never names
an `attention*` role itself, so the §2.7 firewall holds with no exemption and no
entry in the lint's owner list. If a day needs a new kind of mark, that is a new
state: add it to `status_style.dart`.

Cap the dots at four and show a `labelSmall` overflow count; a cell that fills
with dots stops distinguishing a busy day from a full one.

**Every day number, weekday name and hour label goes through
`core/format/datetime_format.dart`,** like all other time rendering (§1). This
is not pedantry here: `table_calendar`'s own cell builders interpolate
`'${day.day}'`, which is Latin digits, and would silently break the app's
worldwide requirement in any locale that renders its own numerals. That is the
reason every cell in this app is drawn by our builder rather than the package's.

**The week starts where the locale says.** `MaterialLocalizations.of(context)
.firstDayOfWeekIndex`, never a constant, never Monday-by-default.

**No time-blocking, and no proportional day grid.** `ScheduleItem` carries an
instant, not a span — it has no duration field. The day view is an hour *rail*:
items are pinned beside the hour they fall in, each at its natural card height.
An item drawn as a sized block would be asserting a duration the model does not
have. If `durationMinutes` ever lands, this section is what changes first.

**A tapped item opens a detail sheet, and the sheet routes rather than acts.**
Done, Skip, Approve, Reject and Withdraw live on the screens that already own
them; the sheet's one primary action navigates there. Two renderings of one
item's controls are two things to keep in step — the same reasoning
`OutcomeScreen` gives for not being a detail screen.

### 6.11 The target-schedule modal

The one blurred surface in the app (`showTargetScheduleModal`). It exists so a
planner can see what the target already has booked before choosing a time.

**Not a route.** A function, like every other dialog and sheet here. It is
transient state inside the builder, not a location.

| Token | Value | Use |
|---|---|---|
| `Blurs.modalBackdrop` | 12 | `ImageFilter.blur` sigma behind the modal |
| `Sizes.modalMaxWidth` | 420 | The card stops growing past this |
| `Sizes.modalMaxHeightFraction` | 0.8 | Never taller than this share of the screen |
| `Sizes.slotRowHeight` | 48 | One selectable slot — the §7 touch floor |

**The backdrop is blur PLUS a scrim, never blur alone.** Blur lowers contrast
without raising it anywhere; text over a purely blurred background fails §7 at
some wallpapers and passes at others. The scrim is what makes the floor
predictable.

**Slot state is drawn with the ONE status mapping where a real item owns the
slot** — a blocked slot shows the occupying item's badge via `statusStyle()` /
`outcomeStyle()`. A slot that is merely *unselectable* (in the past) is line work
and `onSurfaceVariant`, never a status colour: nothing is waiting on anyone there.

**A blocked slot is disabled, not hidden.** The planner has to be able to see
*why* a time is unavailable — the point of the modal is showing B's day, and a
gap where a conflict lives is indistinguishable from free time.

**Both times, whenever the zones differ.** The target's local time is primary and
always labelled with the zone; the planner's own equivalent is secondary
`labelSmall`. Never render a bare "4pm" in this modal — whose 4pm is the exact
confusion it exists to prevent. All of it through
`core/format/datetime_format.dart` (§1).

---

### 6.12 Product-pillar navigation & the docked voice FAB

The bar names the app's **pillars**: `Plan · Track · ⊕ · Stats · You` — a change
from the earlier "three delegation stances" (those three are now sub-navigation
*inside* Plan). Full reasoning in DECISIONS.md "UI redesign — Hearth + Candidate
A". Recipes so it stays Hearth:

- **The bar is flat chrome** (`Elevations.nav`), scaffold-background fill, active
  pillar = filled sage icon + label (§6.6 filled-selected), inactive = outline
  icon in `onSurfaceVariant`. The pending-attention **count** rides the **Plan**
  icon (aggregate) and the **My Schedule** sub-tab — the one orange the bar may
  carry (§2.7), rendering nothing at zero.
- **Two FABs, and only these two, each with a distinct job** (revised 2026-08-27,
  DECISIONS.md "Per-page create FABs"). The old "one FAB, always" rule is retired:
  a single centre-docked mic left *manual* create hidden behind knowing to open an
  app-bar overflow, which confused users who stayed on My Schedule.
  1. The docked centre **voice FAB** — a standard (56) circular `primary` (sage)
     FAB, mic glyph, *gentle* floating shadow (`Elevations.floating`). Speak-to-
     create. Owned by `HomeShell` (the outer scaffold), present on every pillar.
  2. A **manual-create FAB**, bottom-right (`endFloat`), circular `primary` with
     the **`AppIcons.add` (`＋`)** glyph — the WhatsApp-style "new item" affordance.
     Exactly one per creating pillar: **Plan** ("Plan an item", all three sub-tabs)
     and **Track** ("Log item"). Owned by the pillar's own (inner) scaffold, so it
     sits above the system nav bar and clears the bottom bar. Each carries its own
     `heroTag` so it never collides with the voice FAB in a route transition.
  The two never merge and never appear a third time: mic = voice, `＋` = manual.
  Manual create is **no longer** an app-bar `＋`. Detail/leaf pushed screens carry
  no FAB.
- **Bottom edge respects the system nav bar.** Any full-screen **pushed** route
  (no in-app bottom bar of its own) that scrolls or docks a control to the bottom
  pads its content by the system navigation-bar inset, via
  `Space.screenListSafe(context)` / `screenFormSafe(context)` /
  `systemBottomInset(context)` — never a bare `Space.screenList`/`screenForm` on
  such a screen, or the last row / footer button slides under the phone's
  back/home/recents bar. **In-shell tab bodies must NOT add it** — the shell's
  `BottomAppBar` already reserves that space, and adding it leaves a gap.
- **Plan inner TabBar:** the three sub-tabs (My Schedule / Activity / Groups) use
  a soft `primary` underline indicator on a scaffold-background bar, swipeable,
  all kept alive. It is nav between sub-screens, not a filter — so a TabBar, not
  segmented buttons. Labels are text; the bar carries no fill.

### 6.13 The Track log sheet

Logging time is a bottom sheet, not a screen (`Radii.lg`, `Elevations.floating`):

- **The minutes field is the primary control** — a numeric input, digits-only,
  validated 1..1440 (`kMaxEntryMinutes`, §data model). Store minutes; display
  rolls to `Xh Ym` only past 59 (the unit rule).
- **Quick-add chips are sage, not orange.** Optional `15 / 30 / 45 / 60` chips
  are `ChoiceChip`s on a `primaryContainer` tint with `Radii.pill` — a convenience
  fill, and a sage one, so it stays clear of the §2.7 firewall. They *set* the
  minutes field; they never submit on their own.
- **Actions:** `Not now` (text) / `Log` (filled sage, §6.4). The Done→track prompt
  (`log_from_done_prompt.dart`) is the same recipe with the task name pre-filled;
  the voice flow is the same recipe with the minutes pre-filled — one sheet, three
  entry points.

### 6.14 The Stats dashboard

Composes primitives that already exist — it invents nothing:

- **Stat tiles** are §6.9 exactly: flat, outlined, reflowing, `—` for absence
  (never zero). Until the stat computations land (a separate, ungreenlit build)
  every tile is a `placeholder` with its "Coming soon" caption — the dashboard is
  shipped empty-but-honest, not faked.
- **A number-hero** — the one large figure a dashboard may lead with (a streak, a
  total) — reuses `AppText.displaySmall`. This is a **sanctioned third use** of
  that token (alongside the auth hero and the My Schedule band); it is still not a
  general-purpose big-text slot. Hearth allows the figure to feel celebratory
  through *size and warmth*, never through a new hue.
- **Charts** pull every colour from §2.8 (`AppDataVizColors`) and every meter from
  §6.7. Personal-dashboard numbers are distinct from the social-profile stats on
  `/u/:uid`: same tile recipe, different surface and framing ("my dashboard", not
  "someone's profile").

---

## 7. Accessibility floor

**Every text pairing hits WCAG AA (4.5:1) in both modes. Verified by computation,
not by eye.**

Measured minimums:

| Pairing | Light | Dark |
|---|---|---|
| `onSurface` on any surface | 13.70 | 10.71 |
| `onSurfaceVariant` on any surface | 6.03 | 6.39 |
| `primary` / `attention` / `error` on any surface | 5.36 | 6.11 |
| Text on solid button fills | 7.05 | 8.43 |
| `on*Container` on its container | 6.78 | 6.62 |
| `primary` on `primaryContainer` | 5.43 | 4.77 |
| `onAttentionContainer` on `attentionContainer` | 6.78 | **4.99** |
| `onAttentionContainer` on `attentionContainerStrong` | 5.13 | **4.99** |
| warning panel fill vs the card it sits on † | 2.71 | 2.66 |
| Neutral badge text on card | 7.48 | 7.48 |
| Neutral badge border on card (needs 3:1) | 4.64 | 4.89 |
| Pending tint vs card | 2.05 | 2.66 |
| Approved tint vs card | 1.27 | 1.64 |
| **Pending's pull over Approved** | **1.62x** | **1.62x** |
| Structure: app bar title / section rule / empty icon in `primary` on scaffold (needs 3:1) | 6.50 | 8.92 |
| Structure: attention section rule in `attention` on scaffold (needs 3:1) | 6.27 | 8.16 |

Verified against the rendered panel, not just computed: the light and dark values
above were sampled pixel-by-pixel off a Redmi (HyperOS, Android 16) on
2026-07-24 and matched spec exactly. Re-render before trusting a changed value —
that render is what caught the Pending chip reading brown in dark, and rendering
the panel *at size* is what caught light's warning panel being the weak mode.

**Confirmed on-device 2026-07-25, both modes, zero drift.** Every role below was
read off the Redmi's own framebuffer (HyperOS, Android 16) across both screens of
the presence preview. HyperOS applies no colour transform of its own — each value
appears as its exact spec hex.

| Role | light | dark |
|---|---|---|
| `background` | `#FAF5EE` | `#1F1916` |
| `surface` | `#FFFCF8` | `#2B2421` |
| `surfaceContainer` | `#F4EDE3` | `#2B2421` |
| `outlineVariant` | `#DED3C3` | `#4C4139` |
| `outline` | `#7A7266` | `#9C9083` |
| `onSurface` | `#1C1A16` | `#F0E8DC` |
| `onSurfaceVariant` | `#57534B` | `#C0B4A4` |
| `primary` — app bar, section rule, list icons, empty icon | `#356150` | `#8CC6AB` |
| `primaryContainer` | `#D5E6DB` | `#2A4E3F` |
| `attention` — attention section rule | `#8A4A25` | `#E3A47C` |
| `attentionContainer` — Pending badge | `#E6A574` | `#9C531C` |
| `attentionContainerStrong` — panel, count badge | `#DD8643` | `#9C531C` |
| `onAttentionContainer` | `#43220F` | `#FBEDE2` |

This supersedes the 2026-07-24 run, which validated the pre-§2.7 ramp.

† The panel fill is **not** load-bearing and is not held to the 3:1 non-text
floor: the panel's structure is its 3px left rule, which measures 5.13 (light) /
4.99 (dark) against that fill. The fill's job is presence, and 2.78 is the value
that makes it read the same in both modes. If the rule is ever dropped, the fill
becomes the only structure and the 3:1 floor applies.

Floors: **4.5:1** all text · **3:1** meaningful non-text · **48dp** touch targets.

**Changing any colour value requires re-running the contrast check against this
table.** A muted palette is exactly where this slips silently.

Known-failing combinations, documented so they are never used:

- `outline` as text on `surfaceContainerHigh` — 3.65 / 3.89. Banned by §2.6(1).
- `outlineVariant` as a meaningful border — 1.51 / 1.60. Banned by §2.6(2).
- Dimmed neutral badge text — 4.43 in dark. Rejected in §2.3.
- **`attention` on `attentionContainer` — 2.69 in dark.** Fails even the non-text
  floor. Use `onAttentionContainer` for anything drawn on that fill, including
  icons and rules (§6.3). Valid in light (5.47), but the rule is uniform across
  modes so one recipe serves both.
- Old dark `onAttentionContainer` `#F3D3BC` on the raised container — 4.05.
  Replaced by `#FBEDE2`.
- **`#D9792F` as the light `attentionContainerStrong`** — matches dark's 3.13:1
  vs *scaffold* but its text pairing lands at **4.56**, 0.06 off the floor.
  Rejected for `#DD8643` (2.78 vs card, text 5.13). See DECISIONS.md.

---

## 8. Both modes, always

Nothing ships light-only. Every new surface is checked in dark before review.
Dark is not an inversion of light — the values are independently chosen, and a
value that works in one mode proves nothing about the other.

---

## 9. Changing this document

1. A new token, role, or hue requires a `DECISIONS.md` entry **first**, with the
   reasoning and the contrast numbers.
2. Then this file changes.
3. Then the code conforms.

Never the reverse. The document is the source of truth; the code is its
implementation. This is the same lesson as the Firestore-rules incident — a rule
that lives only in someone's head, or only in a deployed artifact nobody checked,
is not a rule.

**Enforcement.** A lint bans raw `Colors.*`, `fontSize:`, and literal spacing
outside `lib/core/theme/`. It is switched on immediately after the first screen
migration validates the token scale — see the build log in `DECISIONS.md`.
