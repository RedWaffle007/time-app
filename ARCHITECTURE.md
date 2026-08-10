# ARCHITECTURE.md

A description of what this codebase **actually is**, derived by reading the code
— not from `CLAUDE.md`, `DECISIONS.md`, or `mvp-spec.md`. Where the code and the
docs disagree, the code wins and I say so.

Written 2026-08-10 against branch `feat/notification-events` (`a8a3d4c`).

---

## 0. One-paragraph summary

`time-app` is a small, unusually disciplined Flutter app backed entirely by
Firebase, plus one Cloudflare Worker that sends push notifications. Two people
join a group; one grants the other permission to plan their day; the planner
creates schedule items in the target's timezone; the target approves each one and
later marks it done or skipped; both sides get pushes. It is roughly 4,500 lines
of real Dart (plus 1,400 lines of comments), 1,350 lines of tests, and 660 lines
of JavaScript. It is Android-only in practice despite claiming to be
cross-platform. The architecture is a clean, consistent repository/provider
layering with essentially no ceremony — no code generation, no DI framework, no
BLoC. The main risks are not structural: they are a security-rules hole that lets
any signed-in user enumerate every user and every group, a privacy feature
(`FLAG_SECURE`) that is silently a no-op because its native handler was never
written, and a notification-tap flow that strands the user on a dead-end screen.

---

# 1. INVENTORY

## 1.1 Directory structure and size

```
time-app/
├── lib/            62 files  6,578 lines  (4,512 code / 1,408 comment / 658 blank)
├── test/            5 files  1,354 lines
├── worker/          7 files    664 lines  (Cloudflare Worker, JavaScript)
├── android/                              (Kotlin: 5 lines total)
├── ios/                                  (Swift scaffold, unconfigured)
└── *.md            7 files  3,364 lines  of design documentation
```

Per-directory Dart line counts:

| Directory | Files | Lines | What lives there |
|---|---|---|---|
| `lib/` (root) | 3 | 381 | `main.dart`, `app.dart`, `firebase_options.dart` |
| `lib/core/theme` | 6 | 1,045 | Colors, type, spacing tokens, icon vocabulary, status→style mapping |
| `lib/core/widgets` | 3 | 321 | `AsyncView`, `SectionHeader`, `WarningPanel` |
| `lib/core/timezone` | 2 | 152 | DST-aware wall-time resolver, quiet-hours math |
| `lib/core/format` | 1 | 46 | The single locale-aware date/time formatter |
| `lib/core/config`, `lib/core/firebase` | 2 | 15 | Two constants (Worker URL, OAuth client ID) |
| `lib/routing` | 2 | 143 | go_router config + stream→Listenable bridge |
| `lib/dev` | 2 | 360 | Dev menu + a standalone theme-preview app |
| `lib/features/scheduling` | 5 | 823 | The core domain: items, repository, providers, 2 screens |
| `lib/features/applock` | 8 | 697 | Biometric app lock (controller, store, gate, screens) |
| `lib/features/auth` | 8 | 712 | Google sign-in, profile CRUD, timezone picker |
| `lib/features/groups` | 7 | 501 | Groups, invite codes, planner-consent grants |
| `lib/features/archive` | 4 | 353 | Per-user soft-archive (hide settled items) |
| `lib/features/notifications` | 4 | 344 | FCM token registration, push-trigger client |
| `lib/features/outcomes` | 1 | 196 | "My Schedule" — mark done/skip |
| `lib/features/approvals` | 1 | 154 | Pending approvals queue |
| `lib/features/home` | 3 | 164 | Bottom-nav shell, profile gate, account menu |

Notable: **only one file in `lib/` exceeds 300 lines** (`schedule_builder_screen.dart`,
344). That is unusual and good. The largest files in the repo are tests.

Also notable: **~21% of `lib/` is comments**, and they are not `// increment i`
comments — many are multi-paragraph essays justifying a design decision, with
cross-references into `DECISIONS.md`. This is a deliberate style. It makes the
code slow to skim and fast to understand.

## 1.2 Dependencies (`pubspec.yaml`)

Dart SDK `^3.12.2`. Every dependency below is a direct dependency.

