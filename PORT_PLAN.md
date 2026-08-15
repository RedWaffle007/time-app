# PORT_PLAN.md

An assessment of porting `time-app` from Flutter to React Native + Expo +
TypeScript. Written 2026-08-12 against branch `feat/notification-events`
(`37c9856`), by reading `ARCHITECTURE.md` and the code.

**Scope note up front:** the Cloudflare Worker, `firestore.rules`, the
`joinCodes` lookup collection and the Firestore data model are backend. They
carry over unchanged and are excluded from every milestone and estimate below
(see §6). Where this document describes `joinByCode` / `createGroup`, it
describes the **current** `joinCodes`-based behaviour from ARCHITECTURE.md §6.1,
not the pre-2026-08-10 query-by-`joinCode` version.

**Reading order if you only read part of this:** §5 first (the recommendation),
then §6 (what a rewrite does not fix), then §7 (tests). §1–§4 are the mechanics,
and they assume you have already decided to go.

---

## 0. The one-paragraph version

This is an unusually portable app. It has ~4,500 lines of Dart, no code
generation, one production file over 300 lines, **zero** uses of `CustomPaint`,
`AnimationController`, `Transform`, `Hero` or `Tween` (verified by grep across
`lib/`), and exactly one platform channel — which is already broken. Almost
nothing in it depends on Flutter being Flutter. A port is genuinely feasible and
would take roughly **4–8 weeks of solo work to arrive back where you already
are**, with zero new features, and with the alarm layer — the thing the product
is named after — made *harder* rather than easier. My recommendation is in §5
and it is: don't, not yet, and here is the one-day experiment that tests your
actual hypothesis first.

---

# 1. DEPENDENCY MAPPING

Legend: **DIRECT** = a drop-in with the same shape · **DIFFERENT** = the
capability exists but the design changes · **NONE** = no equivalent; you build
or drop it.

## 1.1 The three that matter most

| Package | RN/Expo answer | Verdict |
|---|---|---|
| `flutter_riverpod ^3.3.2` | **TanStack Query** (server state) + **Zustand** (client state) + plain module imports (DI) | **DIFFERENT** |
| `go_router ^17.3.0` | **Expo Router** (file-based) | **DIFFERENT** |
| `cloud_firestore ^6.7.1` | **`@react-native-firebase/firestore`** | **DIRECT** (config plugin required) |

**Riverpod.** There is no Riverpod in React, and looking for one is the wrong
move. Riverpod is doing three separate jobs in this codebase and React splits
them across three tools:

1. *Dependency injection* — `scheduleRepositoryProvider`, `groupRepositoryProvider`
   etc. are just "construct this once." In TS that is a module-level `const`, or
   one small Context if you want to swap it in tests. Nine lines of Riverpod
   become one line of TS.
2. *Reactive server state* — `allItemsAsTargetProvider` wraps a Firestore
   snapshot stream in an `AsyncValue`. TanStack Query is the purpose-built
   answer: it owns loading/error/data, retry, invalidation, and a query key
   namespace, which is what `ref.invalidate(allItemsAsTargetProvider)` is doing
   today in every `AsyncView.onRetry`.
3. *Derived computation* — `myItemsAsTarget = allItems − archived`. That is a
   `useMemo` over two query results, or a `select` on one.

The record/view split (`schedule_providers.dart:13-35`) survives this cleanly,
and the loud comment protecting it should be carried across verbatim. It becomes
two query keys plus a derived hook, and the constraint ("stats must read the
record layer") is expressible the same way.

The one thing you lose is Riverpod's compile-time-ish provider graph — you gain
back explicitness, which for someone learning architecture fundamentals is the
better trade. Riverpod hides the DI/state/derivation distinction behind one word,
`Provider`; the React split forces you to name which of the three you're doing.

**go_router.** Expo Router covers everything the app uses (ten flat routes, one
path parameter, an auth redirect, no deep links) and covers it better, because
the file tree makes the tab-vs-route duplication that causes §4.6 structurally
impossible. `GoRouterRefreshStream` (and its undisposed-by-construction leak,
§4.4) has no counterpart — auth-driven redirects are a `<Redirect>` in a layout.
Not a drop-in: your route list becomes a directory.

**Firestore SDK.** `@react-native-firebase/firestore` maps to the Dart API
almost symbol for symbol: `collection`, `doc`, `where`, `orderBy`, `limit`,
`onSnapshot`, `setDoc(…, {merge: true})`, `serverTimestamp()`, `arrayUnion()`,
`collectionGroup()`. `FieldValue.delete()` becomes `deleteField()` (used in
`ArchiveRepository.unarchive`). The five repository files are the *easiest* part
of the port.

> **Do not use the Firebase JS SDK here.** It works in Expo Go, which is
> tempting, but its Firestore offline persistence needs IndexedDB and therefore
> does not exist in React Native — you get memory-only cache. ARCHITECTURE.md
> §2.4 names Firestore's on-device cache as doing "a lot of invisible work here
> (it is why the app is usable offline at all)." Choosing the JS SDK silently
> deletes that. Use `@react-native-firebase`, accept the config plugins, and
> accept that **Expo Go is off the table from day one** — you will be on
> development builds for the entire project.

## 1.2 Full dependency table

| Package | Version | RN / Expo equivalent | Verdict | Plugin / native? |
|---|---|---|---|---|
| `flutter_riverpod` | ^3.3.2 | TanStack Query + Zustand (§1.1) | **DIFFERENT** | no |
| `go_router` | ^17.3.0 | `expo-router` | **DIFFERENT** | no |
| `firebase_core` | ^4.12.1 | `@react-native-firebase/app` | **DIRECT** | **config plugin** |
| `firebase_auth` | ^6.5.6 | `@react-native-firebase/auth` | **DIRECT** | **config plugin** |
| `cloud_firestore` | ^6.7.1 | `@react-native-firebase/firestore` | **DIRECT** | **config plugin** |
| `firebase_messaging` | ^16.0.4 | `@react-native-firebase/messaging` (+ `expo-notifications` for the Android channel and the POST_NOTIFICATIONS prompt) | **DIRECT** | **config plugin** |
| `firebase_crashlytics` | ^5.2.6 | `@react-native-firebase/crashlytics` | **DIRECT** | **config plugin** |
| `google_sign_in` | ^7.2.0 | `@react-native-google-signin/google-signin` | **DIRECT** | **config plugin** |
| `timezone` | ^0.11.1 | `@js-temporal/polyfill` (recommended) or `luxon` | **DIFFERENT** — see §2.4 | no (bundle cost) |
| `flutter_timezone` | ^5.1.0 | `Intl.DateTimeFormat().resolvedOptions().timeZone`, or `expo-localization` `getCalendars()[0].timeZone` | **DIRECT** | no |
| `intl` | any | `Intl.DateTimeFormat` + `expo-localization` | **DIFFERENT** — see §2.5 | no |
| `flutter_localizations` | SDK | **nothing.** RN has no framework-chrome localization because it has no framework chrome | **NONE** | — |
| `http` | ^1.2.2 | `fetch` (built in) | **DIRECT** | no |
| `share_plus` | ^13.2.1 | RN core `Share` API (used at `group_detail_screen.dart:136`) | **DIRECT** | no |
| — (clipboard, `group_detail_screen.dart:128`) | — | `expo-clipboard` | **DIRECT** | no |
| `local_auth` | ^2.3.0 | `expo-local-authentication` | **DIRECT** with a semantic caveat — see §2.2 | **config plugin** |
| `shared_preferences` | ^2.3.2 | `react-native-mmkv` (synchronous) **or** AsyncStorage + held splash | **DIFFERENT** — see §2.2 | plugin if MMKV |
| `cupertino_icons` | ^1.0.8 | — | **DROP.** Unused per ARCHITECTURE.md §1.2; do not carry it over | — |
| `uses-material-design: true` (icon font) | — | `@expo/vector-icons` (`MaterialIcons`) | **DIRECT** — `app_icons.dart`'s vocabulary maps cleanly | no |
| **Material 3 `ThemeData` / `ColorScheme`** | Flutter SDK | `react-native-paper` (MD3) or hand-built tokens | **NONE** — see §2.3. This is the largest hidden dependency in the app | no |
| `showDatePicker` / `showTimePicker` | Flutter SDK | `@react-native-community/datetimepicker` | **DIFFERENT** — see §2.5 | native (Expo-supported) |
| `flutter_lints ^6.0.0` | dev | `eslint` + `typescript-eslint` + `eslint-config-expo` | **DIRECT** | no |
| `flutter_test` | dev | `jest-expo` + `@testing-library/react-native` (+ Maestro for E2E) | **DIRECT** | no |
| `MethodChannel('time_app/secure_window')` | hand-rolled | `expo-screen-capture` | **DIRECT on Android**, **NONE on iOS** — see §2.6 | **config plugin** |

## 1.3 Config plugins and what they cost you

Eight of the dependencies above need an Expo config plugin, which means:

- **No Expo Go, ever.** You build a development client with `eas build --profile
  development` (or `npx expo prebuild` + local build) and install that.
- **Every native dependency change requires a new dev-client build** (~10–25 min
  on EAS free tier, longer in queue). This is the RN equivalent of a
  `flutter clean` + full rebuild, and it happens more often than you'd like.
- **iOS dev-client installs on a physical device require an Apple Developer
  Program membership** ($99/yr). There is no way around this, and it is
  identical to Flutter. See §5 — this matters to your stated motivation.

No dependency in this app requires you to **write** a custom native module.
That is a genuinely good result and it is mostly luck of what the app does:
the one place it would have been needed (`FLAG_SECURE`) is covered by
`expo-screen-capture`, and the one place it *isn't* covered (iOS recents
blanking) is a feature the app claims but does not currently deliver anyway.

