# WORK_PLAN.md

Written 2026-08-13 against `feat/notification-events` (`37c9856`, working tree
clean except for `PORT_PLAN.md` / `PORT_REVIEW.md`, both untracked).

**Decision taken as given: we stay on Flutter.** Nothing below assumes a port.

Every claim here was re-checked against the code rather than trusted from
`ARCHITECTURE.md`, `PORT_PLAN.md` or `PORT_REVIEW.md`. Where a document and the
tree disagree, the tree is cited. Items already closed by ARCHITECTURE.md §6 and
§6.1 are excluded from §1 — but §6.1 itself ends with *"Nothing here is
deployed,"* and that is tracked below as **D20**, because written-but-unshipped
is not fixed.

**Baseline, measured now:** `flutter analyze` → *No issues found* (4.8s).
`flutter test` → **66/66 passing**. `flutter pub outdated` → **25 upgradable but
locked**, **4 constrained below a resolvable version** (ARCHITECTURE.md §1.2's
"41" is stale).

---

## 0. Three findings that change the shape of the plan

Read these first; they reorder everything downstream.

### 0.1 The alarm premise was retired three weeks before PORT_REVIEW.md was written

`DECISIONS.md:881` — **"Product decision: reminder / accountability app, NOT an
alarm app (decided 2026-07-23)"** — says, verbatim: *"This is the load-bearing
decision. It supersedes every 'alarm' framing earlier in this file… Push
notifications and local reminders are the deliberate **ceiling on both
platforms** — not a degraded fallback we're apologising for. There is no 'true
alarm' tier above them."*

It explicitly withdraws the Android-only conclusion, drops the need for
`USE_EXACT_ALARM` / `SCHEDULE_EXACT_ALARM`, and puts iOS back in scope as a
first-class v1 target.

Two documents still contradict it:

- **CLAUDE.md** ("Parked to the alarm layer … all alarm firing (Xiaomi spike —
  the whole premise is empirically unverified), voice-mode alarms …").
- **PORT_REVIEW.md §1**, whose single strongest argument for staying on Flutter
  is *"the product's namesake feature is unbuilt, and you would be porting away
  from the framework that is better at it."*

That argument rests on a premise the project retired on 2026-07-23. The
*conclusion* (stay on Flutter) survives on the other evidence — cost ratio,
comment loss, the iOS diagnosis, the verification-discipline diagnosis — but its
headline justification does not. This matters for §2 below: **there is no "alarm
feature" to build. There is a reminder layer**, and it is a different, smaller,
better-understood job.

### 0.2 The one-day iOS experiment PORT_REVIEW.md recommends is not available to you

Both PORT_PLAN.md §5.4 and PORT_REVIEW.md §5 open with *"(1 day) Configure
Firebase for iOS in the existing Flutter app. Launch it. This is the experiment;
do not skip it."* Neither document knew you have no Mac and no iPhone.

You can do the **configuration** half from Linux. You cannot do the **launch**
half at all — CocoaPods, `pod install`, the Xcode signing/capabilities pass and
any run (simulator or device) all require macOS. See §3 for the exact split.
Consequence: iOS drops down the order, and the first iOS item is a *decision*
(CI service vs. shelve), not a build.

### 0.3 The rules hardening is committed but there is no record of it being deployed

`ARCHITECTURE.md:993` states plainly that rules, client and backfill all sit in
the working tree undeployed, and the deploy order at `:996-1012` warns the rules
and the client **must move as a pair**. Nothing since records a deploy.

This is not cosmetic. `GroupRepository.createGroup` now writes
`joinCodes/{CODE}` (`group_repository.dart:49`), and under the *old* rules
`joinCodes` has no match block and falls through to deny — so **the client
currently in the tree cannot create a group against un-updated rules.** Until
the deploy is confirmed, the app on the devices is either running old client
code (with three live security holes) or new client code that is broken.

Verify this before anything else. It is item 1 in §4.

---

# 1. CONSOLIDATED DEFECT LIST

Deduplicated across ARCHITECTURE.md §4/§5, PORT_PLAN.md §3.5/§6.2,
PORT_REVIEW.md and CLAUDE.md's open list. Effort is *my* implementation time;
add your review on top. "User-facing" means a real person would notice or be
misled.

## 1.1 Blocking / high severity

| # | Defect | Location | Why it matters | Effort | User-facing |
|---|---|---|---|---|---|
| **D20** | **Rules + client hardening written, committed, not deployed** | `firestore.rules`; `lib/features/groups/data/group_repository.dart:49,151`; `scripts/backfill-join-codes.mjs`; deploy order at `ARCHITECTURE.md:996` | Three findings (user enumeration, group/joinCode enumeration, notification suppression) are closed in the tree and possibly still open in the real project. Worse, the two halves are coupled: the tree's `createGroup` writes `joinCodes/{CODE}`, which old rules deny — so group creation is broken until rules land. Deploying breaks join-by-code for anyone still on an old client, so device installs must follow immediately. | **1–2h** (mostly verification + a backfill run) | Yes — group create/join |
| **D1** | **`FLAG_SECURE` is a no-op and the UI claims otherwise** | `lib/features/applock/data/secure_window.dart:22` declares `MethodChannel('time_app/secure_window')`; `android/app/src/main/kotlin/.../MainActivity.kt` is 5 lines with no handler (grep confirms the channel name appears only in Dart + one test import); the promise is `app_lock_tile.dart:83-86` — *"Also hides the app from the recents switcher and blocks screenshots."* | A privacy claim the app does not honour. Every call throws `MissingPluginException`, caught and logged as *"expected off Android"* — a message that reads benign on the one platform where it is a defect. Compounded: `test/app_lock_test.dart` asserts `start()` re-applies FLAG_SECURE against a **fake**, so the suite makes a broken feature look covered. | **1–2h** (Kotlin handler) or **15 min** (honest copy) — plus retiring the fake-based assertions | **Yes** |
| **D2** | **A notification tap strands the user with no way out** | `lib/app.dart:155-172` (`_handleTap` calls `router.go(...)`); `lib/routing/app_router.dart` registers `/groups`, `/outcome`, `/activity` as flat top-level routes; `home_shell.dart:33-37` renders the same three screens as tabs | `go()` replaces the whole stack, so the user lands on a bare `PendingApprovalsScreen` or `PlannerActivityScreen` — no bottom nav, no back button. `PendingApprovalsScreen` has no exit at all. Only killing the app recovers. Root cause is the tab/route duplication, not `_handleTap`. `dev_menu_screen.dart:27-32` walks into the same trap in debug. | **3–4h** (`StatefulShellRoute`) | **Yes, severe** |