| Package | Version | What it does | Verdict |
|---|---|---|---|
| `flutter_riverpod` | ^3.3.2 | State management / DI container | **Core.** Every provider in the app. |
| `go_router` | ^17.3.0 | Declarative routing | **Core**, though barely used (10 flat routes, no nesting, no deep links). |
| `firebase_core` | ^4.12.1 | Firebase bootstrap | **Core.** |
| `firebase_auth` | ^6.5.6 | Auth session, ID tokens | **Core.** |
| `cloud_firestore` | ^6.7.1 | The entire database and the entire realtime layer | **Core.** This *is* the data layer. |
| `firebase_messaging` | ^16.0.4 | FCM token + push receipt | **Core** to the accountability loop. |
| `google_sign_in` | ^7.2.0 | The only sign-in provider | **Core.** |
| `timezone` | ^0.11.1 | IANA tz database, offset math | **Core.** The app's premise depends on it. |
| `flutter_timezone` | ^5.1.0 | Reads the *device's* current zone | Incidental — used in exactly one place, to prefill the profile timezone (`complete_profile_screen.dart:42`). Could be dropped for a manual pick. |
| `intl` | `any` | Locale-aware date/number formatting | **Core** to the "worldwide" requirement. Version pinned to `any` because `flutter_localizations` constrains it — reasonable, but it means `pub upgrade` can move it without warning. |
| `flutter_localizations` | SDK | Material chrome localization | **Core.** |
| `http` | ^1.2.2 | One POST, to the Worker | Incidental but justified — pulling in Dio for a single call would be worse. |
| `firebase_crashlytics` | ^5.2.6 | Remote error reporting | Core to the *workflow* (testing on a friend's phone with no USB), not to the product. |
| `share_plus` | ^13.2.1 | Share the invite code | Incidental. One call site. |
| `local_auth` | ^2.3.0 | Biometric / PIN prompt | Core to the app-lock feature. **Note: v3.0.2 is available and this is 2 majors behind on the Android sub-plugin.** |
| `shared_preferences` | ^2.3.2 | One boolean (app lock on/off) | Incidental but correct — the flag is deliberately device-local, not account-level. |
| `cupertino_icons` | ^1.0.8 | Cupertino icon font | **Unused.** No `Cupertino*` reference anywhere in `lib/`. Flutter template leftover. Delete it. |

Dev dependencies: `flutter_test`, `flutter_lints ^6.0.0`. That's all.

**There is no `build_runner`, no `freezed`, no `json_serializable`, no `mockito`,
no `riverpod_generator`.** No code generation of any kind. All serialization is
hand-written. This is a deliberate, defensible choice at this size (see §2.4).

`flutter pub outdated` reports **41 packages with newer, constraint-incompatible
versions**. Nothing is broken today, but the dependency set is drifting.

## 1.3 Native code

Almost none, which is the point — but there is one hole.

**Android** (`android/`):
- `MainActivity.kt` is **5 lines**: `class MainActivity : FlutterActivity()`. Nothing else.
- `AndroidManifest.xml` is hand-edited and well-commented: explicit `INTERNET`
  (needed because Flutter only injects it into debug manifests), `POST_NOTIFICATIONS`,
  an FCM default channel id, and — added recently — a proper white-on-transparent
  tray icon (`@drawable/ic_notification`) plus an accent color, fixing the
  "notification shows a white blob" defect.
- `build.gradle.kts`: `minSdk 23`, Java/Kotlin 17, Google Services + Crashlytics
  Gradle plugins. **Release builds are signed with the debug keystore** (an
  explicit `TODO` remains). Not shippable to Play as-is.
- No custom Kotlin beyond `MainActivity`.

**iOS** (`ios/`):
- Stock Flutter scaffold. `AppDelegate.swift` is the generated default.
- `Info.plist` has been hand-edited with a full `CFBundleLocalizations` array
  (~80 locales) for the worldwide-formatting requirement.
- **Firebase is not configured for iOS at all.** `firebase_options.dart` throws
  `UnsupportedError` on `TargetPlatform.iOS`, and there is no
  `GoogleService-Info.plist`. The app cannot launch on iOS. The claim in
  `CLAUDE.md` that this is a "cross-platform (Android + iOS)" app is aspirational;
  today it is an Android app with an iOS folder.

**Platform channels:** exactly one, and **it is broken** —
`lib/features/applock/data/secure_window.dart:22` declares
`MethodChannel('time_app/secure_window')` and calls `setSecure(bool)`.
**No native handler for that channel exists anywhere in the repo.** Grepping the
whole tree finds the channel name only in Dart. The call therefore always throws
`MissingPluginException`, which the code catches and turns into a `debugPrint`
that says "expected off Android" — but it happens *on* Android too. See §4.5.

**FFI:** none.

**Plugins with native implementations** (transitively pulled in): `cloud_firestore`,
`firebase_auth`, `firebase_core`, `firebase_crashlytics`, `firebase_messaging`,
`google_sign_in`, `local_auth`, `shared_preferences`, `share_plus`,
`flutter_timezone`, `path_provider`, `flutter_plugin_android_lifecycle`, plus
`jni`/`jni_flutter` (dragged in by a Firebase plugin).

## 1.4 The Cloudflare Worker (`worker/`)

A separate, deployed JavaScript service. 664 lines, no dependencies, no
`package.json` — it runs on Web APIs only.

| File | Lines | Role |
|---|---|---|
| `index.js` | 122 | HTTP entry point. Method/size checks, ID-token verify, per-event authorization, error handling. |
| `notify.js` | 198 | **All the notification policy.** Deliberately transport-agnostic so it can be lifted into a Cloud Function unchanged. |
| `firestore-rest.js` | 101 | Firestore REST client + a hand-rolled value codec. |
| `verify-id-token.js` | 93 | Full Firebase ID-token verification against Google's JWKS, in WebCrypto. |
| `google-auth.js` | 74 | Signs a service-account JWT and exchanges it for an OAuth token. |
| `util.js` | 39 | base64url / PEM helpers. |
| `fcm-rest.js` | 37 | FCM HTTP v1 send, mapping error codes to a 3-word vocabulary. |

`wrangler.toml` holds only the public project id; the service-account JSON is a
`wrangler secret`. This part is genuinely well built.

---

# 2. ARCHITECTURE

## 2.1 The pattern actually in use

**Feature-first layering with a repository pattern, and no formal architecture
beyond that.** It is not MVVM, not BLoC, not Clean Architecture. There is no
use-case layer, no `Either`/`Result` type, no dependency-inversion ceremony.

The consistent shape is three layers per feature:

```
features/<name>/
  domain/        plain immutable classes + a `fromDoc` factory
  data/          a repository class holding a FirebaseFirestore instance
  application/   Riverpod providers wiring the repository to the UI
  presentation/  ConsumerWidget / ConsumerStatefulWidget screens
```

This is applied with real discipline — 9 features, all shaped the same way. Where
a layer is missing it is missing because it's genuinely empty (`approvals/` and
`outcomes/` are `presentation/` only; they read `scheduling`'s providers).

**Two features break the mould, and both for good reason:**

- `applock/` has a real **state machine** (`AppLockController`, a `ChangeNotifier`,
  209 lines) with every collaborator behind an interface and the clock injected.
  It is the only piece of business logic in the app that is genuinely unit-tested,
  and it is tested well (587 lines of tests).
- `archive/` is a *view-filter* feature: it owns no screens' data, it modifies
  what other features' providers emit.

**Where the pattern is thin:** the repositories are anaemic. They are
`FirebaseFirestore` adapters — a method per query, a method per write. There is
no domain service layer, so anything that isn't a single Firestore call ends up
in a widget (see §3.3).

## 2.2 State management

**Riverpod 3, applied consistently and deliberately plainly.** There are ~25
providers, all declared as top-level `final`s in `application/` files. No
code generation, no `autoDispose`, and `family` used in exactly three places where
the parameter is real (`profileByUidProvider`, `membersProvider`, `grantsProvider`).

The provider graph is shallow and easy to hold in your head:

```
authStateProvider (Stream<User?>)
 ├─ currentUidProvider (String?)          ← the testability seam
 ├─ profileProvider (Stream<UserProfile?>)
 └─ profileByUidProvider(uid)

allItemsAsTargetProvider  ─┐
allItemsAsPlannerProvider ─┤→ myItemsAsTarget / myItemsAsPlanner / archivedItems
archivedIdsProvider       ─┘   (three derived Providers holding AsyncValue)
```

Two ideas here are better than average:

1. **The record/view split** (`schedule_providers.dart:13-35`). `allItems*` are
   the raw truth; `myItems*` are the same data minus what the user has hidden.
   A very loud comment states that any future stats consumer must read the record
   layer, not the view layer.
2. **The archive isolation seam** (`archive_providers.dart`). The archive stream
   is transformed so that *it can never emit an error*; a failed archive read
   degrades to "nothing is archived" rather than taking down the schedule. This
   is exactly the right failure direction and it is covered by tests.

**Inconsistency:** the app-lock feature uses a raw `ChangeNotifier` +
`ListenableBuilder` instead of a Riverpod `Notifier`. Riverpod holds the instance
in a plain `Provider` that never rebuilds, and three widgets each wrap themselves
in a `ListenableBuilder`. It works and it is testable, but it is a second state
idiom living alongside the first.

**Smell:** `app.dart:180-183` calls `ref.read(messagingServiceProvider).registerForUser(uid)`
*inside `build()`*. So does `profile_edit_screen.dart:96-111`, which assigns to
controllers and flips `_initialised` during build. Both are guarded so they're
idempotent, and both are commented — but side effects in `build` are a trap for
whoever touches these next.

## 2.3 Navigation

**go_router 17**, configured in one 123-line file. Ten flat routes, one of them
parameterised (`/groups/:groupId`), one registered only under `kDebugMode`.

```
/                → HomeGate  (profile-complete? → HomeShell : CompleteProfileScreen)
/auth            → AuthScreen
/profile         → ProfileEditScreen
/groups          → GroupsScreen
/groups/:groupId → GroupDetailScreen
/schedule-builder→ ScheduleBuilderScreen
/approvals       → PendingApprovalsScreen
/outcome         → OutcomeScreen
/activity        → PlannerActivityScreen
/archived        → ArchivedScreen
/dev             → DevMenuScreen   (debug builds only)
```

Auth gating is a synchronous `redirect` driven by `FirebaseAuth.instance.currentUser`,
re-run via a `refreshListenable` bridging the auth stream. The *profile-complete*
check is deliberately kept out of the router and done asynchronously in `HomeGate`.
That split is sensible.

**Deep links: none.** The Android manifest declares only `MAIN`/`LAUNCHER` — no
intent filters, no `android:scheme`. The only "deep link" is a push notification
tap, handled in Dart (`app.dart:155-173`) by switching on `message.data['event']`
and calling `router.go(...)`.

**This is where navigation is actually broken.** `GroupsScreen`, `OutcomeScreen`
and `PlannerActivityScreen` are each *both* a tab inside `HomeShell` **and** a
standalone top-level route. A notification tap calls `router.go(Routes.activity)`,
which **replaces the whole stack** with a bare `PlannerActivityScreen` — no bottom
navigation bar, no back button, no route to anywhere else. The user taps a
notification and lands in a room with no doors; only killing and relaunching the
app recovers. Same for `/approvals`. See §4.6.

## 2.4 Data layer

**Local persistence:** none, deliberately, except:
- `shared_preferences` — one boolean, the app-lock flag.
- Firestore's own on-device cache, which is on by default and is doing a lot of
  invisible work here (it is why the app is usable offline at all).

There is no Drift/Isar/Hive/sqflite, no manual JSON cache, no repository-level
memoisation. Every screen reads a live Firestore snapshot stream.

**Network client:** two, and they're unrelated:
- `cloud_firestore` for everything data-shaped.
- `package:http` for exactly one POST to the Worker (`http_event_notifier.dart`).

**Models and serialization:** five hand-written domain classes — `UserProfile`,
`Group`, `Membership`, `PlannerGrant`, `ScheduleItem` (+ `ScheduleOutcome`). Each
has a `fromDoc(DocumentSnapshot)` factory with defensive casts and defaults.
**None has a `toMap`/`toJson`** — writes are constructed inline in the repositories
as `Map<String, dynamic>` literals with `FieldValue.serverTimestamp()` sprinkled in.
That asymmetry is intentional (writes need sentinel values that don't round-trip
through a model), but it means the field names exist in two places and nothing
checks they agree.

**Code generation:** none. No `build_runner` in `dev_dependencies`, no `.g.dart`
or `.freezed.dart` files. At 5 models this is the right call; the cost is that
`ScheduleItem.fromDoc` silently papers over bad data (see §4.4).

**Caching:** Firestore's cache only. Note that `HomeShell` uses an `IndexedStack`
specifically so all three tabs stay mounted and their listeners stay live — a
deliberate trade of memory and read-count for instant tab switching.

## 2.5 Backend / API surface

Everything the app talks to, exhaustively:

**A. Firestore** (via SDK, realtime listeners):

| Path | Access | Used by |
|---|---|---|
| `users/{uid}` | read any, write own | profiles, target names/timezones |
| `users/{uid}/fcmTokens/{token}` | owner only | push token registration |
| `users/{uid}/state/archived` | owner only | soft-archive `{itemId: timestamp}` map |
| `groups/{id}` | read any signed-in, create own, self-join update | group list, join-by-code |
| `groups/{id}/members/{uid}` | members read, own write | member roster |
| `groups/{id}/plannerGrants/{planner}_{target}` | members read, target writes | consent |
| `scheduleItems/{targetUid}/items/{itemId}` | target read/write, creator withdraw | the core data |
| collectionGroup `items` where `createdByUid == me` | | planner's Activity feed |
| collectionGroup `plannerGrants` where `plannerUid == me` | | planner's target picker |

The two collection-group queries need their own recursive `{path=**}` rules — the
rules file documents that this was discovered empirically, which is correct and
non-obvious.

**B. Firebase Auth** — Google provider only; `signInWithCredential` with a Google
ID token scoped by `serverClientId`.

**C. Firebase Cloud Messaging** — token registration, `onMessage`,
`onMessageOpenedApp`, `getInitialMessage`, and a registered (intentionally empty)
background handler.

**D. Firebase Crashlytics** — `FlutterError.onError` and
`platformDispatcher.onError` both routed to it, plus explicit `recordError` calls
at the three places where a silent failure would be undiagnosable.

**E. The Cloudflare Worker** — one endpoint,
`POST https://time-app-notify.timeapp.workers.dev`, body
`{event, targetUid, itemId}`, `Authorization: Bearer <Firebase ID token>`.
Four events: `created`, `decided`, `outcome`, `withdrawn`.

The Worker's design deserves credit: **the client never asserts what happened.**
It says "event X occurred on item Y"; the Worker re-reads the item from Firestore
and derives the actual sub-type (approved vs rejected, done vs skipped) itself.
Authorization branches by event — planner-triggered events require the caller to
be the item's creator, target-triggered events require the target. It checks the
grant is still active in *both* directions, dedups per-event via distinct
`notified*` fields, and cleans up dead FCM tokens as a side effect.

**F. Google APIs (Worker only)** — `oauth2.googleapis.com/token`,
`firestore.googleapis.com` REST, `fcm.googleapis.com` v1 send, and Google's JWKS
endpoint.

## 2.6 Auth flow

```
launch
  └─ main(): Firebase.initializeApp → Crashlytics hooks → FCM bg handler
             → tz database → locale symbols → read app-lock flag → runApp
  └─ router redirect: currentUser == null → /auth
       └─ AuthScreen → GoogleSignIn.authenticate() → idToken
            → GoogleAuthProvider.credential → signInWithCredential
            → authStateChanges fires → refreshListenable → redirect → /
  └─ HomeGate: watch profileProvider
       ├─ null or incomplete → CompleteProfileScreen (name + REQUIRED home tz)
       └─ complete           → HomeShell (3 tabs)
  └─ in parallel: TimeApp.build sees a uid → MessagingService.registerForUser
       → requestPermission → getToken → write users/{uid}/fcmTokens/{token}
```

Sign-out is not `auth.signOut()` — every sign-out button calls
`signOutWithTokenCleanup(ref)`, which deletes this device's FCM token *while still
authenticated* (the token doc is owner-only, so the order matters) and then signs
out of both Google and Firebase.

The FCM registration path is the most carefully engineered code in the app, and
it reads like something that was debugged the hard way: the "registered" latch is
only set after the Firestore write succeeds, both FCM calls are time-boxed at 15s,
failures are retried on resume and on auth change behind a 30s cooldown, an
explicit user "Retry" bypasses the cooldown, and a failure surfaces as a
dismissible `MaterialBanner` rather than silence.

---

# 3. HOW IT WORKS

## 3.1 Screen-by-screen map

**`AuthScreen`** (`/auth`, 79 lines) — App name, one tagline, one "Continue with
Google" button. Shows a spinner while signing in and the raw exception text on
failure. That's the entire screen.

**`CompleteProfileScreen`** (no route; rendered by `HomeGate`, 152 lines) — First
run only. Name (prefilled from the Google account) and a **required** home
timezone (prefilled from the device via `flutter_timezone`, changeable via the
picker). Writes `users/{uid}` with `createdAt`/`updatedAt`. Has a sign-out escape
hatch in the app bar.

**`TimezonePicker`** (pushed, 60 lines) — Full-screen searchable list of every
IANA zone from the in-memory tz database. Returns the identifier via `pop`.

**`HomeGate`** (`/`, 37 lines) — Not really a screen: watches `profileProvider`
and renders either the loading/timeout view, `CompleteProfileScreen`, or
`HomeShell`.

**`HomeShell`** (78 lines) — The real home. `IndexedStack` of three tabs behind a
`NavigationBar`. The "My Schedule" destination carries an orange count badge of
items pending the user's decision, which renders nothing at zero.

**`GroupsScreen`** (tab 1 + `/groups`, 133 lines) — Lists the user's groups (name,
join code, member count). FAB creates a group (dialog → name → 6-char code from a
no-O/0/I/1 alphabet). App-bar action joins by code (dialog → uppercase code →
lookup → arrayUnion). Empty state tells you to create or join.

