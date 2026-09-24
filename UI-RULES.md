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

The app has two colours of **equal presence** and **divided duty**: DealerPulse
brand green and a burnt-orange attention family, over green-tinted neutrals.

> **Green owns action and affirmation. Orange owns attention and pending state.**

| | DealerPulse green (`primary`) | Burnt orange (`attention`) |
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
| `background` | `#EAF8EF` |
| `surface` (cards, sheets) | `#F9FFFB` |
| `surfaceContainer` | `#D8F3DF` |
| `surfaceContainerHigh` | `#C8E9D0` |
| `onSurface` | `#141A15` |
| `onSurfaceVariant` | `#4B574D` |
| `outline` | `#6E7A70` |
| `outlineVariant` | `#D1DCD2` |
| `primary` | `#1B7A3D` |
| `onPrimary` | `#FFFFFF` |
| `primaryContainer` | `#9FE5B4` |
| `onPrimaryContainer` | `#04250F` |
| `attention` | `#B4400C` |
| `onAttention` | `#FFFFFF` |
| `attentionContainer` | `#FFD2B2` |
| `attentionContainerStrong` | `#FF9A58` |
| `onAttentionContainer` | `#441C06` |
| `error` | `#B3261E` |
| `onError` | `#FFFFFF` |
| `errorContainer` | `#FFD3D0` |
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
| `attentionContainerStrong` | `#A5551E` *(same — see §2.4)* |
| `onAttentionContainer` | `#FDE9D8` |
| `error` | `#F2B8B5` |
| `onError` | `#601410` |
| `errorContainer` | `#8C1D18` |
| `onErrorContainer` | `#F9DEDC` |

**Note on `surface`.** In light, cards are `#F9FFFB` on a `#EAF8EF` scaffold;
in dark, cards are `#18201A` on a `#0F1511` scaffold. Both are deliberate:
separation comes from the border and the quiet green tinted neutral ramp.

**Both neutral ramps are green-tinted — this is deliberate (§2.7).** They are
not grey: the scaffold carries a quiet trace of the brand hue and cards remain
opaque. Never remove that tint by replacing these roles with generic neutrals.

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

**`attentionContainerStrong` is the panel's fill — never a badge's.** In light,
the vivid `#FF9A58` panel sits above the softer `#FFD2B2` pending tint; dark
uses `#A5551E` for both because it already separates clearly from its surface.
Text, rule and icon on either fill use `onAttentionContainer`; there is no
separate `on*Strong`.

In **dark the two roles hold the same value** — that is the seam where the modes
legitimately differ (§8), not a redundant token.

### 2.5 Red is rationed

`error` appears only for:

- destructive confirmations (Withdraw, Leave group, Delete)
- authentication and system failures
- form validation errors

**Red never appears as a status badge.** Rationing is what keeps it forceful.

### 2.6 Hard colour constraints

1. **`outline` is never a text colour.** It measures 3.42 (light) / 4.59 (dark)
   against the darkest containers — fine for a border, a fail for text. Use
   `onSurfaceVariant` for muted text.
2. **`outlineVariant` is decorative only** (1.39 light / 1.66 dark). Hairline
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
| **Temperature** | the neutral ramp's own green tint (§2.2) | not an element at all |

> **The firewall: a filled shape is state. Line work and text are structure.**

This is what lets both colours be present everywhere without orange going
decorative where it must stay semantic. "An orange **filled pill or panel** means
something is waiting on you" stays true and learnable, because structural orange
is never a fill.

**Enforced.** `ui_rules_lint_test.dart` rejects any `attention*` role used as a
`Container`/`BoxDecoration` colour outside `status_style.dart` and
`warning_panel.dart`. If you need a new orange fill, it is a new *state* — add it
to `status_style.dart`, don't inline it.

**Which colour for structure.** The app bar and list icons remain green. Ordinary
section headers and stat-card rails use a stable label hash into the categorical
palette (green, turquoise, golden, violet, pink); their label text and rule share
that accent. Orange **only** where
the structure labels genuinely attention-bearing content — a "Waiting on you"
section rule, a pending count badge. Structure never invents a new meaning for
orange; it only ever points at attention that is really there.

The neutral ramp is the always-present green-tinted ground (§2.2). Nothing in
the ramp becomes orange, so orange remains reserved for attention state.

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
| `seriesPrimary` | `primary` (brand green) | The main series; every progress fill; "completed / good". |
| `seriesAttention` | `tertiary` (burnt orange) | The pending / attention series — **line or marker only**. |
| `seriesMuted` | `primaryContainer` | A comparison series, when one is not enough. Not a third hue. |
| `chartGrid` | `outlineVariant` | Gridlines, ticks — decorative structure. |
| `chartAxisLabel` | `onSurfaceVariant` | Axis labels, legends. |
| `progressTrack` | `surfaceContainerHigh` | The unfilled part of a meter/ring. |