---

# 2. WHAT PORTS EASILY vs WHAT DOESN'T

## 2.1 Logic that transfers close to 1:1

Dart → TypeScript is a small step for this codebase specifically, because the
Dart here is plain: immutable classes, pure functions, `switch`, pattern
matching, and `Stream<T>`. There are no mixins, no extension-heavy metaprogramming,
no `dart:ffi`, no isolates.

| Module | Lines | Notes |
|---|---|---|
| `core/timezone/quiet_hours.dart` | 59 | Pure integer arithmetic. `minuteInWindow` (the wrap-past-midnight case) transliterates exactly. **Trivial port, and it is currently untested — write the tests during the port, not after.** |
| `features/applock/application/app_lock_controller.dart` | 209 | Pure Dart, injected clock, three collaborators behind interfaces. Near-perfect port — with two RN-specific hazards, §2.2. |
| `features/scheduling/domain/schedule_item.dart` | 143 | Class → `type` + zod schema. The three archive getters (`isAutoArchived`, `isManuallyArchivable`, `isSettled`) are pure and transliterate directly. |
| `scheduling/application/schedule_providers.dart` `_visible()` | ~5 | One `.filter()`. The *comment* above it is worth more than the code — carry it. |
| The five `*_repository.dart` files | ~450 total | Firestore call-for-call, §1.1. |
| `notifications/data/http_event_notifier.dart` | 64 | `http.post` → `fetch`. Same timeout, same swallow-and-record semantics. |
| `core/theme/status_style.dart` — the *mapping* | 194 | The status→label/treatment/icon table is data. The colour *values* need a new home (§2.3). |
| `routing/app_router.dart` `Routes` | ~14 | Becomes typed route literals; Expo Router can generate these. |
| `domain/` models (`UserProfile`, `Group`, `Membership`, `PlannerGrant`) | ~140 | Same as `ScheduleItem`. |

Rough total that ports mechanically: **~1,300 lines of the 4,512.**

## 2.2 The app-lock state machine — near-perfect port, two real hazards

`AppLockController` is the best-designed file in the repo for porting: no
`BuildContext`, no `WidgetsBinding`, clock injected, every collaborator an
interface. It becomes a Zustand store (or a plain TS class exposed via
`useSyncExternalStore`) with identical method names — `didBackground`,
`didForeground`, `didDetach`, `unlock`, `setEnabled` — and the same private
fields. The 30s grace constant, the fail-secure boot default, and the
"`_leftAt` lives in RAM on purpose" property all survive unchanged.

Two things do **not** transliterate and need a decision, not a translation:

**(a) There is no `detached` in React Native.** Flutter's
`AppLifecycleState.detached` drives `didDetach()`, the explicit task-kill signal.
RN's `AppState` has only `active`, `background`, and `inactive` (iOS). There is
no teardown event.

This is less bad than it sounds, and the code already tells you why: the
constructor comment at `app_lock_controller.dart:37-43` says the *real*
task-kill answer is that a fresh process constructs a fresh controller with
`_locked = initiallyEnabled`. That property holds identically in RN — a killed
app gets a fresh JS context and a fresh store. `didDetach` is described in its
own doc comment as "belt-and-braces." So you lose the belt and keep the braces.
**Say so in a comment in the new code**, and delete the corresponding tests
rather than faking a `detached` event that will never fire.

**(b) iOS `inactive` is a genuine fork in the road.** The current gate
deliberately ignores `inactive` (`app_lock_gate.dart`, the switch's last arm)
because on Android it fires for the notification shade and permission sheets.
On iOS, `inactive` is *also* when the app-switcher snapshot is taken. So:

- Ignore `inactive` on iOS → the recents thumbnail shows the user's schedule.
- Act on `inactive` on iOS → you must not *lock* (that would lock people out for
  a permission sheet) but you *can* raise a cover view for the snapshot.

The right answer is to split the two concerns the current code conflates: a
`coverForSnapshot` boolean driven by `inactive`, separate from `locked` driven by
`background` + grace. That is a design improvement, not a port cost — but it is
new logic that has never existed and it needs its own tests.

**(c) The synchronous boot read.** `main.dart:49` `await`s the app-lock flag
*before* `runApp`, because the first frame must know. `AsyncStorage` is async and
React renders immediately. Two options:

- `react-native-mmkv` — synchronous reads, so `main.dart`'s exact shape survives.
  Costs a config plugin and a native dep.
- `expo-splash-screen` `preventAutoHideAsync()` — hold the splash until the flag
  resolves, then reveal. No new native dep; slightly slower cold start.

Either works. Keep `main.dart:62-84`'s **fail-secure** reasoning verbatim (a
failed read guesses ON, because the wrong guess in that direction is recoverable
and the other is not). That paragraph is the most valuable thing in `main.dart`.

## 2.3 The theme system — the largest thing that does not port

`lib/core/theme/` is 1,045 lines across six files, plus 384 lines of tests
(`theme_tokens_test.dart`, `ui_rules_lint_test.dart`), plus a 584-line
`UI-RULES.md` that is doctrine for the whole app. It is the most carefully built
asset in the repo and it is the most Flutter-coupled.

What it leans on that RN does not have:

- **`ThemeData` + component themes.** `CardTheme`, `InputDecorationTheme`,
  `NavigationBarTheme`, `AppBarTheme` mean a bare `Card()` already has the right
  margin, radius, border and elevation. RN has no cascading component theme;
  every one of those recipes becomes an explicit component you write and everyone
  must remember to use.
- **`ColorScheme` roles.** The code uses `surfaceContainer`, `onSurfaceVariant`,
  `primaryContainer`, `outlineVariant`, `outline`, `error`/`onError`, plus the
  custom `attention`/`attentionContainer` extension. Material 3's tonal-palette
  derivation is a Flutter/M3 feature. `react-native-paper` implements MD3 and
  gives you the same role names — that is the pragmatic path — but you inherit
  paper's component opinions along with it.
- **`Theme.of(context)` inheritance.** Every screen does
  `context.colors` / `context.text`. In RN that becomes a `useTheme()` hook off a
  Context. Mechanical, but it touches every file.
- **`ThemeMode.system` + a designed-not-derived dark palette.** `useColorScheme()`
  gives you the signal; the palette itself is data and ports fine.

What *does* port well: the **token values themselves** (`Space`, `Radii`,
`Elevations`, `Sizes`, the colour hexes) are plain constants. And the
`ui_rules_lint_test.dart` technique — scan source files, regex for banned
patterns, fail the test — ports perfectly to Jest over `.tsx`, and should
(better, become an ESLint `no-restricted-syntax` rule so it fires in the editor).

**Budget honestly: this is 2–4 days and it is the least enjoyable part of the
port, and it lands early (M1) when your motivation is highest. Plan for that.**

## 2.4 The DST resolver — ports, but you should not transliterate it

`core/timezone/tz_resolver.dart` (93 lines) is described in ARCHITECTURE.md §3.2
as "the sharpest piece of logic in the codebase," and it is. It labels wall-clock
fields as UTC, shifts by the two offsets bracketing the moment (±24h), and calls
a candidate real only if the zone's actual offset there matches the offset used
to compute it. Zero real candidates → spring-forward gap (push forward); two
distinct → fall-back overlap (take the first).

You *could* transliterate this into TS against `luxon`'s offset API. **Don't.**
The modern answer is `Temporal`, and it expresses this exact rule as a parameter:

- `Temporal.PlainDateTime.prototype.toZonedDateTime(tz, { disambiguation })`
- `disambiguation: 'compatible'` → gap: shift **later**; overlap: take the
  **earlier** occurrence. That is precisely the app's documented rule, and it is
  also java.time's rule, which is what `tz_resolver.dart`'s comment cites.
- Anomaly *detection* (which the UI needs, for `_dstBanner`) comes from comparing
  `'earlier'` and `'later'` results: equal → `none`; different and both valid →
  `ambiguous`; `'reject'` throws → `skipped`.