**`GroupDetailScreen`** (`/groups/:groupId`, 142 lines) — The invite code in a
card with copy-to-clipboard and share-sheet buttons, then the member roster. Each
*other* member has a **"can plan for me" switch** — this is the consent primitive
of the whole product, and it is one `Switch` on a `ListTile`. Flipping it writes
`groups/{g}/plannerGrants/{planner}_{me}`.

**`ScheduleBuilderScreen`** (`/schedule-builder`, 344 lines — the largest screen)
— The planner's compose form. A target picker listing "Myself" first, then every
person who granted them permission (from the cross-group collection-group query).
Once a target is chosen: a neutral banner naming *whose* timezone you are
building in, title, date picker, time picker, optional note, a live "Fires at:"
preview rendered in the target's zone, and up to two warning panels — one for DST
gap/overlap, one for quiet hours / the fixed 11pm–6am band. Both warnings are
non-blocking. Submitting resets the form but keeps the target, so you can plan a
whole day in sequence.

**`PendingApprovalsScreen`** (`/approvals`, 154 lines) — The target's queue,
sorted soonest-first, under an orange "Waiting on you" section rule. Each card:
title, the instant in its own timezone, who it's from, the planner's note in
quotes, and Reject / Approve buttons. Reject opens a dialog with an optional
reason. Neither button is red — rejecting is treated as a legitimate outcome, not
a destructive act.