**The §2.7 firewall extends onto charts.** A filled area is state; a filled
*orange* area is the "waiting on you" signal. So the attention series is drawn as
a **line, dot or label**, never a filled region — a filled region uses
`seriesPrimary` (brand green), which §2.7 does not restrict. There is deliberately no
orange-fill getter in `dataviz_tokens.dart`: adding one would both spend the
signal on decoration and launder the banned `tertiaryContainer` past the §2.7
lint. If a chart needs a filled "pending" area, that is a new state — it belongs
in `status_style.dart` (§2.3), not inlined into a chart.

More than two series: add neutral *shape* (dashed vs solid, marker glyph), never a
new hue. The palette stays two.

`AppDataVizColors.categorical` is the five-colour categorical list for
multi-series charts and marks. It is ordered brand green → turquoise → golden →
violet → pink. The first entry is `primary`; the remaining entries use these
light/dark twins:

| Series | Light | Dark |
|---|---|---|
| brand green | `#1B7A3D` | `#56CE7E` |
| turquoise | `#0E7C86` | `#5AD0D8` |
| golden | `#8A6200` | `#E8C15A` |
| violet | `#6D48C4` | `#B9A0F0` |
| pink | `#C03271` | `#F08AB4` |

These colours are for chart meaning and for stable structural accents: section
header rules and labels, stat-card rails, and selected prominent metric text.
They are never used as general chrome or state fills. `categoricalAccentFor()`
hashes a label so an element keeps its accent when neighbouring content changes.

## Ambient backdrop

`TimeBackdrop` is the app-wide, low-opacity tiled pattern beneath every route.
It uses hand-drawn time and study marks: clocks, alarm clocks, books, pencils,
hourglasses, calendars and paperclips. It is CHECKMATE's replacement for
DealerPulse's `AutomotiveBackdrop`.

The scaffold is transparent so the pattern shows through gutters. Cards, app
bars, sheets and dialogs keep opaque fills, so the backdrop never lowers the
contrast of content. The backdrop is decorative and input-transparent.

---

## 3. Type

Two bundled variable fonts define the type system. Space Grotesk is used for
headings, titles, big numbers, code-like strings, and avatar initials. Manrope
is used for body and UI text. Non-Latin glyphs not covered by either face fall
back to the system font, preserving the app's locale coverage.

| Token | Size / line | Weight | Family | Use |
|---|---|---|---|
| `displaySmall` | 32 / 40 | 700 | Space Grotesk | heroes and big numbers |
| `titleLarge` | 20 / 28 | 600 | Space Grotesk | screen section headers |
| `titleMedium` | 17 / 24 | 600 | Space Grotesk | card titles |
| `bodyLarge` | 16 / 24 | 400 | Manrope | default body |
| `bodyMedium` | 14 / 20 | 400 | Manrope | dense body |
| `labelLarge` | 14 / 20 | 600 | Manrope | buttons |
| `bodySmall` | 13 / 18 | 400 | Manrope | hints, secondary prose |
| `labelSmall` | 12 / 16 | 500 | Manrope | timestamps, timezone labels, metadata |
| `codeDisplay` | 22 / 28 | 700, ls 3 | Space Grotesk | invite codes and any code-like string |

`codeDisplay` lives on the `AppTypeExtension`, reached via `context.codeDisplay`.

**Rules:**

- Never write `fontSize`. Never write `fontWeight` on a themed style — the token
  carries it.
- **`displaySmall` is for heroes and sanctioned big-number leads.** Its remit is
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
`attention` on `attentionContainer` measures only 3.53:1 light / 2.63:1 dark;
since that
container was raised — below even the 3:1 non-text floor. `onAttentionContainer`
clears it on both fills and in both modes (9.19 light / 4.48 dark on the badge
fill; 5.62 light / 4.48 dark on the strong fill).

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

The icon uses `primary`, which measures 4.98 (light) / 9.27 (dark) on the
scaffold against a 3:1
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
  pillar = filled brand-green icon + label (§6.6 filled-selected), inactive = outline
  icon in `onSurfaceVariant`. The pending-attention **count** rides the **Plan**
  icon (aggregate) and the **My Schedule** sub-tab — the one orange the bar may
  carry (§2.7), rendering nothing at zero.