That is ~15 lines instead of 40, with the edge-case reasoning handled by a spec
rather than by your arithmetic.

Costs and cautions, stated plainly:

- `Temporal` is not in Hermes yet, so you ship `@js-temporal/polyfill`. It is not
  small (embedded tzdata). Measure it; if it's unacceptable, `luxon` +
  `@formatjs/intl-datetimeformat` with timezone data is the fallback and is a
  closer transliteration.
- **Changing the engine means the existing 5 DST tests are not optional — they
  are the acceptance criteria.** More: before you delete the Dart, generate a
  table of ~50 `(zone, wall-time) → instant` pairs from the *current* resolver
  (including the southern-hemisphere case the test already covers) and make the
  TS resolver reproduce it exactly. That golden table is the single highest-value
  artifact you can carry across, and it costs an afternoon.
- CLAUDE.md's open item 3 — the real two-timezone DST-observing loop test — was
  already unverified. Swapping engines means it now needs to happen against code
  that has never run on a real pair. That is a small *loss* of confidence, not a
  gain.

## 2.5 Locale-aware formatting and pickers — the quiet regression risk

The standing worldwide requirement (CLAUDE.md) is currently satisfied by two
things that come free in Flutter and do not come free in RN:

**(a) `intl` + `initializeDateFormatting()`.** `core/format/datetime_format.dart`
is 46 lines and gets month names, field order, and digit shaping right in ~80
locales. In RN you use `Intl.DateTimeFormat`, which Hermes backs with platform
ICU on Android and NSFormatter-ish behaviour on iOS. It mostly works. The parts
to verify early, not assume:

- `timeZone: 'Asia/Karachi'` support in `Intl.DateTimeFormat` on both platforms
  (needed by `formatInstant`).
- Whether Android's Hermes build in your Expo SDK ships full ICU or a trimmed
  set. If trimmed, non-Latin locales degrade silently — exactly the failure mode
  the worldwide requirement exists to prevent.
- 12h/24h detection: `MediaQuery.alwaysUse24HourFormat` has no direct analogue.
  `expo-localization`'s `getCalendars()[0].uses24hourClock` is the closest, and it
  is nullable on some platforms. Decide the fallback deliberately.

**(b) `showDatePicker` / `showTimePicker`.** These are Material dialogs,
localized for free by `flutter_localizations`, identical on both platforms, and
they are used in three places (`schedule_builder_screen.dart:47,58`,
`profile_edit_screen.dart` quiet hours). RN has **no equivalent**.
`@react-native-community/datetimepicker` gives you the *platform's* picker: a
spinner/inline on iOS, a Material dialog on Android, different APIs, different
imperative-vs-declarative usage per platform, and no shared visual language. The
app's UI-RULES doctrine has nothing to say about this because Flutter never made
it a question.

This is a real, unglamorous regression in a requirement CLAUDE.md marks "do not
regress." It is solvable — most RN apps solve it — but budget it as design work,
not a library swap.

## 2.6 The `FLAG_SECURE` MethodChannel — the port's clearest technical win

`secure_window.dart:22` declares `MethodChannel('time_app/secure_window')` and
`MainActivity.kt` is the bare 5-line default. Grepping the tree finds the channel
name only in Dart. Every call throws `MissingPluginException`, caught and logged
as `'secure_window: no platform handler (expected off Android)'` — a message that
reads as benign on the one platform where it is a defect. Meanwhile `AppLockTile`
promises the user it "hides the app from the recents switcher and blocks
screenshots." ARCHITECTURE.md §4.5 calls this the most consequential
half-finished thing in the repo, and it is right: it is a privacy claim the app
does not honour.

In the port this disappears: **`expo-screen-capture`** provides
`preventScreenCaptureAsync()` / `allowScreenCaptureAsync()`, which sets
`FLAG_SECURE` on Android. `PlatformSecureWindow` becomes a four-line adapter
against the same `SecureWindow` interface, and the interface/fake structure the
tests already use survives unchanged.

**But be precise about what this does and does not fix:**

- **Android screenshots + recents blanking: fixed.** Real implementation, no
  Kotlin to write.
- **iOS screenshot blocking: still impossible.** iOS provides no API to block
  screenshots — only to *detect* them after the fact. No framework changes this.
- **iOS recents blanking: still not delivered.** The app-switcher snapshot needs
  a cover view raised on `applicationWillResignActive`. `expo-screen-capture`
  does not do it. In RN you'd do it via the `inactive` AppState fork in §2.2(b) —
  which is achievable, but it is *new work*, not a port.

So the honest summary: **the port fixes the Android half for free and makes the
iOS limitation explicit instead of fake — but the UI copy still has to change**,
because on iOS the promise will still be partly untrue. And note the deflating
part: writing the missing Kotlin handler in the existing Flutter app is roughly
**30 lines and an hour**. You do not need a rewrite to fix this.

## 2.7 Widget trees that map cleanly

Most of them, because the UI is deliberately plain.

| Flutter | RN | Difficulty |
|---|---|---|
| `Scaffold` + `AppBar` | `<Stack.Screen options={{title}} />` + `SafeAreaView` | easy |
| `ListView(children: [...])` | `FlatList` with `data`/`renderItem` | easy — and an improvement, since the current code materializes every child |
| `Card` + `Padding` + `Column` | `<View style={card}>` | easy (component to build once) |
| `ListTile` | `<Pressable>` with leading/title/subtitle/trailing slots | easy (component to build once) |
| `NavigationBar` + `IndexedStack` | Expo Router `(tabs)` layout | easy — tab screens stay mounted after first focus, matching the `IndexedStack` intent |
| `Badge` | small absolute-positioned `<View>` | easy |
| `SwitchListTile` | `<View>` + RN `Switch` | easy |
| `Divider`, `SectionHeader`, `WarningPanel` | `<View>` with borders | easy |
| `TextField` + `InputDecoration` | `<TextInput>` + your own decoration | medium — `InputDecorationTheme` does a lot invisibly today |
| `AlertDialog` with a `TextField` | RN `Modal` (**not** `Alert` — `Alert.prompt` is iOS-only) | medium — and this is where the dialog-controller leaks die, §3.5 |
| `SnackBar` / `MaterialBanner` | `react-native-paper` Snackbar/Banner, or hand-built | medium |
| `showDatePicker` / `showTimePicker` | §2.5 | **hard** |
| `AsyncView` (220 lines, incl. the 12s stuck-listener timeout) | a `<QueryView>` over TanStack Query state | medium — the timeout behaviour is worth keeping and is not free in Query |

## 2.8 Things relying on Flutter's rendering model: essentially none

Verified by grep across `lib/`:

- `CustomPaint`: **0**
- `AnimationController` / `Tween` / `Transform` / `Hero`: **0**
- Custom `RenderObject`s, `Slivers` beyond stock lists: **0**
- `dart:ffi`: **0**
- Platform channels: **1**, and it is broken (§2.6)

This is the single most favourable fact for the port. The usual reason
Flutter→RN rewrites fail — a custom-painted chart, a bespoke animation system, a
pile of native interop — does not exist here. What you would be porting is
business logic, forms, lists, and a design system.

---

# 3. RECOMMENDED TARGET ARCHITECTURE

Everything below assumes you have decided to port. Several of these changes are
worth making **in the Flutter app instead** — I flag which, because they are the
actual learning goal and they are framework-agnostic.

## 3.1 Folder layout

```
app/                                  ← Expo Router. ROUTES ONLY.
  _layout.tsx                         root: providers + auth redirect
  sign-in.tsx
  (app)/
    _layout.tsx                       profile-complete gate
    (tabs)/
      _layout.tsx                     the three tabs
      groups.tsx
      schedule.tsx
      activity.tsx
    groups/[groupId].tsx
    schedule-builder.tsx
    approvals.tsx
    archived.tsx
    profile.tsx
src/
  features/
    scheduling/
      domain/     schedule-item.ts  selectors.ts  (pure, zero imports from react)
      data/       schedule-repository.ts
      hooks/      use-items.ts  use-item-mutations.ts
      ui/         ScheduleBuilderScreen.tsx  ItemCard.tsx
    auth/  groups/  approvals/  outcomes/  archive/  applock/  notifications/
  core/
    theme/    tokens.ts  colors.ts  typography.ts  status-style.ts  ThemeProvider.tsx
    format/   datetime.ts
    time/     resolve-wall.ts  quiet-hours.ts
    firebase/  config/  ui/ (Card, ListTile, Badge, QueryView, ReasonDialog, WarningPanel)
  services/   messaging.ts  notify.ts
```

**Why `app/` holds routes only.** Expo Router's file tree is a *URL contract*,
not an architecture. A route file should be ~15 lines: read params, render a
component from `src/features/*/ui`. If screens live in `app/`, they can't be
rendered in a test without the router, can't be reused, and renaming a URL moves
your code. This is the one Expo-specific structural rule that people most often
get wrong, and it's cheap to get right on day one.