**`OutcomeScreen`** ("My Schedule" tab + `/outcome`, 196 lines) — The target's
approved items, soonest-first. Each card offers Skip (dialog + optional reason)
and Done. Once an outcome exists, the buttons are replaced by a status badge and
the skip reason. Settled cards grow a `⋮` overflow with Archive. The app bar
carries a badge-counted shortcut into the approvals queue.

**`PlannerActivityScreen`** ("Activity" tab + `/activity`, 205 lines) — The
planner's mirror: everything they created *for other people* (self-planned items
are filtered out — those live in My Schedule), newest first. Each card shows one
status badge (an outcome badge replaces the approval badge, because "Done" implies
"Approved"), the time explicitly labelled as *their* local time, the target's
reason if any, a Withdraw button while still pending, and Archive once settled.
FAB → Schedule Builder.

**`ArchivedScreen`** (`/archived`, from the account menu, 158 lines) — One shared
list of everything hidden from this user's views, by either route, newest first.
Manually archived items get an Unarchive button; auto-hidden (rejected/withdrawn)
ones are read-only. **This is the only screen where a rejection reason remains
readable**, since rejected items vanish from Activity immediately.

**`ProfileEditScreen`** (`/profile`, 199 lines) — Name, home timezone, a quiet-hours
switch with From/To time pickers, Save, and — below the Save button, deliberately —
a "Privacy" section with the app-lock toggle (which applies instantly rather than
on save).

**`LockScreen`** (overlay, not a route, 89 lines) — Opaque full-bleed cover with a
lock icon and an Unlock button. Prompts the OS biometric/PIN dialog immediately on
appear; does not re-prompt in a loop if you cancel.

**`DevMenuScreen`** (`/dev`, debug only, 80 lines) — A flat list of links to every
screen. Its own header comment says "REMOVE THIS SCREEN before any release build",
which is now stale — the route is compiled out under `kDebugMode`.

**`lib/dev/theme_preview.dart`** — Not part of the app. A separate `main()` you run
with `flutter run -t`, rendering the real warning panel and the real Activity
screen against synthetic data so colour values can be eyeballed in both themes.

## 3.2 The five data flows that matter

### Flow 1 — Grant consent (the product's whole premise)

```
GroupDetailScreen: user flips "can plan for me" for member M
  → groupRepository.setPlannerGrant(groupId, plannerUid: M, targetUid: me, granted: true)
  → Firestore set() on groups/{g}/plannerGrants/{M}_{me}
      rules check: caller == targetUid == grantedByUid, both parties in memberUids
  → grantsProvider(groupId) snapshot fires → this screen's switch settles
  → on M's device: myPlanningTargetsProvider (collectionGroup query, granted==true)
      fires → "me" appears in M's Schedule Builder target picker
```

No push, no polling — the cross-device propagation is purely a Firestore listener
on a collection-group query. Revocation runs the identical path with `false`, and
the Worker independently re-checks the grant before every push, so a revoked grant
also silences notifications.

### Flow 2 — Plan an item (timezone correctness lives here)

```
ScheduleBuilderScreen: target + title + date + time
  → _wall() builds DateTime.utc(y,m,d,h,min)   ← UTC-kind on purpose: a local
        DateTime would be silently normalised by the PLANNER's DST rules
  → live preview: resolveWall(wall, targetZone) → banner if gap/overlap
  → live warnings: warningsForInstant(...) vs target's quiet hours + 11pm–6am
  → Send
      → scheduleRepository.createItem(...)
          → resolveWallTimeToUtc(wall, targetZone)   ← the actual resolution
          → add {targetUid, createdByUid, groupId, title, note?, localWallTime,
                 timezone, scheduledInstantUtc, status: 'pending', timestamps}
              rules: creator must hold an ACTIVE grant AND status must be 'pending'
                     (self-planning is the only path allowed to write 'approved')
      → notify(event: created, ...)  → Worker → FCM → target's device
  → on the target's device: allItemsAsTargetProvider snapshot fires
      → pending count badge increments, card appears in the approvals queue
```