## 1.2 Correctness and architecture

| # | Defect | Location | Why it matters | Effort | User-facing |
|---|---|---|---|---|---|
| **D3** | `write → notify` is a hand-repeated pairing with nothing enforcing it | Six sites, all in `presentation/`: `schedule_builder_screen.dart:99`, `pending_approvals_screen.dart:115` and `:147`, `outcome_screen.dart:156` and `:189`, `planner_activity_screen.dart:169` | Correct in all six today. One forgotten paste silently kills an entire event type, and the only symptom is a push that never arrives. Zero tests cover the pairing. The self-planned skip is duplicated too (`outcome_screen.dart:78`, re-branched in the builder). | **1 day** incl. six pairing tests | Latent, then yes |
| **D4** | `ScheduleItem.fromDoc` fabricates a timestamp | `lib/features/scheduling/domain/schedule_item.dart:133` — `?? DateTime.now().toUtc()` | A missing/malformed `scheduledInstantUtc` renders as *scheduled for right now*, which looks entirely plausible. Every other field defaults to `''`, which at least looks empty. Should drop-and-report, or render an explicit "unreadable item" card — never a made-up time. | **1h** | Yes, when it fires |
| **D5** | No `limit()` and no server-side `orderBy` on any query | Zero `limit(` in `lib/features/*/data/` (verified). `watchItemsForTarget`, `watchItemsByPlanner`, `watchMyGroups`, `watchMembers`, `watchGrants` are all unbounded; sorting and filtering happen in `build()` | Free at two users; a growing cold-start cost and Firestore bill at a year of daily items, with **no pagination seam** — adding one later touches every screen. Adding `orderBy` to the `collectionGroup('items')` query will need a composite index in `firestore.indexes.json`. | **2h** for the seam | Eventually |
| **D13** | Two idioms for "get the current uid" | `currentUidProvider` (used by archive + schedule providers) vs. `ref.watch(authStateProvider).value?.uid` / `authRepository.currentUser` (groups, group detail, both profile screens, schedule builder) | The first exists specifically to make things testable without Firebase; half the app bypasses it, which is exactly why the repositories have no tests. | **1–2h** | No |
| **D10** | Side effects inside `build()` | `lib/app.dart:182` (`registerForUser` during build); `profile_edit_screen.dart:96-110` (assigns controllers and flips `_initialised` during build) | Both are idempotent and commented, so harmless today — and both are a trap for the next person. | **1h** | No |
| **D11** | `GoRouterRefreshStream` is never disposed | Constructed inline in `routerProvider` (`app_router.dart`); the class has a `dispose()` (`go_router_refresh_stream.dart:16`) that nothing calls — no `ref.onDispose` | A leak by construction. Harmless in a single-router app that lives for the process; wrong as a pattern. | **5 min** | No |

## 1.3 Duplication and consistency

| # | Defect | Location | Why it matters | Effort | User-facing |
|---|---|---|---|---|---|
| **D6** | Four `TextEditingController`s created in a method and never disposed | `groups_screen.dart:63` and `:95`, `pending_approvals_screen.dart:123`, `outcome_screen.dart:164`. (The other four in `lib/` are `State` fields and *are* disposed — PORT_PLAN §3.5(d) is right that it's four, not ARCHITECTURE.md §4.2's five.) | Same mistake four times. Dies for free with D7. | **15 min** | No |
| **D7** | Three structurally identical reason dialogs; `_reasonLine()` duplicated verbatim | Dialogs at the four sites in D6 (reject / skip / withdraw). `_reasonLine` at `planner_activity_screen.dart:187` and `archived_screen.dart:135` | One `ReasonDialog` + one `ReasonLine` replaces three near-copies and removes the leak class entirely. | **2–3h** | No |
| **D8** | Item filters and the pending count are inlined across screens | Pending count twice: `home_shell.dart:44-48` and `outcome_screen.dart:29-31`. Filters inline at `pending_approvals_screen.dart:35`, `outcome_screen.dart:59`, `planner_activity_screen.dart:55` | Pure functions living in widgets, so they are untestable in milliseconds and drift independently. This is the cheapest large win in the repo: extracting them creates the entire Tier-1 test surface. | **2h** | No |
| **D9** | The schedule builder resolves the same wall time three times per frame | `schedule_builder_screen.dart:287`, `:308`, `:333` each independently call `resolveWall*` | Marginal perf; mostly a symptom of the largest screen (344 lines) doing view-model work. Collapsing to one memoised computation also shrinks the file. | **1h** | Barely |
| **D14** | Three error presentations; raw exception text shown to users | `AsyncView` + retry (list screens), local `String? _error` in red (auth, profile), `SnackBar` with the raw exception (schedule builder, groups) | Users see `Exception.toString()` output in several places. `AsyncView`'s 12s stuck-listener timeout is a genuinely good idea worth making universal. | **2–3h** | **Yes** |

## 1.4 Verification gaps (things that are untested, not things that are wrong)

