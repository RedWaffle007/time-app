# UI-RULES.md

**This document governs every pixel in this app. Read it before writing any screen code.**

`DECISIONS.md` records *why*. This file states *what you must do*. If a screen
disagrees with this file, the screen is wrong.

Approved 2026-07-24. Changing anything here requires a `DECISIONS.md` entry first
(see §8).

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
| `background` | `#FAF5EE` |
| `surface` (cards, sheets) | `#FFFCF8` |
| `surfaceContainer` | `#F4EDE3` |
| `surfaceContainerHigh` | `#EDE3D6` |
| `onSurface` | `#1C1A16` |
| `onSurfaceVariant` | `#57534B` |
| `outline` | `#7A7266` |
| `outlineVariant` | `#DED3C3` |
| `primary` | `#356150` |
| `onPrimary` | `#FFFFFF` |
| `primaryContainer` | `#D5E6DB` |
| `onPrimaryContainer` | `#14352A` |
| `attention` | `#8A4A25` |
| `onAttention` | `#FFFFFF` |
| `attentionContainer` | `#E6A574` |
| `attentionContainerStrong` | `#DD8643` |
| `onAttentionContainer` | `#43220F` |
| `error` | `#9C332C` |
| `onError` | `#FFFFFF` |
| `errorContainer` | `#F8DEDA` |
| `onErrorContainer` | `#4A100D` |

Dark — re-picked, not inverted. Chroma drops and lightness rises, because
saturated hues vibrate on dark surfaces.

| Role | Hex |
|---|---|
| `background` | `#1F1916` |
| `surface` (cards, sheets) | `#2B2421` |
| `surfaceContainer` | `#2B2421` |
| `surfaceContainerHigh` | `#392F2A` |
| `onSurface` | `#F0E8DC` |
| `onSurfaceVariant` | `#C0B4A4` |
| `outline` | `#9C9083` |
| `outlineVariant` | `#4C4139` |
| `primary` | `#8CC6AB` |
| `onPrimary` | `#0A2419` |
| `primaryContainer` | `#2A4E3F` |
| `onPrimaryContainer` | `#B9E3CF` |
| `attention` | `#E3A47C` |
| `onAttention` | `#3D1E0C` |
| `attentionContainer` | `#9C531C` |
| `attentionContainerStrong` | `#9C531C` *(same — see §2.4)* |
| `onAttentionContainer` | `#FBEDE2` |
| `error` | `#EBA49E` |
| `onError` | `#57120F` |
| `errorContainer` | `#5C2320` |
| `onErrorContainer` | `#F8D6D2` |

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

---

## 3. Type

System font. No custom family: `supportedLocales` covers ~80 locales, and the
system font is the only thing guaranteed to have the glyphs.

| Token | Size / line | Weight | Use |
|---|---|---|---|
| `displaySmall` | 32 / 40 | 700 | auth hero only |
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