The DST resolver (`tz_resolver.dart`) is the sharpest piece of logic in the
codebase. It labels the wall-clock fields as if they were UTC, shifts by the two
zone offsets bracketing the moment (±24h), and calls a candidate *real* only if
the zone's actual offset at that instant equals the offset used to compute it.
Zero real candidates means a spring-forward gap (push forward); two distinct ones
mean a fall-back overlap (take the first). It is the only pure-logic module with
dedicated tests, including a southern-hemisphere case.

The item stores **three** representations — `localWallTime` (a string), `timezone`,
and `scheduledInstantUtc` — and the UTC instant is documented as the source of
truth. This is a snapshot model: if the target later moves timezone, existing
items do not move. That was a decision, not an oversight.

### Flow 3 — Approve (the consent gate)

```
PendingApprovalsScreen: Approve
  → scheduleRepository.approve(targetUid, itemId)
      → merge-write {status: 'approved', decidedAt, updatedAt}
        rules: target may update their own items without restriction
  → notify(event: decided, ...)
      → Worker: re-reads the item, sees status == 'approved',
        derives subtype, checks notifiedDecided != 'approved',
        checks grant still active, fetches planner's tokens, sends,
        stamps notifiedDecided = 'approved'
  → target's device: myItemsAsTargetProvider fires → card moves from the
        approvals queue into My Schedule with Done/Skip buttons
  → planner's device: myItemsAsPlannerProvider fires → badge flips to "Approved"
        AND a push arrives (in-app SnackBar if foregrounded, tray if not)
```

Note the belt-and-braces: the planner's UI updates from the **Firestore listener**
regardless of whether the push lands. Push is purely additive. A push failure is
recorded to Crashlytics and swallowed — never retried, never blocking.

### Flow 4 — Mark done (the loop closing)

Identical in shape to Flow 3 with `markDone` writing an `outcome` sub-map rather
than a status, `event: outcome`, and the notification flowing target → planner.
Two details worth naming:

- `status` stays `approved`; the outcome is layered on top. Approval and completion
  are kept as two separate facts, which is the whole accountability signal.
- The client **skips the push entirely** for self-planned items (`_isSelfPlanned`),
  and the Worker independently skips them too. Belt and braces again.

### Flow 5 — Archive (a write that touches nobody else)

```
OutcomeScreen / PlannerActivityScreen: ⋮ → Archive
  → archiveRepository.archive(uid, itemId)
      → merge-write users/{uid}/state/archived  { items: { itemId: serverTimestamp } }
        rules: owner-only — structurally impossible to hide something in
               someone else's view
  → archivedIdsStreamProvider fires (error-proofed: any failure → empty set)
  → archivedIdsProvider ({} on loading or error)
  → myItemsAsTarget / myItemsAsPlanner recompute → the row disappears
  → archivedItemsProvider recomputes → the row appears on the Archived screen
  → a SnackBar with Undo calls unarchive()
```

Plus a second, *write-free* hide route: `ScheduleItem.isAutoArchived` is a pure
getter over `status`, so rejected and withdrawn items vanish from feeds with no
storage at all. Both routes converge in one `_visible()` function, so no screen
can forget to apply them.

## 3.3 Where the business logic actually lives

Honestly: **most of it lives in widget files**, and the exceptions are the parts
someone decided to test.

| Logic | Where it lives | Fair? |
|---|---|---|
| DST wall-time resolution | `core/timezone/tz_resolver.dart` — pure functions | ✅ Correct. Tested. |
| Quiet-hours / late-night windows | `core/timezone/quiet_hours.dart` — pure functions | ✅ Correct. **Untested.** |
| App-lock state machine | `applock/application/app_lock_controller.dart` | ✅ Correct. Well tested. |
| Archive visibility rules | `scheduling/application/schedule_providers.dart` + a getter on the model | ✅ Correct. Tested. |
| Status → colour/label/icon | `core/theme/status_style.dart` | ✅ Correct. One mapping, tested. |
| Firestore reads/writes | the five `*_repository.dart` files | ✅ Correct. |
| **Push policy** (recipients, dedup, grant checks, cleanup) | `worker/src/notify.js` | ✅ Correct — and deliberately isolated so it can move to a Cloud Function. **Untested.** |
| **When to fire a push** | scattered across 5 screens | ❌ Every screen remembers to call `notify()` after its write. Miss one and a whole event type silently stops working, with no test to catch it. |
| Self-planned vs planner-planned branching | `schedule_builder_screen.dart` and `outcome_screen.dart` | ❌ Duplicated policy in widgets. |
| Pending-item counting | `home_shell.dart` and `outcome_screen.dart` | ❌ Two copies of the same filter. |
| Which items each feed shows | inline `.where()` in 4 screens | ❌ Filter logic scattered. |
| Reject/skip/withdraw confirmation + reason capture | inline dialogs in 3 screens | ❌ Three near-identical dialogs. |

The write-then-notify pairing is the sharpest edge. It appears six times
(`_approve`, `_reject`, `_markDone`, `_skip`, `_withdraw`, and the builder's
`_save`), always as "await the repository, then await the notifier". Nothing
enforces the pairing; nothing tests it. It belongs in the repository or in a thin
application-service layer.

---

# 4. HEALTH CHECK

**Baseline, verified now:** `flutter analyze` → *No issues found*.
`flutter test` → **66/66 passing** in ~2s.

## 4.1 Security-rules problems (the most serious findings)

**(a) Every signed-in user can enumerate every user in the system.**
`firestore.rules`: `match /users/{uid} { allow read: if signedIn(); }`. In
Firestore, an unconditional collection-level read permits *list* queries, not just
`get`s by id. Anyone with a Google account can therefore dump every user document:
display name, avatar URL, home timezone, **and quiet-hours window** — i.e. when
each user is asleep. The rules file frames this as a deferred "share-a-group
scoping" hardening; that framing undersells it. It is a whole-database leak of
personal data, not a scoping nicety.

**(b) Same for groups.** `match /groups/{groupId} { allow read: if signedIn(); }`
permits listing every group document — names, `memberUids`, and **`joinCode`**.
The invite-code mechanism assumes codes are secret; they are readable in bulk by
anyone signed in. The comment explains the rule exists so join-by-code can look a
group up, which is true — but that only requires a `where('joinCode', ==)` query,
not an unbounded read.