| # | Gap | Location | Why it matters | Effort | User-facing |
|---|---|---|---|---|---|
| **D18** | Coverage is inverted, with a signature | 5 test files, 1,354 lines. App lock (587) + archive isolation (321) = 67% of it. **Zero** on: all five repositories, every screen except the lock, the `write→notify` pairing, and `core/timezone/quiet_hours.dart` — 59 lines of pure integer arithmetic with a wrap-past-midnight branch (`minuteInWindow`, `quiet_hours.dart:33-38`), the single easiest testable thing in the repo | Tests were written when the feature was *interesting*, not when the risk was high. PORT_REVIEW.md §2 ranks this the dominant problem in the project, and I agree with that read. The harness for the fix already exists (`firestore-tests/` runs the emulator via `npm test`). | **2 sessions** | No, but it gates everything |
| **D19** | The Worker has zero tests and no test runner | `worker/src/` — 664 lines, no `package.json`. `notify.js` (198 lines) holds *all* notification policy: recipient resolution, per-event dedup, grant re-checks, dead-token cleanup | The largest untested surface in the system, and the one place a bug is invisible (a push that never arrives has no symptom). | **1 day** | Latent |
| **V1** | **Backgrounded / killed-app push on HyperOS — never run** | CLAUDE.md open item 1 | The 2026-07-24 verification was *foregrounded*, which sidesteps OEM battery policy entirely. System-tray delivery to a backgrounded or process-killed app on the Redmi is unproven, and it is the same gate the reminder layer will need (`DECISIONS.md:930-935`). One test session answers both. | **1–2h** on-device | **Yes** |
| **V2** | **Rules Test 3 — grant-off negative test — never run** | CLAUDE.md open item 2 | With the grant revoked, B's item-create must be denied. I checked `firestore-tests/rules.test.mjs`: it seeds `granted: true` and asserts the *positive* case at `:451` ("ALLOWS the planner to create a pending item under an active grant"). **There is no revoked-grant denial test.** This used to be a manual device run; it is now ~20 lines in a harness that already exists. | **30 min** | No |
| **V3** | Four-event foreground retest — blocked on a second person | CLAUDE.md | All four events require `creator != target`. Expect `sent:1` per event with `wrangler tail` running. Passing it does **not** close V1. | **1h** with the friend | No |
| **V4** | Real two-timezone DST-observing loop — never run | CLAUDE.md open item 3 | The gap/overlap rule in `tz_resolver.dart` is unit-tested (5 cases, incl. southern hemisphere) but has never run on a real pair across a DST-observing zone pair. | **1h** with the friend | Yes if wrong |
| **V5** | iOS locale check | CLAUDE.md open item 4; `ios/Runner/Info.plist` carries a hand-written ~100-entry `CFBundleLocalizations` array whose own comment says *"UNTESTABLE until an iOS target is wired up"* | Blocked on §3, and specifically on hardware you do not have. | Blocked | Yes on iOS |

## 1.5 Release readiness and housekeeping

| # | Defect | Location | Why it matters | Effort | User-facing |
|---|---|---|---|---|---|
| **D12** | Release builds are signed with the debug keystore | `android/app/build.gradle.kts:33-38` — `signingConfig = signingConfigs.getByName("debug")` with the `TODO` still in place | Not shippable to Play. Also a key-custody decision (where the keystore lives, who has it) that is cheaper to make now than under release pressure. | **1h** + custody decision | Blocks release |
| **D16** | `README.md` is the unmodified Flutter template; `firebase_options.dart` is gitignored with no setup note | `README.md` (17 lines, *"A new Flutter project"*); ARCHITECTURE.md §4.1(d) | A fresh clone does not compile and nothing says so. For a project with 3,364 lines of design docs, the first file anyone opens is the template. | **1h** | No |
| **D17** | Dead code | `cupertino_icons` (`pubspec.yaml:40`, zero `Cupertino*` references); `Motion.fast/normal/curve` (`app_tokens.dart:62-66`, zero references); `Sizes.listIcon` / `Sizes.appBarIcon` (`app_tokens.dart:79-80`); `StatusBadge`'s default constructor; `DevMenuScreen`'s header comment (`dev_menu_screen.dart:17`) demanding removal that `kDebugMode` already handles | Small individually; together they are noise that makes the theme layer look bigger than it is. **Two deliberate exceptions:** `NoopEventNotifier` (`outcome_notifier.dart:39`) is the pre-built card-day swap — keep. `ScheduleItemStatus.cancelled` (`schedule_item.dart:4`) is a dead state no path writes, but production docs could theoretically carry it, so keep it in the parser and drop it from the UI switches (PORT_PLAN §3.5(k) is right). | **1h** | No |
| **D22** | Invite codes are 6 chars from a 32-char alphabet | `group_repository.dart:151` `_generateJoinCode()` | ~10⁹ single `get`s against `joinCodes` to brute-force. §6.1 made this strictly better (a resolved code yields only a group id; doc, roster and grants are all member-gated) but the surface exists. **Lengthening the code is a one-line change** — decide what happens to existing codes. Real mitigation (App Check, rate limiting) is Firebase-console work. | **15 min** + a migration call | No |
| **D21** | §4.1(a) residual — a caller who knows a uid can still `get` that profile | `firestore.rules:87-90` (`allow get: if signedIn()`) | Reads name, home timezone and **quiet-hours window** (i.e. when someone sleeps). Closing it strictly needs a denormalized `groupIds` array on every user doc + a backfill + one extra billed read per profile read — rules cannot run queries. Knowingly accepted; the mitigation is that no uid leaks to a stranger any more. | **1 day** | No |
| **D24** | Dependency drift | 25 upgradable-but-locked, 4 constrained below a resolvable version (`riverpod` 3.3.2→3.4.2, `local_auth_windows`, `objective_c`, `share_plus_platform_interface`). ARCHITECTURE.md §1.2 also flags `local_auth` being two majors behind on the Android sub-plugin | Nothing is broken. Left alone it compounds, and `intl` is pinned to `any` so `pub upgrade` can move it silently. | **1–2h** | No |
| **D25** | **Docs contradict each other on the product's premise** | `CLAUDE.md` (alarm layer parked, "the whole premise is empirically unverified") and `PORT_REVIEW.md:31-51` vs. `DECISIONS.md:881` (reminder app, decided 2026-07-23) | See §0.1. The roadmap in CLAUDE.md is steering off a retired premise. Reconciling it is 30 minutes and prevents a wasted alarm spike. | **30 min** | No |

**Explicitly *not* defects — decided and logged, don't re-litigate:** the
silent-miss push window (`DECISIONS.md:507`, accepted at N=2, fix is card-day's
Cloud Function, *do not* build a client retry queue); the dedup-stamp relocation
(considered and rejected 2026-08-10); quiet hours being warning-only
(`DECISIONS.md:675`); the timezone snapshot model (pure snapshot, no re-anchor,
`DECISIONS.md:836`); Google-only sign-in.

---

# 2. MISSING FEATURES

## 2.1 The alarm question, answered

### What exists

**Nothing that fires.** Verified by grep, not inferred:

- No `flutter_local_notifications`, no `android_alarm_manager_plus`, no `alarm`,
  no `flutter_alarmkit` in `pubspec.yaml`.