**Why keep feature-first.** The existing `features/<name>/{domain,data,application,presentation}`
layout is applied with real discipline across nine features and it works. Keep
it. The only rename is `application/` → `hooks/` (because that's what it will
contain) and `presentation/` → `ui/`.

**What's new: `domain/selectors.ts`.** See §3.5(b).

## 3.2 State management

**TanStack Query for server state, Zustand for client state, plain modules for DI.**

*Server state — TanStack Query.* Every Firestore read in this app is a live
snapshot stream, so you need a subscription bridge, not `fetch`-style queries.
One helper does it:

```
useFirestoreSubscription(queryKey, buildQuery, parse)
  → onSnapshot(next: docs => queryClient.setQueryData(key, parse(docs)),
               error: err  => queryClient.setQueryData/​setError(key, err))
  → returns useQuery({ queryKey, enabled:false }) state
```

Why Query and not "just `useState` + `useEffect`": you get the loading/error/data
tri-state that `AsyncValue` gives you today, a key namespace that makes
`ref.invalidate(allItemsAsTargetProvider)` → `queryClient.invalidateQueries` a
one-liner, and deduplication so three mounted tabs share one listener — which is
exactly what Riverpod is buying you now.

*Client state — Zustand.* Two things qualify: the app-lock store (§2.2) and
transient UI state that must outlive a screen. Everything else is `useState`.
Zustand because it is ~1KB, has no provider ceremony, and `useSyncExternalStore`
under the hood — which is the same shape as the `ChangeNotifier` +
`ListenableBuilder` pattern the app already uses for app lock, so the port is
mechanical.

*Rejected alternatives, briefly:* **Jotai/Recoil** (closest to Riverpod's
feel — rejected because "make React feel like Riverpod" is the wrong goal when
the point is to learn the layer boundaries); **Redux Toolkit** (too much
ceremony for ~25 pieces of state); **Context alone** (three permanently-mounted
tabs sharing one context = rerender storms).

*The record/view split survives.* Two query keys hold the record layer
(`['items','asTarget',uid]`, `['items','asPlanner',uid]`), one holds
`['archived',uid]`, and `useVisibleItems()` is a `useMemo` over them calling the
same pure `visible()` selector. Carry the loud "stats must read the record layer"
comment across word for word — it is the kind of constraint that only survives if
it's written where it can be violated.

## 3.3 Navigation — and how it structurally fixes §4.6

> **AMENDMENT 2026-08-14.** This document is a point-in-time analysis and is left
> as written, but three of its factual premises have since changed in the Flutter
> tree, and they cut *against* the port:
>
> - **§4.6 is fixed in Dart.** The tabs are branches of a
>   `StatefulShellRoute.indexedStack` and each tab's detail screens are
>   sub-routes of their branch, so a screen is registered exactly once and a
>   notification `go()` lands in the right tab with the bar and a back stack.
>   The "tab-vs-route duplication" this section is built on no longer exists —
>   it took about half a day in Flutter, not a framework change. (Fixed in tree;
>   the device matrix has not been run.)
> - **The `GoRouterRefreshStream` leak is closed** — `ref.onDispose` cancels the
>   subscription. It was defensive rather than live in any case.
> - **The test count is 65, not 66**, everywhere this document says 66: the
>   deleted one was a fake `FLAG_SECURE` assertion, and `FLAG_SECURE` itself now
>   has a real Kotlin handler that is device-verified — so the "`FLAG_SECURE`
>   really applies on Android" line in the benefits table is also settled in
>   Dart.
>
> Read the argument below with those three corrections applied.

The current bug: `GroupsScreen`, `OutcomeScreen` and `PlannerActivityScreen` are
each *both* a tab inside `HomeShell` **and** a standalone top-level route. A
notification tap calls `router.go(Routes.activity)`, which replaces the whole
stack with a bare screen — no tab bar, no back button. The user must kill the app.

File-based routing removes the *duplication that causes it*: a screen is a file,
and a file is either inside `(tabs)/` or it isn't. There is no way to register
the same screen twice without literally creating two files.

Concretely:

- `(tabs)/groups.tsx`, `(tabs)/schedule.tsx`, `(tabs)/activity.tsx` — tabs, and
  only tabs.
- `approvals.tsx`, `archived.tsx`, `schedule-builder.tsx`, `profile.tsx`,
  `groups/[groupId].tsx` — pushed *on top of* the `(app)` stack, so the tab
  layout remains beneath and the back button always exists.
- Notification taps use `router.push()`, never `replace()`.
- Cold-start taps: `expo-notifications`' `getLastNotificationResponseAsync()` (or
  RNFirebase's `getInitialNotification()`), handled **after** the navigator has
  mounted — Expo Router gives you `useRootNavigationState()` to know when that
  is. The current `app.dart:107-120` handles this correctly for Flutter; the RN
  version has an extra ordering hazard, so write it once and test it.

Auth gating keeps the current, correct split: a synchronous auth redirect in
`app/_layout.tsx` (`<Redirect href="/sign-in" />` when `user == null`), and the
*asynchronous* profile-complete check in `(app)/_layout.tsx`. That is exactly
what `app_router.dart`'s `redirect` + `HomeGate` do today, and ARCHITECTURE.md
§2.3 is right that the split is sensible. Preserve it.

## 3.4 Data fetching and caching

- **`@react-native-firebase` native SDK**, so Firestore's on-device persistence
  keeps working (§1.1). This is load-bearing, not a preference.
- **TanStack Query is a mirror, not a cache.** Do *not* add
  `persistQueryClient` — you'd have two persistence layers disagreeing about the
  same documents. Firestore's cache is the durable one; Query holds the
  in-memory view.
- **Add the pagination seam now.** Every list repository method takes an options
  object and applies it server-side:

  ```ts
  watchItemsForTarget(uid, { limit = 200, since?: Date })
  watchItemsByPlanner(uid, { limit = 200, since?: Date })
  watchMyGroups(uid, { limit = 100 })
  ```

  This answers the "unbounded queries with no pagination seam" finding
  (ARCHITECTURE.md §4.4) at essentially zero cost — even if `limit` stays 200
  forever, the *shape* exists, so adding real pagination later touches the
  repository and one hook rather than every screen. Add `orderBy('scheduledInstantUtc')`
  server-side too, so sorting stops happening in render on every rebuild.

  ⚠️ Coordination note: adding `orderBy` to the `collectionGroup('items')` query
  will require a composite index. `firestore.indexes.json` is backend and out of
  scope for effort, but the *need* originates here — don't be surprised by the
  console error.

- **One place decides staleness.** Snapshots are always fresh, so set
  `staleTime: Infinity` and let `onSnapshot` drive invalidation. Query's refetch
  machinery should never fire for Firestore-backed keys.

## 3.5 What I would change about the current structure, and why

These are the "the Flutter app is poorly structured here" items. Each says
plainly what changes.

**(a) `write → notify` moves out of the widgets.**
Today the pairing appears six times — `_approve`, `_reject`, `_markDone`,
`_skip`, `_withdraw`, and the builder's `_save` — each written as "await the
repository, then await the notifier." Nothing enforces it; nothing tests it. Miss
one paste and an entire event type silently stops firing, and the only symptom is
a push that never arrives.

*Change:* one mutation hook per transition. `useApproveItem()` does the write and
the notify inside a single `mutationFn`. Screens call `mutate()` and cannot skip
the second half. The self-planned skip (`_isSelfPlanned`, currently duplicated in
`outcome_screen.dart:78` and branched again in `schedule_builder_screen.dart`)
lives in the mutation, once. Then §7's Tier 3 tests pin it.
*Worth doing in Flutter too* — ARCHITECTURE.md §5 ranks it #5 and it is a day.

**(b) Item filtering leaves the widgets.**
`.where()` calls are inlined in four screens: pending-filter in
`pending_approvals_screen.dart:35` and `outcome_screen.dart:30`, approved-filter
in `outcome_screen.dart:58`, planned-for-others in
`planner_activity_screen.dart:48,55`. Two of them are the same filter written
twice (the pending count also appears in `home_shell.dart:44-49`).

*Change:* `src/features/scheduling/domain/selectors.ts` — pure functions
`visible()`, `pendingFor()`, `approvedFor()`, `plannedForOthers()`,
`countPending()`. Zero React imports, so they're testable in milliseconds, and
they become the entire content of §7's Tier 1. Screens receive arrays and render.

**(c) Confirmation dialogs collapse into one component.**
`_reject` (approvals), `_skip` (outcomes) and the withdraw dialog (activity) are
structurally identical: build a controller, `showDialog<bool>`, act on `true`.
`_reasonLine()` is *duplicated verbatim* between
`planner_activity_screen.dart:188-205` and `archived_screen.dart:135-150`.

*Change:* one `<ReasonDialog title confirmLabel destructive onConfirm />` and one
`<ReasonLine item />`. Three call sites, one implementation.