**(c) The target can silently suppress the planner's notification.** The item
update rule is `request.auth.uid == targetUid` with **no field restrictions**.
The Worker's dedup guard reads `notifiedOutcome`/`notifiedDecided` off the *item
document*. A target can pre-write `notifiedOutcome: 'done'` and the Worker will
answer `already-notified` and send nothing. In an accountability app, that is the
one thing the design must not allow. The same unrestricted rule also lets a
target rewrite `title`, `scheduledInstantUtc`, or `createdByUid` after the fact.

**(d) `lib/firebase_options.dart` is `.gitignore`d.** Defensible for key hygiene,
but it means a fresh clone does not compile until someone runs
`flutterfire configure`, and nothing in `README.md` says so.

## 4.2 Duplicated logic

- **`_reasonLine()` is duplicated verbatim.** `planner_activity_screen.dart:188-205`
  and `archived_screen.dart:135-150` contain the same `switch` over the same two
  patterns producing the same widgets. A comment in the first even admits its
  rejected-item branch is unreachable there.
- **Pending count, twice.** `home_shell.dart:44-49` and `outcome_screen.dart:29-32`
  both filter `myItemsAsTargetProvider` for `status == pending` and count it.
- **"Reason dialog then act", three times.** `_reject` (approvals), `_skip`
  (outcomes) and the withdraw dialog (activity) are structurally identical:
  build a `TextEditingController`, `showDialog<bool>`, act on `true`.
- **Profile form, twice.** `CompleteProfileScreen` and `ProfileEditScreen` share
  name field + timezone button + save + error rendering, diverging only in
  quiet hours and the app-lock tile.
- **`TextEditingController` leaks.** Every one of those dialogs creates a
  controller inside a method and never disposes it (`groups_screen.dart:63,95`,
  `pending_approvals_screen.dart:123`, `outcome_screen.dart:164`). Small, but
  it's five instances of the same mistake.
- **The `writeThenNotify` pairing** — see §3.3.

## 4.3 Dead code and unused things

- **`cupertino_icons`** — unused dependency.
- **`ScheduleItemStatus.cancelled`** — no code path ever writes it. The model's
  own comment calls it "a dead state". It still costs a `status_style` branch, an
  icon constant, and a case in the archive rule.
- **`NoopEventNotifier`** (`outcome_notifier.dart:39-48`) — never instantiated.
  Deliberate: it's the pre-built swap for a future Cloud Function migration. Fine,
  but it *is* unreferenced code.
- **`Motion`** (`app_tokens.dart:62-66`) — `fast`, `normal`, `curve`: zero
  references anywhere in `lib/` or `test/`.
- **`Sizes.listIcon` and `Sizes.appBarIcon`** — declared, documented, never used.
- **`StatusBadge`'s default constructor** — only the two named constructors
  (`.status`, `.outcome`) are ever used.
- **`archivedIdsStreamProvider`** — exposed "so a screen that genuinely wants the
  load state (none today) could have it". Only ever read by `archivedIdsProvider`
  and one `ref.invalidate`.
- **`DevMenuScreen`'s header comment** is stale — it demands removal before
  release, but the route is already `kDebugMode`-gated and tree-shaken.
- **`firestore-debug.log`** (58 KB) sits in the repo root. It is `.gitignore`d and
  untracked, so it's local clutter only — but it's emulator output nobody needs.

## 4.4 Fragile / silently wrong

- **`ScheduleItem.fromDoc` invents data.** Line 132-133:
  `scheduledInstantUtc: (d['scheduledInstantUtc'] as Timestamp?)?.toDate() ?? DateTime.now().toUtc()`.
  A missing or malformed timestamp becomes "now", so a corrupt item renders as
  scheduled for this instant instead of failing visibly. Every other field
  defaults to `''`, which is at least obviously empty; this one is plausibly wrong.
- **`joinByCode` returns a stale group.** `group_repository.dart:85` returns
  `Group.fromDoc(doc)` built from the snapshot taken *before* the `arrayUnion`,
  so `memberUids` does not include the joiner. Only the group name is used at the
  call site today, so it's latent rather than live.
- **No query limits anywhere.** `watchItemsForTarget` streams *every item the user
  has ever had*; `watchItemsByPlanner` streams every item they ever created;
  `watchMyGroups`, `watchMembers`, `watchGrants` are all unbounded. Filtering and
  sorting happen client-side, in `build()`, on every rebuild. At two users this is
  free. At a year of daily items it is a growing cold-start cost and a growing
  Firestore bill, and there is no pagination seam to add later without touching
  every screen.
- **`GoRouterRefreshStream` never gets disposed.** It's constructed inline in
  `routerProvider` and no `ref.onDispose` cancels it. Harmless in a single-router
  app that lives for the process, but it is a leak by construction.
- **Side effects in `build()`** — `app.dart:180`, `profile_edit_screen.dart:96`.
- **The invite code has no uniqueness check.** `_generateJoinCode()` picks 6 chars
  from a 32-char alphabet (~10⁹ combinations) and never checks for a collision.
  `joinByCode` does `.limit(1)`, so a collision silently sends the joiner to
  whichever group Firestore returns first. Very unlikely; completely unhandled.

## 4.5 Broken: the app lock's screenshot/recents protection does nothing

`AppLockTile`'s subtitle promises the user: *"Also hides the app from the recents
switcher and blocks screenshots."*

The implementation (`secure_window.dart`) invokes `MethodChannel('time_app/secure_window')`.
**There is no Kotlin handler for that channel.** `MainActivity.kt` is the bare
5-line default; nothing anywhere registers the channel. Every call throws
`MissingPluginException`, which is caught and logged as
`'secure_window: no platform handler (expected off Android)'` — a message that
reads as benign on the one platform where it is a defect.

So: screenshots are not blocked, the recents thumbnail is not blanked, and the UI
tells the user otherwise. Worse, the tests reinforce the illusion — `app_lock_test.dart`
asserts `start()` "re-applies FLAG_SECURE" against a *fake* `SecureWindow`, so the
suite proves the Dart side calls a method that lands nowhere. This is the single
most consequential half-finished thing in the repo: it is a privacy claim the app
does not honour.

## 4.6 Broken: notification taps strand the user

`app.dart:155-173` routes a tap with `router.go(...)`, which replaces the
navigation stack. `/activity` and `/approvals` are registered as bare top-level
routes, so the user lands on a screen with **no bottom nav bar and no back
button**. `PlannerActivityScreen`'s only exits are its FAB (Schedule Builder) and
the account menu (Edit profile / Archived / Sign out) — none of which return to
the shell. `PendingApprovalsScreen` has no exit at all. The user must kill the app.

This is a direct consequence of the same three screens being both tabs and routes.
The fix is a `StatefulShellRoute` (or `go` to `/` plus a tab-index parameter), not
a patch to `_handleTap`.

## 4.7 Files over 300 lines

Only one production file:

- **`schedule_builder_screen.dart` (344)** — holds target selection, form state
  for six fields, two date/time pickers, DST preview, DST warning, quiet-hours
  warning, the create call, the notify call, snackbar feedback, and form reset.
  It is readable, but it is doing the work of a form widget, a view-model, and a
  small policy layer. `_warningBanner` and `_dstBanner` each independently re-run
  `resolveWallTimeToUtc` on every rebuild, as does `_previewLocal` — three
  resolutions of the same value per frame.

Tests: `app_lock_test.dart` (587) and `archive_isolation_test.dart` (321) both
exceed 300, which is fine for table-driven test files.

Everything else in `lib/` is under 300, most under 200. Genuinely good.

## 4.8 Inconsistencies

- **Two state idioms** — Riverpod providers everywhere, `ChangeNotifier` +
  `ListenableBuilder` in `applock`.
- **Two "get the current uid" idioms** — `currentUidProvider` (the clean seam,
  used by archive and schedule providers) *and*
  `ref.watch(authStateProvider).value?.uid` / `ref.read(authRepositoryProvider).currentUser`
  (used by groups, group detail, and both profile screens). The first exists
  specifically to make things testable without Firebase; half the app ignores it.
- **Error handling by screen, three ways** — `AsyncView` with a real retry (list
  screens), a local `String? _error` rendered in red (auth, profile), and a
  `SnackBar` with the raw exception (schedule builder, groups). Users are shown
  raw `Exception.toString()` output in several places.
- **The dev menu's route list is stale** — it links to screens that are now tabs,
  so tapping "Groups & Invite" from it pushes a nav-less `GroupsScreen`, the same
  dead-end as §4.6.
- **`README.md` is still the unmodified Flutter template.** For a project with
  3,364 lines of design documentation, the one file a newcomer opens first says
  "A new Flutter project."

## 4.9 Test coverage

**5 files, 1,354 lines, 66 tests, all passing.** Coverage is deep in a few places
and absent everywhere else.

| Area | Coverage |
|---|---|
| App lock (grace window, task-kill, refusal paths, gate placement) | **Excellent** — 587 lines, including widget tests proving dialogs and pushed routes sit behind the lock. |
| Archive isolation + the terminal-state split | **Excellent** — 321 lines, proves a broken archive can't take down the schedule. |
| Theme tokens, contrast ratios, status doctrine | **Good** — 194 lines, including programmatic WCAG-AA checks. |
| UI-rules lint (bans `Colors.*`, inline `fontSize`, literal spacing/radius/elevation, raw `Icons.*`) | **Good** — 190 lines of source-scanning. A rule that lives only in a doc isn't a rule. |
| DST resolver | **Good** — 62 lines, 5 cases including southern hemisphere. |
| **Repositories** (all 5) | **Zero.** No fake Firestore, no `mockito`. |
| **Every screen except the lock** | **Zero.** No widget tests for approve, reject, done, skip, withdraw, create. |
| **The Worker** (all notification policy) | **Zero.** No JS test runner, no `package.json`. |
| **Quiet-hours math** | **Zero**, despite being pure functions with a wrap-past-midnight edge case. |
| **`write → notify` pairing** | **Zero.** |
| **Firestore rules** | **Zero** automated. Tested by hand against a live project, per the docs. |

The pattern is clear: the two features built most recently (app lock, archive)
are tested thoroughly and thoughtfully; the core loop that shipped earlier is
tested not at all. If the core loop regresses, nothing catches it.

## 4.10 Half-finished / not-yet-real

- **iOS.** No Firebase config, no `GoogleService-Info.plist`, `firebase_options`
  throws for iOS, no Podfile. The `CFBundleLocalizations` work in `Info.plist` is
  written but unverifiable.
- **`FLAG_SECURE`** — §4.5.
- **Release signing** — debug keystore, `TODO` still in `build.gradle.kts`.
- **Alarms.** The app's name and premise are about alarms firing. There are none,
  by explicit policy — `OutcomeScreen` is a checklist you visit manually. This is
  a deliberately parked layer, not an oversight, but it means the product's core
  claim is not yet exercised by any code.
- **`ScheduleItem` has no duration field**, which the docs flag as a blocker for
  the planned goal/effort tracking.
- **`archivedIdsStreamProvider`'s load state** is exposed for a consumer that
  doesn't exist.
- **The `NoopEventNotifier` swap** is pre-built for a migration that hasn't happened.

---

## 5. What I'd fix, in order

1. **Scope the `users` and `groups` read rules.** Right now a signed-in stranger
   can enumerate every user's name, timezone and sleep schedule, and every group's
   invite code. Nothing else on this list is close.
2. **Constrain the target's item-update rule** to the fields they legitimately
   set. As written, a target can suppress the notification that closes the
   accountability loop — which defeats the product.
3. **Write the `secure_window` Kotlin handler**, or delete the sentence in the UI
   that promises what it doesn't do. Shipping a false privacy claim is worse than
   shipping no feature.
4. **Fix notification-tap navigation** (`StatefulShellRoute`, or `go('/')` plus a
   tab index). Today a tapped notification requires killing the app.
5. **Move `write → notify` into the repository.** Six call sites remembering to
   pair two awaits is one forgotten paste away from a silent event-type outage.
6. **Add widget tests for the core loop** — approve, reject, done, skip, withdraw.
   The newest features are the best tested and the oldest, most important ones are
   untested; that is exactly backwards.
7. **Put `limit()` on the item queries** before the data grows.
8. Housekeeping: drop `cupertino_icons`, delete `Motion`/`Sizes.listIcon`/
   `Sizes.appBarIcon`/`ScheduleItemStatus.cancelled`, extract the duplicated
   `_reasonLine` and the pending-count filter, dispose the dialog controllers,
   and write a real `README.md`.

---

## 6. Server-side security fixes applied (2026-08-10)

Items 1 and 2 of §5 are done. Scope was deliberately **server-only** —
`firestore.rules` plus new tests; **no Dart in `lib/` was touched**, because a
client rewrite is being evaluated. `flutter analyze` → *No issues found*;
`flutter test` → **66/66**, both unchanged.

### What changed in `firestore.rules`

**§4.1(a) — user enumeration. Downgraded to a stated residual.**
`users/{uid}` splits `read` into `allow get: if signedIn()` and
`allow list: if false`. No client path ever queried this collection (every read
is `_users.doc(uid)`), so denying `list` costs nothing and ends the bulk dump of
names, home timezones and quiet-hours windows.

*Residual, accepted knowingly:* a caller who **already knows a uid** can still
`get` that profile. Strict "only users who share a group" is not expressible in
Firestore rules — rules cannot run queries, so it needs a denormalized `groupIds`
on every user doc (plus a backfill, plus one extra billed read per profile read),
and that is a client change. What holds the line meanwhile is that no uid leaks
to a stranger any more: group docs and rosters are member-gated, and both
collection-group rules were already resource-scoped to the caller.