- **Two FABs, and only these two, each with a distinct job** (revised 2026-08-27,
  DECISIONS.md "Per-page create FABs"). The old "one FAB, always" rule is retired:
  a single centre-docked mic left *manual* create hidden behind knowing to open an
  app-bar overflow, which confused users who stayed on My Schedule.
  1. The docked centre **voice FAB** — a standard (56) circular `primary` (brand green)
     FAB, mic glyph, *gentle* floating shadow (`Elevations.floating`). Speak-to-
     create. Owned by `HomeShell` (the outer scaffold), present on every pillar.
  2. A **manual-create FAB**, bottom-right (`endFloat`), owned by the creating
     pillar's own (inner) scaffold so it clears the bottom bar. **Plan** uses a
     rounded, bold **`PLAN`** text FAB on all three sub-tabs; **Track** retains its
     circular **`AppIcons.add` (`＋`)** "Log item" FAB. Each carries its own
     `heroTag` so it never collides with the voice FAB in a route transition.
  The controls never merge or appear a third time: mic = voice, `PLAN` / `＋` =
  the pillar-specific manual action.
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
- **Quick-add chips are brand green, not orange.** Optional `15 / 30 / 45 / 60` chips
  are `ChoiceChip`s on a `primaryContainer` tint with `Radii.pill` — a convenience
  fill, and a brand-green one, so it stays clear of the §2.7 firewall. They *set* the
  minutes field; they never submit on their own.
- **Actions:** `Not now` (text) / `Log` (filled brand green, §6.4). The Done→track prompt
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
  through *size and spacing*, never through a new hue.
- **Charts** pull every colour from §2.8 (`AppDataVizColors`) and every meter from
  §6.7. Personal-dashboard numbers are distinct from the social-profile stats on
  `/u/:uid`: same tile recipe, different surface and framing ("my dashboard", not
  "someone's profile").

### 6.15 Splash

The cold-start reveal uses the CHECKMATE wordmark `CHECKMATE` in Space Grotesk,
with the tagline **“Mates Always Remember”**. It is a theme-independent pure
black reveal with white wordmark and glow. The two fixed brand bars are green
`#2FA35A` over burnt orange `#EA6A2E`, from `SplashTokens`.
The complete reveal remains exactly 1.5 seconds. Its clock ting begins at mount
and fades perceptually over the final 750ms of that same deadline; audio must
never lengthen the reveal or end in an abrupt hard cut.

### 6.15a Completion celebration

Done produces one silent, full-viewport colored-paper celebration per task. It
is a 1.4-second ballistic burst: paper rapidly explodes from a compact central
source, disperses toward every screen region, then falls under gravity and fades.
It is never a continuous top-down rain and never plays background audio.
Repeated live snapshots must not restart the same event, a slow acknowledgement
must not block the next event, and pausing or locking the app pauses the current
visual rather than replaying it from zero.

### 6.16 Missed-alarm review

After the native one-minute ring cap expires, the next unlocked foreground
session places one blocking review card over the current route. It uses the
ordinary surface Card on the standard scrim, not an error-red takeover: a missed
alarm is a neutral Skipped outcome, not app failure. The underlying route is
`IgnorePointer` + `ExcludeSemantics` while visible. Show one missed task at a
time, with exactly two actions: neutral **Mark as Skipped** and primary
**Mark as Done**. There is no generic acknowledgement or bulk outcome action.
Additional misses advance through the same card. The card appears as soon as the
automatic outcome is durably recorded—planner push delivery is not on its
critical path—and never above the app lock or cold-start reveal. A later Done is
shown as **Done (Late)** while the separate **User unavailable at alarm time**
timeline fact remains visible.

### 6.17 Android alarm wake surface

An Android alarm launch requests screen-on and show-over-lock-screen before the
Flutter route mounts, then keeps the screen on only while ringing. This covers
the keyguard but never dismisses it or bypasses authentication. The native
ringing notification is public on the lock screen and always includes a direct
**Dismiss** action, providing a usable fallback when Android or an OEM refuses
full-screen presentation. Ordinary app and push-notification launches must not
inherit any alarm window flags.

---

## 7. Accessibility floor

**Every text pairing hits WCAG AA (4.5:1) in both modes. Ratios below were
computed from the role hex values with a WCAG relative-luminance script, not
estimated by eye.**

Measured minimums:

| Pairing | Light | Dark |
|---|---|---|
|---|---:|---:|
| `onSurface` on `surface` | 17.44:1 | 14.08:1 |
| `onSurface` on `background` | 16.13:1 | 15.63:1 |
| `onSurfaceVariant` on `surface` | 7.48:1 | 8.38:1 |
| `onSurfaceVariant` on `background` | 6.92:1 | 9.30:1 |
| `primary` on `background` | 4.92:1 | 9.27:1 |
| `attention` on `background` | 5.21:1 | 9.08:1 |
| `error` on `background` | 5.97:1 | 10.83:1 |
| `onPrimary` on `primary` | 5.39:1 | 6.57:1 |
| `onAttention` on `attention` | 5.71:1 | 7.01:1 |
| `onError` on `error` | 6.54:1 | 7.66:1 |
| `onPrimaryContainer` on `primaryContainer` | 11.23:1 | 7.15:1 |
| `onAttentionContainer` on `attentionContainer` | 10.68:1 | 4.55:1 |
| `onAttentionContainer` on `attentionContainerStrong` | 7.08:1 | 4.55:1 |
| `onErrorContainer` on `errorContainer` | 11.98:1 | 7.17:1 |
| `primary` on `primaryContainer` | 3.68:1 (non-text only) | 4.56:1 |
| `attention` on `attentionContainer` | 3.53:1 | 2.63:1 (do not use) |
| `outline` on `surfaceContainerHigh` | 3.60:1 | 4.59:1 (border only) |
| `outlineVariant` on `surface` | 1.41:1 | 1.66:1 (decorative only) |
| `attentionContainer` on `surface` | 1.37:1 | 3.11:1 (fill contrast only) |
| `primaryContainer` on `surface` | 1.45:1 | 1.83:1 (fill contrast only) |
| categorical accents on `background` (turquoise / golden / violet / pink) | 4.52 / 5.01 / 5.68 / 4.87:1 | 10.08 / 10.75 / 8.23 / 7.92:1 |

The role values used for the computation are:

| Role | light | dark |
|---|---|---|
| `background` | `#EAF8EF` | `#0F1511` |
| `surface` | `#F9FFFB` | `#18201A` |
| `surfaceContainer` | `#D8F3DF` | `#18201A` |
| `surfaceContainerHigh` | `#C8E9D0` | `#232D25` |
| `outlineVariant` | `#D1DCD2` | `#39453B` |
| `outline` | `#6E7A70` | `#8A958C` |
| `onSurface` | `#141A15` | `#E6EEE7` |
| `onSurfaceVariant` | `#4B574D` | `#AFBBB1` |
| `primary` | `#1B7A3D` | `#56CE7E` |
| `onPrimary` | `#FFFFFF` | `#00391B` |
| `primaryContainer` | `#9FE5B4` | `#1E5233` |
| `onPrimaryContainer` | `#04250F` | `#B6F2C6` |
| `attention` | `#B4400C` | `#F0A56E` |
| `onAttention` | `#FFFFFF` | `#491E05` |
| `attentionContainer` | `#FFD2B2` | `#A5551E` |
| `attentionContainerStrong` | `#FF9A58` | `#A5551E` |
| `onAttentionContainer` | `#441C06` | `#FDE9D8` |
| `error` | `#B3261E` | `#F2B8B5` |
| `onError` | `#FFFFFF` | `#601410` |
| `errorContainer` | `#FFD3D0` | `#8C1D18` |
| `onErrorContainer` | `#410E0B` | `#F9DEDC` |

The panel fill is not load-bearing and is not held to the 3:1 non-text floor:
the panel's structure is its 3px left rule. If the rule is ever dropped, the
fill becomes the only structure and the 3:1 floor applies.

Floors: **4.5:1** all text · **3:1** meaningful non-text · **48dp** touch targets.

**Changing any colour value requires re-running the contrast check against this
table.** A green-tinted neutral palette still needs measured verification.

Known-failing combinations, documented so they are never used:

- `outline` as text on `surfaceContainerHigh` — 3.42 / 4.59. Banned by §2.6(1)
  even where it happens to clear AA in dark mode.
- `outlineVariant` as a meaningful border — 1.39 / 1.66. Banned by §2.6(2).
- Dimmed neutral badge text — 4.43 in dark. Rejected in §2.3.
- **`attention` on `attentionContainer` — 4.11 light / 2.63 dark.** Fails the
  non-text floor in dark. Use `onAttentionContainer` for anything drawn on that
  fill, including icons and rules (§6.3).

---

## 8. Both modes, always

Nothing ships light-only. Every new surface is checked in dark before review.
Dark is not an inversion of light — the values are independently chosen, and a
value that works in one mode proves nothing about the other.

### Theme mode

The You hub exposes **Light**, **Dark**, and **System default**. The preference
is stored on this device through `ThemeModeStore`; `ThemeMode.system` is the
default and follows the OS. `MaterialApp.router` reads the Riverpod
`themeModeProvider`, so a selection applies immediately and persists across
launches.

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