- No `zonedSchedule`, no `AlarmManager`, no scheduling call anywhere in `lib/`.
- No notification channel is created in code. The manifest's
  `high_importance_channel` id (`AndroidManifest.xml`) is an **FCM fallback
  pointer only** — no plugin ever registers it.
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` are not declared. The manifest has
  `INTERNET` and `POST_NOTIFICATIONS` and nothing else.
- `POST_NOTIFICATIONS` *is* granted at runtime, but incidentally — via
  `firebase_messaging`'s `requestPermission()` on sign-in. The permission is not
  the blocker.

What *does* exist is the **remote** half: FCM token registration, four
server-triggered push events (created / decided / outcome / withdrawn), a
foreground in-app banner, tap routing, and a white-on-transparent tray icon.
Those are notifications *about* the loop, not reminders *of* an item.

The user-facing consequence: the core loop's `→ alarms fire →` arrow is
currently *"the target remembers to open the app."* `OutcomeScreen` is a
checklist you visit manually.

### Is a scheduled local notification a substitute or a downgrade?

**Neither — it is the specified design.** This is the finding from §0.1 and it
is the direct answer to your question. `DECISIONS.md:881` (2026-07-23) decided
the product is a reminder/accountability app and that local notifications plus
push are *"the deliberate ceiling on both platforms — not a degraded fallback
we're apologising for."* The comparison to a true alarm is against a bar the
project deliberately dropped, for a stated reason: the product is *"start your
study block"*, explicitly not *"leave now for your interview."*

Against that bar, per platform (`DECISIONS.md:916-977`):

**Android — viable, with a real drift budget and an OEM prerequisite.**

- Mechanism: **WorkManager as the durable substrate**, optionally with a
  one-shot inexact `AlarmManager.set()` / `setWindow()` /
  `setAndAllowWhileIdle()` near fire time. Not `setExactAndAllowWhileIdle` —
  that needs the exact-alarm permission the product dropped.
- Drift: **minutes when the phone is in active use; tens of minutes to 1h+ in
  deep Doze** (screen off, stationary, unplugged — i.e. overnight is worst
  case). In Doze, alarms are deferred to the next maintenance window and those
  windows widen the longer the device idles. `setAndAllowWhileIdle` is
  rate-limited to ~once per 9–15 min per app; WorkManager's minimum periodic
  interval is 15 min.
- Reboot: **`AlarmManager` does not survive reboot** — the OS clears every alarm
  on shutdown. **WorkManager persists across reboot automatically** (own DB,
  reschedules on boot), so WorkManager is the durability answer and a
  `BOOT_COMPLETED` receiver is a top-up hook, not the mechanism.
- **Xiaomi/HyperOS is the gate.** Aggressive app-standby throttles or drops
  WorkManager jobs *and* blocks `BOOT_COMPLETED` unless Autostart is on and
  battery is set to "No restrictions." The OEM onboarding primer is therefore a
  **prerequisite for reminders, not just for push** — and it is the same gate as
  open item V1. One Redmi session answers both.

**iOS — viable, arguably better, with one architectural constraint.**

- Mechanism: `UNUserNotificationCenter` with `UNCalendarNotificationTrigger`.
  Same notification permission as push; no special entitlement.
- Accuracy: **fires on time.** No Doze equivalent. iOS is the *more* precise
  platform here — the inverse of Android.
- Durability: notifications are held by the **system**, not the app process, so
  they fire even if the app is never relaunched, and they survive app updates
  under the same bundle id. (Power-cycle persistence is documented less clearly
  — verify on device when iOS is wired up.)
- **The hard limit: 64 pending local notifications per app.** iOS keeps the
  soonest-firing 64 and silently discards the rest. You cannot schedule
  everything up front; you need a **rolling-window scheduler** that schedules the
  nearest N and tops up on app open and when a push arrives. This is real
  engineering, but it is a *scheduling-architecture* problem, not a reliability
  one.

**Verdict.** Scheduled local notifications are a genuine downgrade only against
a true alarm, and the product is not an alarm. On iOS they deliver essentially
full fidelity for a reminder product. On Android they deliver a reminder that
may drift by up to an hour overnight and requires the user to complete an OEM
checklist — which is a real product compromise, and one the docs already
accepted with eyes open. **The honest remaining unknown is empirical, not
architectural:** does a WorkManager-scheduled reminder actually fire on the
Redmi after a force-stop, with and without the exemptions? That is a few hours
of throwaway code (`DECISIONS.md:267-292` already specifies the spike) and it is
the only thing standing between "designed" and "known."

For completeness, the retired path: true alarms would need Android
`AlarmManager.setAlarmClock` + `USE_EXACT_ALARM` — which **Google Play restricts
to alarm-clock/calendar apps, and an accountability app likely does not
qualify** (`DECISIONS.md:1176-1183`) — or clock handoff via `ACTION_SET_ALARM`,
which cannot carry a custom sound; and on iOS, AlarmKit via `flutter_alarmkit`
(v0.4.x, iOS 26+ floor, immature). Play policy is the reason this path is closed,
and it closed before Flutter-vs-RN was ever a question.

## 2.2 Everything else the docs describe that does not exist

**Core to the product** — these are on the critical path to the loop working as
specified:

| Feature | Status | Notes |
|---|---|---|
| **The reminder layer** | Designed in detail (`DECISIONS.md:910-977`), zero code | §2.1. The single largest product gap. Parked pending explicit direction per CLAUDE.md's build-order rule. |
| **Xiaomi / OEM onboarding primer** | Designed (`DECISIONS.md:361-374`), never built | Prerequisite for *both* the reminder layer and backgrounded push. CLAUDE.md notes its placement in onboarding should be decided from V1's result. |
| **iOS as a running target** | Config absent, never launched | §3. `firebase_options.dart:28` throws `UnsupportedError` for iOS; no `GoogleService-Info.plist`; no `Podfile`. |
| **Release signing** | Debug keystore | D12. |
| **Invite by link** | Partial | `mvp-spec.md` §2 says "invite by link or username." Built: a 6-char code plus a share-sheet that shares *text*. The manifest declares only `MAIN`/`LAUNCHER` — **no intent filters, no deep links**, so a shared link cannot open the app. Small gap, easy to close, worth naming because the spec asked for it. |

**Deferred by an explicit decision** — designed, not built, and that is on
purpose:

| Feature | Status | Notes |
|---|---|---|
| **Group B — "seen" status** | Fully designed 2026-07-23, deferred 2026-07-25 | Item-level not app-level, pending-only, three states including the high-value *absent* one (`Sent 3d ago · not seen yet`), no push. **Has a hard dependency:** locale-aware *relative*-time formatting, which does not exist — `core/format/datetime_format.dart` (46 lines) exposes only `formatInstant`, `formatWallDate`, `formatTimeOfDay`, `formatMinutesOfDayLocalized`. Goals will want the same helper. |
| **Quiet-hours enforcement** | Warnings built, enforcement deferred | `quiet_hours.dart` + two warning panels in the builder are live and non-blocking, exactly as `DECISIONS.md:675` decided. Enforcement belongs to the reminder layer. |
| **Voice-mode reminders** | Parked | Note: a local notification *can* carry a bundled custom sound on both platforms, so the reminder-app decision does not kill this — it just means it is a sound choice, not a second alarm tier. |
| **Consent model rework** (toggle vs. request-driven) | Open product decision | Deferred until after the first real-pair run, deliberately — decide from how the loop *feels*. May rebuild the grant flow. |
| **Per-item category icons** | Deferred, co-designed with goals | So `ScheduleItem` migrates once, not twice. Use a stable string key, never a raw codepoint. |

**Aspirational** — real intent, but nothing to build against yet:

| Feature | Status | Notes |
|---|---|---|
| **Goal / effort tracking** | Unparked 2026-07-25, queued build item 3, not started | Needs a doctrine pass *before* code. Hard blocker confirmed in the tree: **`ScheduleItem` has no duration field** — it carries an instant, not a span — so feature-ideas.md's "log its planned duration" presumes a field that does not exist. Decide first: add `durationMinutes` (model + builder UI + create-rules whitelist + three card screens) or log effort separately. Also: if it ships charts, **write the UI-RULES progress/chart sections first** — UI-RULES.md has no data-viz section and `app_theme.dart` themes no progress indicator. Already decided and not open: unit is minutes; visibility is owner-controlled, private by default, its own share list (**not** a reuse of `plannerGrants`); items count only via an explicit `goalId` set at creation. |
| **Everything in feature-ideas.md** | Parked, do not build | Streaks, gentle stakes, templates, panic mode, Cheerleader/Buddy roles, public template sharing. |

---

# 3. iOS REALITY CHECK

`lib/firebase_options.dart:28` throws `UnsupportedError` for `TargetPlatform.iOS`.
There is no `ios/Runner/GoogleService-Info.plist`. There is no `ios/Podfile`.
`AppDelegate.swift` is the generated default. The bundle id in
`project.pbxproj:385` is `com.timeapp.timeApp`. The app has **never launched on
iOS, not once.**

The `Info.plist` has been hand-edited with a ~100-entry `CFBundleLocalizations`
array whose own comment reads *"UNTESTABLE until an iOS target is wired up."*
Careful iOS work exists here that has never been observable.

## 3.1 Every step, in order

Legend: **[Linux]** you can do now · **[MAC]** requires macOS · **[$]** requires
a paid Apple Developer Program membership · **[iPHONE]** requires a physical
device.

| # | Step | Blocked? |
|---|---|---|
| 1 | Register an iOS app in the Firebase console for project `time-app-1e1c9`, bundle id `com.timeapp.timeApp` | **[Linux]** — web console |
| 2 | `flutterfire configure` selecting iOS. Regenerates `lib/firebase_options.dart` with an `ios` block (the throw at `:28` disappears) and writes `ios/Runner/GoogleService-Info.plist` | **[Linux]** |
| 3 | Confirm the plist is actually **referenced by the Runner target** in `project.pbxproj`. `flutterfire` patches this via a Ruby `xcodeproj` script that may not run on Linux — if it didn't, the file exists on disk but is not in the bundle, and Firebase fails at runtime with no build error | **[Linux]** to check; possibly **[MAC]** to fix |
| 4 | Add `REVERSED_CLIENT_ID` (from the new plist) as a URL scheme in `ios/Runner/Info.plist` — required by `google_sign_in` on iOS | **[Linux]** |
| 5 | Add the `NSFaceIDUsageDescription` key for `local_auth`'s biometric prompt | **[Linux]** |
| 6 | Generate the `Podfile` (`flutter build ios --config-only`) and run `pod install` | **[MAC]** — CocoaPods is macOS-only in practice |
| 7 | Open `Runner.xcworkspace`; set the signing team; confirm the bundle id; add the **Push Notifications** capability and **Background Modes → Remote notifications** | **[MAC]** **[$]** |
| 8 | Enrol in the Apple Developer Program ($99/yr) | **[$]** |
| 9 | Create an APNs auth key (`.p8`) in the Apple Developer portal and upload it to Firebase → Cloud Messaging | **[$]** — web, but requires the paid account |
| 10 | Set the `aps-environment` entitlement per build configuration | **[MAC]** |
| 11 | First build + launch on a simulator. Validates: Firebase init, Google sign-in, Firestore, the whole non-push loop, **and the `CFBundleLocalizations` question (open item V5)** | **[MAC]** |
| 12 | Build + launch on a physical iPhone. The only way to validate push end to end | **[MAC]** **[$]** **[iPHONE]** |
| 13 | Decide the iOS app-lock story. `expo-screen-capture`'s Flutter equivalent does not exist and **iOS provides no API to block screenshots at all** — only to detect them. Recents blanking needs a cover view on `applicationWillResignActive`, which is new Swift you would write. `AppLockTile`'s copy (D1) has to be platform-aware or honest | **[MAC]** to implement |
| 14 | TestFlight / App Store review | **[MAC]** **[$]** |

## 3.2 What this means given no Mac and no iPhone

**Steps 1–5 are available to you today and are worth doing** — roughly an hour.
They remove the `UnsupportedError`, put the plist in the tree, and mean that the
moment a Mac exists, iOS is a build away rather than a research project. That is
real value at near-zero cost.

**Steps 6 onward are hard-blocked.** No amount of code changes that. Concretely,
you cannot compile, cannot run, cannot verify the localization work, and cannot
test push.

Your options, honestly ranked:

1. **Do steps 1–5, then shelve iOS.** Cheapest. iOS stays a configured-but-unbuilt
   target. Recommended unless someone is waiting on an iOS build.
2. **Cloud CI.** **Codemagic** has a free tier (500 build-minutes/month) with
   macOS runners and first-class Flutter support; **GitHub Actions** macOS
   runners are free for public repos and cost 10× minutes on private. Either can
   produce an iOS build without owning a Mac. This gets you *compilation*
   confidence — it proves the project builds — but a build artifact you cannot
   install is not verification.
3. **Rent a Mac hourly** (MacinCloud, MacStadium) for a one-off setup + simulator
   session. A few dollars gets you steps 6–11 and answers the localization
   question.
4. **Borrow.** If either of your two testers has an iPhone *and* a Mac is
   available even once, steps 6–12 collapse into one afternoon.

**The thing to be clear-eyed about:** PORT_REVIEW.md called the iOS launch *"the
cheapest information available to you"* and made it step 1 of its
recommendation. With your hardware, it is not cheap and it is not available.
That does not change the stay-on-Flutter conclusion — Expo needs the identical
Apple account, provisioning, APNs key and review, and its one real advantage
(EAS Build without a Mac) is matched here by Codemagic. But it does mean iOS
should stop occupying the top of any plan until the hardware question is
answered.

---

# 4. ORDERED WORK PLAN

Ordered by value per unit of effort. Every session ends with an app that builds,
passes `flutter analyze` and `flutter test`, and runs. Sessions are sized at
**2–4 hours of implementation** on the assumption that you review every change —
so budget roughly double in wall-clock.

## Session 1 — Ship the security work that is already written · 1–2h

**This is first, and I want to justify it properly rather than just assert it.**

It is the only item on this entire list where the work is **already done and
sitting unshipped**. `firestore.rules` closes user enumeration, group/joinCode
enumeration and — the one that actually defeats the product — the target's
ability to pre-stamp `notifiedOutcome` and silently suppress the notification
that closes the accountability loop. All three are written, all three are
covered by 38 passing emulator tests, and per `ARCHITECTURE.md:993` none of them
are deployed.

It is also, right now, a **correctness blocker on the checked-out tree.**
`createGroup` writes `joinCodes/{CODE}` (`group_repository.dart:49`); under the
old rules that path has no match block and falls through to deny. Whatever is on
the phones is either the old client with three live holes, or the new client
that cannot create a group. Every other session in this plan builds on a base
that must be known-good first.

And it costs about an hour, most of it verification.

Value-per-effort on this is not close to anything else on the list: it is the
highest value *and* nearly the lowest effort, because the expensive part was
paid on 2026-08-10.

Steps (from `ARCHITECTURE.md:996-1012`, order matters):

1. Read the **deployed** ruleset source in the Firebase console. Confirm whether
   `users` has `list: if false`, whether `groups` is members-only, and whether
   the item field whitelists are live. This project has shipped a 6-day-stale
   ruleset before, so verify the deployed source, never the local file.
2. `node scripts/backfill-join-codes.mjs --key sa.json` — dry run, review output.
3. Same with `--apply`. It is rules-independent (service account bypasses rules),
   so it is safe before the deploy.
4. `firebase deploy --only firestore:rules`, then **re-read the deployed source**
   and confirm. Join-by-code breaks for anyone on the old client from this moment.
5. Install the current client on both devices.
6. Re-run the backfill with `--apply` — idempotent, and it catches any group an
   old client created during the window.
7. Record the date and the ruleset id in DECISIONS.md.

*Ends with:* the hardening actually in force, and the tree's client provably
able to create and join groups.

> **Git note:** I will not run `git` write commands. When a session needs a
> commit I will give you the exact commands and stop.

## Session 2 — Stop the app lying about privacy · 2–3h · [D1]

Write the ~30-line Kotlin handler for `time_app/secure_window` in
`MainActivity.kt` (`configureFlutterEngine`, `FLAG_SECURE` on/off) so the
existing Dart actually lands somewhere. Then **rewrite the `app_lock_tile.dart:83-86`
subtitle to be platform-honest** — Android gets both behaviours, iOS gets
neither (no API exists to block iOS screenshots, and recents blanking is
unwritten Swift).

Then the part that matters more than the code: **delete the `app_lock_test.dart`
assertions that `start()` re-applies FLAG_SECURE against a fake `SecureWindow`,**
and replace them with a dated manual verification line in DECISIONS.md — turn
the lock on, try to screenshot, check the recents thumbnail, write down the date
and result. PORT_REVIEW.md's sharpest single sentence applies here: *never let a
fake stand in for an unverified native effect.*

*Ends with:* the privacy claim is true on Android and honest on iOS, and the one
test in the repo that was actively misleading is gone.

## Session 3 — Fix the notification dead end · 3–4h · [D2, D11, D15 — see note]

Convert the shell to a `StatefulShellRoute`. Remove `/groups`, `/outcome` and
`/activity` as duplicate top-level routes so a screen cannot be registered
twice; push `/approvals`, `/archived`, `/schedule-builder`, `/profile` and
`/groups/:groupId` on top of the shell so the tab bar stays beneath and back
always exists. Switch `_handleTap` from `go()` to the shell-aware navigation.
Update `dev_menu_screen.dart:27-32` so the dev menu stops walking into the same
trap. Add `ref.onDispose` for `GoRouterRefreshStream` while you are in the file.

*Ends with:* tapping a notification lands you somewhere with doors.

### D15 — UNRESOLVED, not dropped

**There is no definition of D15 anywhere in this repository.** `grep -rn "D15"`
over `*.md`, `*.dart` and `*.mjs` returns exactly one hit: the Session 3 heading
above. The defect tables in §1.1–§1.5 run D1–D14, D16–D22, D24, D25 — **D15 and
D23 are both missing rows**, so this is almost certainly a row dropped during the
dedup pass rather than a typo for an existing id. Session 3 was executed as
**D2 + D11 only**. If the original D15 is remembered later, add its row to §1.1–§1.5
and re-open a session for it; do not assume Session 3 covered it.

### Session 3 decisions (2026-08-14, taken before implementation)

1. **Notification routing splits by who acts.** `decided` / `outcome` are
   planner-facing → `go()` the Activity **branch** (a tab switch, no stack push).
   `created` / `withdrawn` are target-facing → `/approvals` **pushed on top of the
   My Schedule branch**, so Back returns to a tab rather than exiting.
2. **The profile-completion check stays in the shell's `builder`**, wrapping the
   navigation shell above the tabs. It is *not* moved into `redirect` — that would
   reverse the documented decision to keep `redirect` synchronous
   (`app_router.dart:39-41`).
3. **Verification is by hand on the Redmi, no new automated test scope.** Because
   routing coverage is zero (D18), the device pass runs the explicit matrix below
   rather than a glance.

### Session 3 manual device checklist (Redmi / HyperOS, debug build)

Run top to bottom in one sitting. An unticked line is a failure, not an omission.
"Nav bar present" means the three-tab `NavigationBar` is visible; "Back" means the
system back gesture/button.

**A. Tabs — the shell itself**

- [ ] A1 Cold start signed in → lands on **Groups** with the nav bar visible.
- [ ] A2 Tap **My Schedule** → switches; Groups' scroll position survives.
- [ ] A3 Tap **Activity** → switches; nav bar still visible.
- [ ] A4 Back from a tab at its root → **exits the app** (does not cycle tabs).
- [ ] A5 The pending-count badge on My Schedule still renders (and shows nothing
      at zero).
- [ ] A6 Switch tabs 10× rapidly → no rebuild flash, no lost Firestore listeners
      (lists stay populated).

**B. Pushed routes — each must keep a door**

For every row: push it, confirm the AppBar back arrow exists, press Back, confirm
you return to the stated place with the nav bar visible.

- [ ] B1 Groups → tap a group → **Group detail** → Back → Groups tab.
- [ ] B2 My Schedule → **Pending approvals** → Back → My Schedule tab.
- [ ] B3 Activity → FAB → **Schedule builder** → Back → Activity tab.
- [ ] B4 Account menu → **Edit profile** → Back → the tab you launched from.
- [ ] B5 Account menu → **Archived** → Back → the tab you launched from.
- [ ] B6 Account menu → **Dev menu** (debug only) → Back → the tab you launched
      from.
- [ ] B7 B4/B5 launched from **each** of the three tabs → Back returns to *that*
      tab, not always Groups.
- [ ] B8 Save on Edit profile (`Navigator.pop`) → returns to the launching tab.
- [ ] B9 Deep stack: Groups → group detail → account menu → Archived → Back →
      group detail → Back → Groups tab.

**C. Notification paths — all four events (needs the second person)**

Foreground (in-app banner → **View**) and background (tray tap) for each. Every
one must land on a screen with the nav bar and a way back.

- [ ] C1 `created` → Pending approvals, pushed over My Schedule; Back → My
      Schedule tab.
- [ ] C2 `withdrawn` → same destination and same Back behaviour as C1.
- [ ] C3 `decided` → Activity tab (a branch switch — Back exits, no orphan push).
- [ ] C4 `outcome` → Activity tab, same as C3.
- [ ] C5 Legacy payload `type: 'outcome'` with **no** `event` field → Activity tab.
- [ ] C6 Tap a notification while already **on** the destination → no duplicate
      screen stacked on itself.
- [ ] C7 Tap a notification while a pushed route is open (e.g. Schedule builder)
      → lands correctly, and Back does not strand you.
- [ ] C8 Cold start **from** a tray tap (terminated app, `getInitialMessage`) →
      correct destination, nav bar present, Back works.

**D. Dev menu — all six destinations**

Each pushes and must return to the dev menu on Back.

- [ ] D1 Edit Profile · [ ] D2 Groups & Invite · [ ] D3 Schedule Builder
- [ ] D4 Activity (planner) · [ ] D5 Pending Approvals · [ ] D6 My Schedule /
      Outcomes
- [ ] D7 From any of the six, Back → dev menu → Back → the tab you launched from.

**E. Auth edges**

- [ ] E1 Sign out from the account menu → auth screen, no stranded shell beneath.
- [ ] E2 Sign back in → Groups tab, nav bar present.
- [ ] E3 Sign out while a pushed route is open (e.g. Archived) → auth screen, and
      Back does not reveal the signed-in stack.
- [ ] E4 A signed-in user with an **incomplete** profile still sees the
      complete-profile screen instead of the tabs (decision 2 above).
- [ ] E5 App lock (D1, shipped) still gates everything: background → foreground on
      a pushed route → lock screen, not the route.

*Record the date, the build, and any failing line in DECISIONS.md when the pass is
run. Restore the device to its prior build/theme afterwards.*

## Session 4 — Repository tests on the emulator you already run · 3–4h · [D18, V2]

The highest-value *new* work in this plan. `firestore-tests/` already has the
whole harness: `@firebase/rules-unit-testing`, `firebase-tools`, and
`npm test` running `firebase emulators:exec`. Point the client repositories at
it with `connectFirestoreEmulator` and test for real:

- `createItem` — both the self-planned `approved` path and the planner `pending`
  path
- `approve`, `reject` (with and without a reason), `markDone`, `markSkipped`,
  `withdraw`
- `archive` / `unarchive`
- `createGroup` — including that it writes `joinCodes/{CODE}` **after** the group
  doc (the rule forces that order)
- `joinByCode` — including that the returned group's `memberUids` contains the
  joiner, which is the bug §6.1 fixed and which nothing currently guards

Add **V2 while you are here**: the grant-off negative test. I checked
`rules.test.mjs` — it seeds `granted: true` and only asserts the positive case
at `:451`. Revoking the grant and asserting `PERMISSION_DENIED` on item-create
is about twenty lines, and it closes a CLAUDE.md item that has been open since
July as a *manual device run*.

*Ends with:* all five repositories covered, and the oldest cheap open item shut.

## Session 5 — One mutation layer owns `write → notify` · 3–4h · [D3]

Move the six hand-written pairings into one place — a thin application service
or the repository — so a screen physically cannot do the write without the
notify. Put the `_isSelfPlanned` skip in that one place too instead of the two
it lives in now. Then six tests with a fake notifier, one per transition, plus
one asserting a self-planned outcome fires **no** notify.

*Ends with:* the sharpest structural edge in the codebase is gone, and pinned.

## Session 6 — Selectors and dialogs out of the widgets · 3–4h · [D6, D7, D8]

Create `features/scheduling/domain/selectors.dart`: `visible()`, `pendingFor()`,
`approvedFor()`, `plannedForOthers()`, `countPending()` — pure functions, no
Flutter imports. Repoint the five inline `.where()` sites and both pending-count
copies at them. Build one `ReasonDialog` and one `ReasonLine` widget; the three
near-identical dialogs and the two verbatim `_reasonLine` copies collapse into
them, and **all four undisposed controllers die by construction.**

Then the Tier-1 tests, which now cost minutes: the selectors, and
`quiet_hours.dart`'s `minuteInWindow` — 59 lines of pure integer arithmetic with
a wrap-past-midnight branch and a zero-length-window branch, currently at zero
coverage, and the single easiest untested bug in the repo.

*Ends with:* business logic testable in milliseconds, and four leaks deleted.

## Session 7 — Firestore boundary and query hygiene · 2–3h · [D4, D5, D9]

Make `ScheduleItem.fromDoc` stop inventing a timestamp (`schedule_item.dart:133`)
— drop and report to Crashlytics with the doc id, or render an explicit
"unreadable item" card, but never a fabricated instant. Apply the same
parse-don't-default discipline to the other four models. Add the pagination
seam: `limit` and `orderBy` server-side on the five list queries, even if the
limit stays 200 forever — the *shape* is the point. Watch for a composite index
on the `collectionGroup('items')` query. Collapse the schedule builder's three
per-frame `resolveWall*` calls into one memoised computation.

*Ends with:* corrupt data is diagnosable, and the growth cliff has a seam.

## Session 8 — The real-pair validation run · 2–3h · needs the friend · [V1, V3, V4]

Not blocked by anything above; run it the first evening your tester is free. Do
all of it in one sitting with `wrangler tail` running:

- **V1 — the one that matters.** Backgrounded, then process-killed, delivery on
  the Redmi. Run the matrix: default settings vs. Autostart on + battery "No
  restrictions" + locked in recents. Record which settings were required. This
  answer also decides where the OEM primer goes in onboarding **and** whether
  the reminder layer is viable on this device.
- **V3** — the four-event foreground retest (created / decided / outcome /
  withdrawn), expecting `sent:1` each. All four need `creator != target`.
- **V4** — the two-timezone loop across a **DST-observing** pair.

Write the date and result next to each line in DECISIONS.md. An item is not done
until a dated run sits beside it — that rule is already in CLAUDE.md and it is
the one that has been slipping.

## Session 9 — Release readiness and honest docs · 3–4h · [D10, D12, D14, D16, D17, D25]

Real release keystore + signing config, retiring the `build.gradle.kts:35` TODO
(decide key custody now, not under release pressure). One error presentation
across the app — `AsyncView` everywhere, keep its 12s stuck-listener timeout,
and a rule that raw `Exception.toString()` never reaches a user. Side effects
out of `build()` at `app.dart:182` and `profile_edit_screen.dart:96`. A real
`README.md` that says a fresh clone needs `flutterfire configure`. Sweep the
dead code (keeping `NoopEventNotifier`, and keeping `cancelled` in the parser
while dropping it from the UI switches).

Then **reconcile the docs (D25)**: update CLAUDE.md's parked-alarm section to
match `DECISIONS.md:881`, and add a one-line note at the top of PORT_REVIEW.md
recording that its lead argument rests on a retired premise while its conclusion
stands on the rest. Half an hour that prevents a wasted alarm spike later.

## Session 10 — iOS, as far as Linux allows · 1–2h · [§3]

Steps 1–5 of §3.1. Register the iOS app, `flutterfire configure`, check the
plist is actually referenced in `project.pbxproj`, add the `REVERSED_CLIENT_ID`
URL scheme and `NSFaceIDUsageDescription`. Then **stop and decide**: Codemagic
free tier for build-only confidence, an hour of rented Mac to answer the
localization question, or shelve iOS until hardware exists. Do not start step 6.

*Ends with:* `firebase_options.dart` no longer throws for iOS, and a decision on
record instead of an open question.

## Then — the two things that need your direction, not my judgement

**A. The reminder layer.** The product's largest real gap (§2.1). CLAUDE.md's
build-order rule 2 forbids me from writing *any* of it — not even a stub, config
flag or TODO — until you explicitly direct it. When you do, the correct first
move is not product code: it is the throwaway Android spike already specified at
`DECISIONS.md:267-292`, run on the Redmi, off the product tree. If Session 8
already established the OEM settings matrix, that spike gets shorter.

**B. Goal / effort tracking.** CLAUDE.md's queued build item 3, gated behind the
real-pair validation. Needs a doctrine pass before code, and its first question
is the `durationMinutes` decision in §2.2.

**Optional, high value, unscheduled:** Worker tests (D19, ~1 day — a
`package.json` and `node:test` over `notify.js` covers all notification policy,
the largest untested surface in the system) and the §4.1(a) `groupIds`
denormalization (D21, ~1 day).

---

# 5. THE ONE THING

**Session 4 — repository and core-loop tests against the emulator harness you
already run.**

Session 1 is not a candidate for this question. It isn't a choice; it's a
prerequisite that has to happen regardless of what else you do, and it's an
hour. Set it aside.

Among everything that *is* discretionary, Session 4 wins, for four reasons:

1. **It is the direct fix for your actual problem.** PORT_REVIEW.md's diagnosis
   — which I re-derived independently and agree with — is that generating work
   outpaced verifying it. The evidence is specific: 67% of test lines cover the
   two most recently built, most intellectually satisfying features, while all
   five repositories, every core-loop screen and the entire write→notify pairing
   sit at zero. Tests on the core loop are what let you accept a generated change
   without reading every line. That is the thing you said you couldn't do.

2. **The expensive part is already built.** `firestore-tests/` has the emulator,
   `@firebase/rules-unit-testing`, `firebase-tools` and a working `npm test`.
   You are adding test files to a harness that runs today, not standing up
   infrastructure. That is why the value-per-effort is so lopsided.

3. **It is the only item that makes every later session cheaper.** Sessions 5,
   6 and 7 all rewrite core-loop behaviour — the mutation layer, the selectors,
   the Firestore parser. Doing those *without* a safety net means reviewing each
   one line by line. Doing them after means the suite tells you whether the
   refactor preserved behaviour. Do Session 4 out of order and you pay for it
   three times.

4. **It closes an open item as a side effect.** V2 — the grant-off negative test
   — has been on CLAUDE.md's list since July as a manual device run that never
   happened. In this harness it's twenty lines, and it never needs to be run by
   hand again.

The runner-up is Session 3 (the notification dead end), and I want to be fair to
it: it is a severe, genuinely user-facing bug, and at two users a stranded
screen is more visible than any missing test. But it is also cheap enough that
it will happen anyway, and fixing it changes one screen's navigation. Session 4
changes how every subsequent session goes.