**§4.1(b) — group / invite-code enumeration. Closed, with an outstanding client
half.** `groups/{groupId}` is now members-only for both forms:
`get` and `list` each require `request.auth.uid in resource.data.memberUids`.
That makes `where('memberUids', array-contains: me)` the only satisfiable query
— exactly `watchMyGroups` — and takes `joinCode` off the table for non-members.

**§4.1(c) — notification suppression. Closed on both doors.** Item writes are now
field-scoped rather than document-scoped:

| Role | May write |
|---|---|
| creator (`create`) | `targetUid`, `createdByUid`, `groupId`, `title`, `note`, `localWallTime`, `timezone`, `scheduledInstantUtc`, `status`, `decidedAt`, `createdAt`, `updatedAt` |
| target (`update`) | `status`, `decidedAt`, `rejectionReason`, `outcome`, `updatedAt` — and a `status` change must be `pending` → `approved`\|`rejected` |
| planner (`update`) | `status`, `withdrawnAt`, `updatedAt` (withdraw a still-pending item — unchanged) |
| **nobody** | `notifiedCreated`, `notifiedDecided`, `notifiedOutcome`, `notifiedWithdrawn`, `notifiedAt` |

The `create` half was a hole the original finding did not name: the old rule
constrained `status` but not the key set, so a planner could create an item
already stamped `notifiedCreated: true` and its `created` push would never fire.
Field scoping also stops a target rewriting `title`, `scheduledInstantUtc` or
`createdByUid` after the fact, reviving a decided item, or faking a withdrawal.

**New: `joinCodes/{code}`.** An invite-code → `groupId` lookup, `get`-only with
`list` denied, created by the group's owner and immutable. This exists so
join-by-code needs no read on the group doc. Brute-forcing 6 chars from a 32-char
alphabet is now ~10⁹ single gets instead of one query, and a resolved code yields
only a group id — which grants nothing, since the doc, roster and grants are all
member-gated. The client now uses it (§6.1).

### The Worker: no change, by analysis

`worker/src/` is untouched. `firestore-rest.js` authenticates with the
service-account token from `google-auth.js`, and service-account access bypasses
security rules entirely — so `notify.js`'s dedup stamp keeps working unchanged
while every client path to those fields is now closed. The requirement that
`notified*` be writable only by the Worker's identity is met by the rules alone.

*Considered and rejected:* moving the dedup stamp off the item into a server-only
`notifications/{…}` doc. Better defence-in-depth — a future rules regression
could not re-open the hole — but it rewrites the guard and the stamp for a hole
the rules now close. Left as an open finding rather than done silently.

### Tests

New `firestore-tests/` at the repo root: a Node harness
(`@firebase/rules-unit-testing` + `firebase-tools`) running `rules.test.mjs`
against the Firestore emulator via `npm test`. **38 tests, all passing.** It is
outside `test/` so `flutter test` never walks `node_modules`.

Every denial case is paired with the legitimate operation it must not break, so a
rules file that denied everything would fail half the suite. This closes the
"**Firestore rules — zero automated**" row in §4.9.

### Client impact — exactly one path broke, and it is now fixed

**`GroupRepository.joinByCode` resolved codes with `where('joinCode', '==',
CODE)`** — a `list` on `groups` by a non-member, precisely the operation being
closed. There is no rules-only way to keep it: rules cannot see a query's
where-clauses, so any rule permissive enough to pass it also permits enumerating
the collection. That was the deliberate trade, and §6.1 pays it off.

Everything else was checked field-by-field against the new whitelists and is
unaffected: `watchMyGroups`, `GroupDetailScreen` (it reads from
`myGroupsProvider`, never a direct group get), `watchMembers`, `watchGrants`,
`watchTargetsFor`, every `profileByUidProvider` read, `createItem`, `approve`,
`reject`, `markDone`, `markSkipped`, `withdraw`, the archive state doc, FCM
tokens, and both collection-group queries.

## 6.1 Join-by-code moved onto the lookup collection (2026-08-10)

The client half of §4.1(b), plus its migration. Confined to **one Dart file**,
`lib/features/groups/data/group_repository.dart`:

- **`createGroup`** writes `joinCodes/{CODE} = {groupId}` after the group doc
  exists (the rule checks the caller owns that group, so the order is forced).
- **`joinByCode`** `get`s `joinCodes/{CODE}` → `groupId` → the existing self-join
  update → the member doc → **re-reads the group as a member**. The sequence
  works because the self-join update deliberately needs no read permission.

Two bugs die with it. **§4.4's stale `joinByCode` return is fixed** — the
returned `Group` now comes from a snapshot taken *after* the join, so its
`memberUids` includes the joiner. And **§4.4's unchecked invite-code collision
is now loud**: `joinCodes` docs are immutable under the rules, so a duplicate
code fails at `createGroup` instead of silently routing a joiner into whichever
group Firestore returned first.

**Migration — `scripts/backfill-join-codes.mjs`** (new, zero dependencies).
Writes the lookup doc for every pre-existing group. It runs as the **service
account**, which is not a convenience but a necessity: under the old rules
`joinCodes` had no match and fell through to deny, and under the new rules no
user may list `groups`. A service-account token bypasses rules on both the read
and the write, which also makes the script **rules-independent** — it can run
before or after the rules deploy. Dry-run by default; `--apply` writes. It only
ever creates, uses a `currentDocument.exists=false` precondition, skips codes
already pointing at the right group (so re-running is a no-op), and **never
overwrites a code pointing elsewhere** — that is reported as a collision and
left alone.

Verified against the emulator across all four branches (create, idempotent
re-run, collision left untouched, group with no code skipped).

### Still open

- **§4.1(a) residual** — targeted `get` of a profile by known uid. Needs the
  `groupIds` denormalization + backfill described above.
- **Dedup-stamp relocation** — the defence-in-depth option rejected above.
- **§4.1(d)** `firebase_options.dart` gitignored with no README note,
  **§4.5** the `FLAG_SECURE` no-op, **§4.6** notification-tap dead end — all
  untouched, all still open. §4.5 remains the most consequential: it is a privacy
  claim the app does not honour.
- **Nothing here is deployed.** Rules, client and backfill all sit in the working
  tree; see the deploy order below.

### Deploying — order matters

The rules and the client must move as a pair: the old client's `createGroup`
cannot write `joinCodes` under the old rules, and the new client's `createGroup`
requires the new rules.

1. `node scripts/backfill-join-codes.mjs --key sa.json` — dry run, review.
2. Same with `--apply`. Rules-independent, so it is safe before step 3.
3. `firebase deploy --only firestore:rules`, then **read the deployed source in
   the console** and confirm `users` `list: if false`, the members-only `groups`
   rules and the item field whitelists are actually live. This project has
   shipped a 6-day-stale ruleset before (`CLAUDE.md`), so verifying the deployed
   source rather than the local file is the standing practice. Join-by-code
   breaks for anyone still on the old client from this moment.
4. Install the new client on both devices.
5. Re-run the backfill with `--apply` — idempotent, and it catches any group an
   old client created during the window between 2 and 4.