**(d) The leaked `TextEditingController`s — a correction, and why the port makes
them impossible.**

A precise count from the code, since it differs from the write-up: there are
**four** undisposed controllers, not five. All four are created inside a method
that shows a dialog and never disposed:

- `groups_screen.dart:63` (create-group dialog)
- `groups_screen.dart:95` (join-by-code dialog)
- `pending_approvals_screen.dart:123` (reject-reason dialog)
- `outcome_screen.dart:164` (skip-reason dialog)

The other four controllers in `lib/` are `State` fields and *are* correctly
disposed (`schedule_builder_screen.dart:41-44`, `profile_edit_screen.dart:36-39`,
`complete_profile_screen.dart:50-53`). ARCHITECTURE.md §4.2 says "five instances"
while listing four locations; four is right. This changes nothing about the
finding — it's the same mistake, and it is real.

*Change:* in React the failure mode does not exist. A dialog holds its text in
`useState`; when the component unmounts, the state is garbage. There is no
imperative object to forget to dispose. Combined with (c), all four leaks are
deleted by construction.
*Also a 15-minute fix in Flutter* — wrap the dialog body in a `StatefulWidget`,
or dispose in the `.then`.

**(e) `ScheduleItem.fromDoc` stops inventing data.**
`schedule_item.dart:132-133`:
`scheduledInstantUtc: (d['scheduledInstantUtc'] as Timestamp?)?.toDate() ?? DateTime.now().toUtc()`.
A missing or malformed timestamp becomes *right now* — so a corrupt item renders
as "scheduled for this instant" and looks completely plausible. Every other field
defaults to `''`, which at least looks empty. This one is plausibly wrong, which
is worse.

*Change — and this is the single most important TypeScript decision in the port:*
**parse at the boundary, never cast.** Define `ScheduleItemSchema` in zod and
`safeParse` every document:

```ts
const parsed = ScheduleItemSchema.safeParse(raw);
if (!parsed.success) {
  reportParseFailure(doc.id, parsed.error);   // Crashlytics/Sentry, with doc id
  return null;                                 // dropped from the list
}
```

Missing `scheduledInstantUtc` is now a **typed failure** that is dropped and
reported, not a fabricated instant. This is a deliberate behaviour change: a
corrupt item disappears instead of lying. Both are bad; only one is diagnosable.
(If you'd rather see it, render an explicit "unreadable item" card — but never
render a made-up time.)

Do the same for the other four models. `as` on Firestore data should be banned by
lint.

**(f) Side effects out of `build()`.**
`app.dart:180-183` calls `ref.read(messagingServiceProvider).registerForUser(uid)`
inside `build()`; `profile_edit_screen.dart:96-111` assigns to controllers and
flips `_initialised` during build. Both are idempotent and commented, but they're
traps.

*Change:* `useEffect` for registration, and initial form values from a
`useState` initializer / `defaultValues`, not a build-time write. Note React's
own version of this trap: effects run twice in dev StrictMode. `MessagingService`'s
existing dedup latch and 30s cooldown are exactly what makes that harmless — that
carefully-debugged design (`messaging_service.dart:48-107`) is worth porting
line for line, comments included.

**(g) One way to get the uid.** Today there are two: `currentUidProvider` (the
clean seam, used by archive + schedule providers) and
`ref.watch(authStateProvider).value?.uid` / `authRepository.currentUser` (used by
groups, group detail, both profile screens, and the schedule builder). The first
exists specifically to make things testable without Firebase, and half the app
ignores it. *Change:* one `useCurrentUid()`, and lint the direct SDK access.

**(h) One state idiom.** Riverpod everywhere + `ChangeNotifier` in app lock
becomes: Query for server state, Zustand for app lock. Two tools with a clear
boundary, rather than two idioms doing the same job.

**(i) One error presentation.** Today: `AsyncView` with retry (list screens), a
local `String? _error` in red (auth, profile), and a `SnackBar` with the raw
exception (schedule builder, groups). Users are shown raw `Exception.toString()`
in several places. *Change:* one `<QueryView>` (port `AsyncView`, **including its
12-second stuck-listener timeout** — that is a genuinely good idea most apps
lack), plus a rule enforced by lint: never render `String(error)` to a user.

**(j) The schedule builder stops resolving the same time three times per frame.**
`_previewLocal`, `_dstBanner` and `_warningBanner` each independently call
`resolveWallTimeToUtc` on every rebuild. *Change:* one `useMemo` over
`(date, time, timezone)` returning `{ utc, anomaly, warnings }`. The screen also
drops from 344 lines to something closer to 200 once the target picker and the
warning panel are extracted.

**(k) Drop `ScheduleItemStatus.cancelled` from the UI, keep it in the parser.**
No code path writes it; the model's own comment calls it "a dead state." But
documents in production could theoretically carry it, so the zod union should
still accept it (mapping to the auto-hidden bucket, as
`isAutoArchived` does today) while the UI's exhaustive switches lose the branch.

## 3.6 TypeScript strictness

`tsconfig.json`:

```jsonc
{
  "extends": "expo/tsconfig.base",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "verbatimModuleSyntax": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

Reasoning, since you asked for it rather than conclusions:

- **`strict`** — non-negotiable. Dart has sound null safety; without `strict`,
  TS has none, and you would be *downgrading* a guarantee this codebase currently
  relies on everywhere (`String?`, `DateTime?`, `ScheduleOutcome?`).
- **`noUncheckedIndexedAccess`** — makes `array[0]` be `T | undefined`. In Dart,
  an out-of-range index throws loudly at runtime; in TS it silently yields
  `undefined` and you get `Cannot read property 'title' of undefined` three
  frames later. This flag restores the "you must handle it" property. It is
  mildly annoying and worth it.
- **`exactOptionalPropertyTypes`** — distinguishes "absent" from "present and
  `undefined`". This matters specifically here: `note`, `rejectionReason`,
  `skipReason` and the quiet-hours pair are all *conditionally written* fields
  (`if (note != null && note.trim().isNotEmpty) 'note': ...`), and writing
  `{note: undefined}` to Firestore is not the same as omitting the key.
- **`noFallthroughCasesInSwitch`** — the status/event switches are exhaustive by
  design (`status_style.dart`, `_handleTap`). Pair it with a `never`-check helper
  so adding a status breaks the build the way Dart's exhaustive `switch` does.
- **`verbatimModuleSyntax`** — keeps type-only imports erasable; avoids a class
  of Metro bundling surprises.

Two rules beyond the compiler flags, both worth more than the flags:

1. **Zod at every Firestore boundary** (§3.5(e)). `strict` does nothing about
   `DocumentSnapshot.data()` being `any`-shaped — that is where your real type
   holes are, and only runtime parsing closes them.
2. **Ban `as` on external data** via `@typescript-eslint/consistent-type-assertions`.
   `as` is how a strictly-typed codebase quietly becomes an untyped one.

---

# 4. PORT PLAN

Estimates assume solo, AI-assisted, part-time-ish focused days — not calendar
days. Every milestone ends with an app that **builds and runs on both iOS and
Android**.

### M0 — Foundations and the iOS unblock · **2–4 days**
Expo app with TypeScript strict, ESLint, Jest. Install `@react-native-firebase`
(app/auth/firestore/messaging/crashlytics) + Google Sign-In with their config
plugins. Register **both** platforms in the Firebase console
(`google-services.json` *and* `GoogleService-Info.plist`). Build and install a
development client on the Redmi and on an iOS device/simulator. Google sign-in
working end to end on both.
*Ends with:* a signed-in blank screen on two platforms.
*Note:* this is where the real iOS work lives, and ~90% of it is Firebase and
Apple configuration that would be **identical in Flutter**. See §5.

### M1 — Theme and primitives · **2–4 days**
Port `app_colors` / `app_text` / `app_tokens` / `status_style` to TS tokens +
`ThemeProvider`. Build the shared components: `Card`, `ListTile`, `Badge`,
`StatusBadge`, `SectionHeader`, `WarningPanel`, `QueryView`, `ReasonDialog`.
Port `theme_tokens_test`'s WCAG contrast checks and rewrite the UI-rules lint for
TSX. Update UI-RULES.md to describe the new mechanism (doctrine first, per the
standing rule).
*Ends with:* a component-gallery route — the `dev/theme_preview.dart` analogue —
rendering every recipe in light and dark on both platforms.

### M2 — Domain and data layer, headless · **3–5 days**
Types + zod schemas for all five models. Five repositories with the pagination
seam. The `useFirestoreSubscription` helper. `selectors.ts`. The DST resolver on
Temporal, validated against the golden table generated from the Dart (§2.4).
Quiet hours. **Tier 1 and Tier 2 tests are written here, not later** (§7).
*Ends with:* M1's gallery still running, plus a dev screen dumping live Firestore
data through the real repositories.

### M3 — Auth, profile, groups · **3–5 days**
Sign-in screen, root auth redirect, profile-complete gate, complete/edit profile,
timezone picker (~600 IANA zones — use `FlatList` + search), groups list, create
group, join by code (**current `joinCodes` behaviour**: `get joinCodes/{CODE}` →
`groupId` → self-join update → member doc → re-read as member), group detail with
the invite-code card, copy, share, and the "can plan for me" consent switch.
*Ends with:* the full consent flow working between two real accounts.

### M4 — The core loop · **4–6 days**
Schedule builder (target picker with "Myself" first, date/time pickers, live
"Fires at" preview, DST banner, quiet-hours warning, submit-and-reset), pending
approvals, my schedule with done/skip, planner activity with withdraw. All
transitions go through mutation hooks that own `write → notify` (§3.5(a)).
*Ends with:* the entire product loop working, minus push.

### M5 — Push · **2–4 days** · ⚠️ **RISKIEST**
FCM token registration (port `MessagingService` faithfully, latch and cooldown
included), the failure banner, background handler registered at module scope,
foreground in-app banner, tap routing via `push()`, Android notification channel
+ the white-on-transparent tray icon, iOS APNs auth key uploaded to Firebase,
`aps-environment` entitlement, permission prompt on both.
*Ends with:* a real push landing on both platforms, foregrounded.

### M6 — Archive and app lock · **2–4 days**
Archive doc, the isolation seam (`onSnapshot` error handler → empty set), the
Archived screen, archive/unarchive with undo. App-lock store (MMKV or held
splash), the ported state machine, the AppState mapping decision from §2.2(b),
`expo-local-authentication`, `expo-screen-capture`. **Rewrite the `AppLockTile`
subtitle to say what each platform actually does.**
*Ends with:* both privacy features working, with honest copy.

### M7 — Hardening and release · **3–5 days**
Error boundaries, Crashlytics/Sentry wiring, EAS build profiles, **real release
signing via EAS credentials** (this retires the debug-keystore `TODO` in
`build.gradle.kts`), a real README, store metadata, the manual-verification
checklist from §7.
*Ends with:* installable release builds for both platforms.

**Total: ~21–37 focused days.** Realistically 4–8 calendar weeks solo, and it
buys **zero new features**.

## 4.1 The riskiest milestone and what would make it fail

**M5 (push), unambiguously.** Every other milestone succeeds or fails based on
code you can see in your editor. M5 depends on four things you cannot:

1. **Apple.** iOS push requires a physical device *and* a paid Apple Developer
   Program membership — there is no simulator path and no free path. You need an
   APNs auth key (`.p8`) uploaded to the Firebase console, a matching bundle id,
   and the `aps-environment` entitlement in the right build profile. Any one of
   these being wrong produces "no notification arrives" with no error anywhere.
   **If you do not have an Apple Developer account, M5 is blocked on iOS and no
   amount of code fixes it.**
2. **RN's background-handler placement.** `setBackgroundMessageHandler` must be
   registered at module scope, outside the React tree, in the app's entry file.
   Expo Router owns the entry point (`expo-router/entry`), so *where* to put it is
   non-obvious and getting it wrong fails silently — the handler simply never
   runs for a backgrounded app. This is a known sharp edge and it is exactly the
   category of bug that cost six days on the Flutter side already (DECISIONS.md
   2026-07-24).
3. **The Redmi.** CLAUDE.md's open item 1 — backgrounded/killed-app delivery on
   HyperOS — is **unverified today and stays unverified after the port**. OEM
   battery policy does not care what framework drew your UI. If it fails, it
   fails for reasons unrelated to React Native, and you will have spent five
   milestones to arrive at the same unanswered question.
4. **Four-event verification needs a second person.** All four events
   (created/withdrawn/decided/outcome) require `creator != target`, so none can
   be tested on one account. CLAUDE.md already flags this as blocked on a friend.
   That blocker ports across unchanged.

*Runner-up risk:* **M1+M2 together**, because that is where "I couldn't keep up
with AI-assisted development" recurs. The theme system is 1,045 lines of
carefully-reasoned decisions being rebuilt in a framework with no theming
primitive, and it is the least rewarding work in the plan, arriving in week one.
If you're going to abandon the port, you will abandon it here.

---

# 5. HONEST RECOMMENDATION

## 5.1 The case FOR the rewrite

- **The codebase is genuinely portable, which is rare.** ~4,512 lines of code, no
  code generation, one production file over 300 lines, and — verified by grep —
  zero dependence on Flutter's rendering model. One platform channel, already
  broken. Most Flutter→RN ports founder on custom painters, animation systems,
  and native interop. None of that exists here.
- **TypeScript + React is the stack AI assistance is best at.** This is not a
  vague claim: RN/Expo/Firebase-JS has far more public example code than
  Flutter/Riverpod/FlutterFire, and it shows in first-draft quality. If your
  bottleneck is "the AI writes code I can't evaluate," a stack where the first
  draft is more often right is a real, if modest, help.
- **Expo genuinely reduces native-config surface**, and one thing it offers has
  no Flutter equivalent at all: **EAS Update**. You can ship a JS-only bug fix to
  users without a store review. For a solo dev shipping to two friends' phones,
  that is a meaningful iteration-speed win.
- **The layer boundaries are more visible.** You said you're learning architecture
  fundamentals. Riverpod does DI, reactive state, and derivation behind one word
  — `Provider` — which makes it excellent to use and poor to learn from. Query vs
  Zustand vs pure selectors forces you to name which one you're doing every time.
- **Several current defects vanish by construction**, not by being fixed: the
  controller leaks (React state), the tab/route duplication behind the
  notification dead-end (file-based routing), the `GoRouterRefreshStream` leak.
  *(Amended 2026-08-14: the last two were since fixed in Dart — see the
  amendment in §3.3. Only the controller leaks remain on this bullet.)*

## 5.2 The case AGAINST

- **You would rebuild 4,500 working lines for zero new features.** `flutter
  analyze` is clean, 66 Dart tests pass, 38 rules tests pass. Every item on
  CLAUDE.md's "Parked & unverified" list stays parked and unverified. You would
  spend 4–8 weeks to arrive precisely where you are, minus the confidence.
- **The alarm layer — the thing the product is named after — gets *harder*.**
  This is the strongest argument and it deserves top billing. `time-app`'s premise
  is alarms firing reliably on a Xiaomi device. Flutter's ecosystem for that is
  materially better than Expo's: `android_alarm_manager_plus`,
  `flutter_local_notifications` with `AndroidScheduleMode.exactAllowWhileIdle`,
  boot-receiver re-registration, and direct Kotlin whenever you need it.
  `expo-notifications`' scheduled notifications do **not** give you an
  `AlarmManager.setExactAndAllowWhileIdle` path with a custom sound surviving
  Doze; you would be writing a native module — the exact thing this port
  otherwise avoids. **You would be porting away from the framework that is better
  at the one feature the product exists to deliver, before building that
  feature.**
- **1,408 lines of comments encode *why*, and rewrites are where that dies.**
  ~21% of `lib/` is comments, and they are multi-paragraph justifications with
  cross-references into DECISIONS.md, not `// increment i`. The comment above
  `_leftAt` explaining why the grace window must never be persisted; the one
  above `archivedIdsStreamProvider` explaining which direction a failure must
  degrade; the one above `_wall()` explaining why it must be UTC-kind. Those
  survive the port **only if you carry them by hand**, and the temptation during
  a rewrite is always to write fresh code and re-derive the reasoning later.
  History says you won't.
- **3,364 lines of design documentation go stale on day one.** ARCHITECTURE.md,
  DECISIONS.md (2,068 lines) and UI-RULES.md are full of file paths and line
  numbers. After the port, every one of those references is wrong.
- **The measurable defects are cheap to fix in place.** ARCHITECTURE.md §5 items
  3–8 — the `FLAG_SECURE` handler, notification-tap navigation, `write→notify`,
  `limit()`, the `fromDoc` default, the controller leaks, the duplicated filters
  — total roughly **2–4 days in Flutter**. Against 21–37 days for the port, in a
  codebase that currently has zero analyzer warnings and no known bugs outside
  that list.
- **You'd be trading a drifting dependency set for a fresh one that starts
  drifting immediately.** `flutter pub outdated` reporting 41 constraint-incompatible
  packages is real, but a `package.json` with `@react-native-firebase` and eight
  config plugins ages *faster* than a Flutter app, and Expo SDK upgrades are an
  annual chore with real breakage.

## 5.3 Your actual motivation, assessed directly

You gave two reasons. They deserve different answers.

**"I could not keep up with AI-assisted development of this app."**

I don't think this is a language problem, and the repo is fairly clear evidence.
The code is small, clean, consistently layered, and analyzer-clean. What grew
faster than you could manage is the surface *around* the code:

- DECISIONS.md is **2,068 lines** — six times the largest source file, and 125KB
  on disk.
- CLAUDE.md's "Parked & unverified" checklist has **four items open since
  2026-07-25**, three weeks ago, plus three deferred product decisions and a
  three-item build queue.
- Coverage is inverted: 908 of 1,354 test lines cover two features that ship no
  product value, while the core loop and all five repositories have **zero**.

Read together, that describes a project where *generating* work outpaced
*verifying* it. A rewrite resets the code and keeps the process — you would be
in exactly this position in six weeks, with less working software and staler
documentation.

The things that would actually help are free and framework-independent:
(1) test the core loop, so you can accept AI-written changes without reading
every line; (2) shrink the doc surface — DECISIONS.md should be a decision *log*,
not an essay collection; (3) adopt the rule that a feature isn't done until its
verification run is recorded, which CLAUDE.md already asks for and which has been
slipping.

**"iOS specifically was becoming difficult."**

This is the stronger argument, and it is worth taking seriously — but check what
is actually blocking, because it is not Flutter. Per ARCHITECTURE.md §1.3:
**iOS was never configured.** There is no `GoogleService-Info.plist`,
`firebase_options.dart` throws `UnsupportedError` on iOS, and the app has never
launched there. That is not "iOS is difficult in Flutter" — that is "iOS has not
been set up." It is `flutterfire configure` plus registering an iOS app in the
Firebase console: **hours, not weeks.**

And the parts of iOS that are genuinely painful are **identical in Expo**:

| | Flutter | Expo |
|---|---|---|
| Apple Developer Program ($99/yr) | required | required |
| Physical device + provisioning for push | required | required |
| APNs auth key wired into Firebase | required | required |
| TestFlight / App Store review | required | required |
| A Mac to build locally | required | required |
| CI build without a Mac | Codemagic / GitHub macOS runners | EAS Build (more turnkey) |
| OTA JS updates | ✗ | ✓ EAS Update |

So the iOS relief Expo offers is real but **narrow**: a more turnkey CI story and
OTA updates. It does not touch the Apple account, the signing, the APNs key, or
review. If iOS is the reason for the rewrite, the rewrite mostly doesn't fix it.

## 5.4 My actual recommendation

**Don't rewrite. Not now.** I think it's a mistake, and I'd rather say that
plainly than hedge it.

The port is well-shaped and the plan in §4 is sound — this is not "rewrites are
always bad." It's that this specific rewrite costs 4–8 weeks, delivers no
features, makes your parked headline feature harder, discards the reasoning
embedded in 1,408 lines of comments, and does not address either of your stated
problems. The one thing it fixes for free — `FLAG_SECURE` on Android — is an hour
of Kotlin in the app you already have.

**Do this instead, in order:**

1. **(1 day) Run the experiment that tests your actual hypothesis.** Configure
   Firebase for iOS in the *existing Flutter app* and get it launching on an iOS
   simulator or device. If that goes fine, the port's main stated motivation
   evaporates and you've spent a day. If it's genuinely miserable, you'll know
   *why* — and you'll know it before spending six weeks. Do not skip this step;
   it is the cheapest information available to you.
2. **(2–4 days) Clear ARCHITECTURE.md §5 items 3–8.** Write the `secure_window`
   Kotlin handler (or change the copy — either is honest, silence is not). Fix
   notification-tap navigation with a `StatefulShellRoute`. *(Both done
   2026-08-14 — see §3.3 amendment.)* Move `write → notify`
   into the repository. Put `limit()` on the item queries. Make `fromDoc` stop
   inventing a timestamp. Dispose the four dialog controllers and extract
   `_reasonLine` and the pending-count filter.
3. **(2–3 days) Write the missing core-loop tests** — approve, reject, done,
   skip, withdraw, plus repository tests against the emulator you already run for
   `firestore-tests/`. This is the direct fix for "I couldn't keep up": tests are
   what let you accept AI-written changes without reading every line.
4. **Then run the real-pair validation that has been queued since July.** It is
   the oldest open item and it gates everything.
5. **Revisit the rewrite only after that** — and if you still want it, you will be
   porting a *verified* app with tests to port against, which is a completely
   different and far safer exercise than porting an unverified one.

**A middle path worth naming:** adopt §3.5's architectural changes — selectors
out of widgets, one mutation layer owning `write → notify`, parse-don't-cast at
the Firestore boundary, a pagination seam — **in Flutter**. Every one of them is
framework-agnostic, every one is a genuine architecture-fundamentals lesson, and
together they are about a week. That gets you most of the learning value of the
rewrite for a fifth of the cost, and if you port later, the port gets easier
because the boundaries already exist.

**If you rewrite anyway:** do M0 alone, as a spike, before committing. Set an
explicit stopping rule — if M0 and M1 don't feel materially better than the
Flutter workflow did, stop and keep the Flutter app. Sunk cost after two
milestones is two weeks; after five it's your whole summer.

---

# 6. SCOPE BOUNDARY

## 6.1 Excluded from this port entirely

These are backend and carry over unchanged regardless of client framework. They
appear in **no milestone** and in **no estimate** above:

- **The Cloudflare Worker** (`worker/`, 664 lines JS). Its `{event, targetUid,
  itemId}` contract, ID-token verification, per-event authorization, structural
  recipient computation, grant re-checks, per-event dedup, and dead-token cleanup
  are all untouched. The client's only obligation is to keep POSTing the same
  body with a Firebase ID token — which `fetch` does in ten lines.
- **`firestore.rules`.** Including everything from the 2026-08-10 hardening: the
  `users` `get`/`list` split, members-only `groups`, the item-write field
  whitelists, and the `notified*` fields being writable by nobody.
- **The `joinCodes` lookup collection** and `scripts/backfill-join-codes.mjs`.
- **The Firestore data model** — every collection path, field name, and the
  three-representation time storage (`localWallTime` / `timezone` /
  `scheduledInstantUtc`).
- **`firestore-tests/`** (38 rules tests). They run against the emulator via Node
  and are entirely independent of the client language.

One consequence worth stating: because the data model is fixed, the port is a
**client rewrite against a stable contract**, which is the safest possible kind.
Both apps could even run against the same project during a transition.

## 6.2 Findings the port does NOT fix — do not assume otherwise

**Security and backend**

- **ARCHITECTURE.md §4.1(a) residual — targeted profile reads.** A signed-in
  caller who already knows a uid can still `get users/{uid}` and read name, home
  timezone and quiet-hours window. Closing it needs a denormalized `groupIds`
  array on every user doc plus a backfill plus an extra billed read — a **data
  model** change, explicitly out of scope. A client rewrite does not touch it.
- **The invite-code brute-force surface.** Six characters from a 32-character
  alphabet is ~10⁹ single `get`s against `joinCodes`. The 2026-08-10 hardening
  made this strictly better (a resolved code now yields only a group id, and the
  doc/roster/grants are all member-gated), but the surface exists. Mitigations —
  App Check, rate limiting, longer codes — are Firebase-console and backend
  concerns. *Partial exception:* `_generateJoinCode()` lives in
  `group_repository.dart:151`, so **lengthening the code is a one-line client
  change** — but doing so does not require a rewrite, and the rewrite does not do
  it for you.
- **The dedup-stamp relocation** (moving `notified*` off the item into a
  server-only `notifications/{…}` doc). Considered and rejected on 2026-08-10;
  still open; Worker + rules only.
- **The Worker's zero test coverage.** No `package.json`, no test runner. All
  notification policy — recipients, dedup, grant checks, token cleanup — remains
  untested. Out of port scope; worth naming because it is the largest untested
  surface in the system.

**Product and verification — all four of CLAUDE.md's open items survive**

- **Backgrounded / killed-app push delivery on HyperOS (item 1).** Unverified
  before, unverified after. OEM battery policy is framework-independent.
- **Rules Test 3 — the grant-off negative test (item 2).** Never run; unaffected.
- **The real two-timezone DST-observing loop (item 3).** Unaffected — and
  arguably *worse*, since §2.4 swaps the resolver engine, so this needs to
  validate code that has never run on a real pair.
- **The iOS locale check (item 4).** Still open, just differently: instead of
  `CFBundleLocalizations` in `Info.plist`, the question becomes whether Hermes's
  `Intl` ships adequate ICU on your Expo SDK (§2.5). Same unanswered question,
  new mechanism.
- **The Group A/C four-event foreground retest.** Still blocked on a second
  person; all four events require `creator != target`.

**Features and product decisions**

- **Alarms.** Do not exist; still won't. And per §5.2, RN makes them harder.
- **`ScheduleItem` has no `durationMinutes`.** Still the blocker for goal/effort
  tracking. (The port is a *good* moment to add it, since you're touching the
  model anyway — but that's a scope expansion, not a fix the port delivers.)
- **Group B "seen" status** — designed 2026-07-23, never built, still deferred.
  It needs locale-aware *relative*-time formatting, which does not exist in
  either codebase.
- **The consent model question** (toggle vs. request-driven) and the
  **share-a-group profile-scoping question** — product decisions, deferred until
  after the first real loop test. Unaffected.
- **Per-item category icons**, deferred and co-designed with goals. Unaffected.

**Housekeeping that changes shape but does not go away**

- **§4.1(d) — `firebase_options.dart` gitignored with no README note.** Becomes
  `google-services.json` / `GoogleService-Info.plist` gitignored with no README
  note. Identical problem, new filenames.
- **Dependency drift.** 41 outdated Flutter packages become a fresh `package.json`
  that starts drifting on day one. A reset, not a fix.
- **`README.md` is still the Flutter template.** It would become the Expo
  template. Write it either way.

**The one genuine exception**

- **Release signing.** `build.gradle.kts` signs release with the debug keystore
  and still carries the `TODO`. EAS credentials management replaces that with a
  managed keystore and iOS certificates as a side effect of M7. This one really
  does get easier — though `flutter build appbundle` with a proper keystore is
  also about an hour's work.

---

# 7. TESTS

The 66 Dart tests do not port. But most of them encode *behaviour*, and behaviour
is language-independent — so the question is which behaviours are worth
re-asserting, and in what form.

## 7.1 Which of the existing tests encode behaviour worth re-implementing

**`tz_resolver_dst_test.dart` (62 lines, 5 cases) — HIGHEST VALUE. Re-implement
first, and expand.**
These encode a *product rule*, not an implementation: gap → push forward; overlap
→ take the first; and a southern-hemisphere case proving the logic isn't
northern-biased. Since §2.4 changes the engine, these tests are the only thing
that proves the new resolver agrees with the old one. **Before deleting any Dart,
generate a golden table of ~50 `(zone, wall-time) → instant` pairs from the
current resolver** and make the TS version reproduce it exactly. Include: both
US transitions, Europe/London, Australia/Sydney, Asia/Kolkata (a non-DST +05:30
zone), and Pacific/Chatham (+12:45 / +13:45) as an adversarial case.

**`archive_isolation_test.dart` (321 lines) — re-implement the *properties*, not
the tests.**
321 lines encode about five assertions, and it's the assertions you want:

1. An archive read failure yields "nothing archived" — it can **never** put My
   Schedule or Activity into an error state.
2. Loading also reads as "nothing archived" (the deliberate flash-then-filter
   trade).
3. Auto-hide (rejected/withdrawn) still works when the archive is unreadable,
   because it reads a field already in hand.
4. `archivedItems` dedups self-planned items, which appear in both source streams.
5. A live item (pending, or approved-not-done) is hideable by neither route.

In RN this gets *easier* to test: the isolation is an `onSnapshot` error callback
writing `new Set()` instead of a `StreamTransformer`, and the selectors are pure
functions. Five focused tests, not 321 lines.

**`app_lock_test.dart` (587 lines) — re-implement most, and delete one thing
deliberately.**

Keep: grace-window boundaries (29s does not lock, 31s does), fresh-construction-
starts-locked (the task-kill answer), refuse-to-enable when the device has no
credential, self-disable-and-explain when the credential is removed mid-session,
`didBackground` must not start a grace window while an auth prompt is up, and the
widget test pinning gate **placement** (dialogs and pushed routes sit behind the
lock) — that last one catches a whole class of bug that unit tests cannot.

Delete: **the assertions that `start()` "re-applies `FLAG_SECURE`" against a fake
`SecureWindow`.** ARCHITECTURE.md §4.5 is exactly right that these are worse than
no test — the suite proves the Dart side *calls a method that lands nowhere*, and
in doing so it made a broken privacy feature look covered. In RN the underlying
call is real on Android, so an equivalent test is defensible — but only if it is
paired with a **recorded manual verification** (turn the lock on, try to take a
screenshot, write down the date). The generalizable lesson, and the most important
sentence in this section: **never let a fake stand in for an unverified native
effect.** If the only thing proving a native behaviour is a fake, you have proven
nothing.

Also drop the `didDetach` tests — there is no `detached` in RN (§2.2(a)).

**`theme_tokens_test.dart` (194 lines) — port the contrast checks, drop the rest.**
The programmatic WCAG-AA contrast assertions are pure maths over hex values and
port to Jest with no framework at all. They are genuinely valuable and rare. The
`ThemeData`-shaped assertions do not port.

**`ui_rules_lint_test.dart` (190 lines) — port the *technique*, upgrade the
mechanism.**
Reading source files and regexing for banned patterns works identically over
`.tsx`. Rewrite the patterns: ban raw hex colours outside `theme/`, raw numeric
`fontSize`, magic numbers in `StyleSheet` spacing, direct `@expo/vector-icons`
imports outside `app-icons.ts`. **Better: make it an ESLint
`no-restricted-syntax` rule** so it fires in the editor rather than at test time,
and keep a source-scan test as the backstop. Note that `pendingMigration` is
currently empty — start the new one empty too, and keep the "this list only ever
shrinks" rule.

## 7.2 What the strategy should be instead

The current coverage is inverted, and understanding *why* matters more than the
numbers: **tests were written when the feature was interesting, not when the risk
was high.** App lock and archive are the two most recently built features and the
two most intellectually satisfying; they got 908 of 1,354 test lines. The core
loop — the thing the product *is* — shipped earlier and got zero. Neither
decision was wrong in the moment; the pattern is what's wrong.

Invert it deliberately, in five tiers:

**Tier 1 — Pure domain logic. Jest, no mocks, milliseconds. Target near-100%.**
The DST resolver (with the golden table), quiet-hours math (**currently zero
coverage despite being pure functions with a wrap-past-midnight edge case** —
`minuteInWindow` is the single easiest untested bug in the repo), the visibility
selectors, pending/approved/planned-for-others filters, the status→style mapping,
the app-lock reducer, and **every zod parser including malformed-document cases**
(a doc missing `scheduledInstantUtc` must be rejected, not defaulted — §3.5(e)).
This tier is cheap, fast, and is where the real bugs are.

**Tier 2 — Repositories against the Firestore emulator. THE HIGHEST-VALUE NEW
SUITE.**
All five repositories currently have **zero** tests. You already run the emulator
for `firestore-tests/` (38 rules tests, `@firebase/rules-unit-testing` +
`firebase-tools`, `npm test`). Point the client repositories at it with
`connectFirestoreEmulator` and test for real: `createItem` (both the self-planned
`approved` path and the planner `pending` path), `approve`, `reject` with and
without a reason, `markDone`, `markSkipped`, `withdraw`, `archive`/`unarchive`,
`createGroup` (including that it writes `joinCodes/{CODE}` *after* the group doc),
and `joinByCode` (including that the returned group's `memberUids` contains the
joiner — the bug §6.1 fixed, which nothing currently guards). **The harness
already exists; this costs a day and closes the biggest hole in the repo.**

**Tier 3 — Mutation pairing.** One test per transition asserting write-then-notify
fires with the correct event, using a fake notifier. Six tests. This directly
kills ARCHITECTURE.md §3.3's sharpest edge — six call sites remembering to pair
two awaits, with nothing enforcing it. Also assert the self-planned skip fires
*no* notify.

**Tier 4 — Component tests.** `@testing-library/react-native`, five interactions:
approve, reject-with-reason, done, skip-with-reason, withdraw-with-confirm.
Assert *the mutation was called with the right arguments*, not pixels. Five tests,
and they're the ones ARCHITECTURE.md §5 item 6 has been asking for.

**Tier 5 — One E2E flow.** Maestro (simpler than Detox, YAML, works with Expo dev
builds): sign in → create group → join from the second account → grant → plan →
approve → done. Run it before releases, not on every commit. This is what makes
"real-pair validation" a repeatable thing instead of a recurring manual event that
keeps slipping.

**Not machine-testable — verified by a dated, recorded manual run.** Keep a
checklist in the repo, and write the date and result next to each line every time:

- Push delivery: foreground / backgrounded / process-killed, per platform, per
  device (the Redmi specifically).
- Notification tap routing from cold start, from background, and from foreground.
- Biometric prompt and the no-credential refusal path.
- Screenshot blocking and the recents thumbnail (Android; and honestly record
  that iOS does not).
- Locale rendering in a non-Latin locale with a 24h device setting.

That last group is where this project has actually been failing — not for lack of
a test framework, but because runs weren't recorded. CLAUDE.md's "Parked &
unverified" list is the right instinct; it just needs the discipline that an item
is not done until a dated run sits next to it.

**Note on the Worker:** it keeps its zero coverage. Adding a `package.json` and
`node:test` to `worker/` would be a day and would cover all the notification
policy — recipients, dedup, grant checks, token cleanup. Out of port scope, but
it is the highest-value testing work *outside* this document's boundary, and it
is equally available whether or not you rewrite the client.
