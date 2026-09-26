# Decisions — reasoning log

Full rationale for architectural choices. CLAUDE.md holds the terse one-liners;
this file holds the "why" so it doesn't load every session. Newest at the bottom.

---

## Backend = Firebase (not Supabase)

Auth + Firestore + Cloud Functions + FCM.

The completion→planner push is non-negotiable in the spec, and FCM fires natively
from a Firestore write via a Cloud Function — one integrated pipeline, no
self-hosted server. Supabase would still need FCM wired by hand (Postgres trigger
→ Edge Function → own FCM creds).

**Trade-off accepted:** Firestore security rules for the consent/permission model
are more verbose and error-prone than Postgres row-level security. Mitigate by
(a) keying schedule items by target-user id for simple ownership rules and
(b) routing privileged writes through Cloud Functions.

## State management = Riverpod

Compile-safe, testable without a `BuildContext`, and `StreamProvider` maps cleanly
onto Firestore real-time streams (pending queue, outcomes). Kept deliberately
plain while the user learns it — no families/autoDispose/code-gen until a screen
genuinely needs it.

## Routing = go_router

Official router with first-class deep-link support, needed later for
invite-by-link.

## Feature-first folder layout

`lib/features/<feature>/presentation/`; `data/` + `application/` added per feature
as backend wiring lands.

## Auth = Google Sign-In only for v1 (email/password deferred)

Avoids building sign-up/reset/verify screens (less solo-dev code), gives one-tap
join for the invite-by-link flow, and is smoother for recruiting test pairs. Cost:
a one-time debug SHA-1 registered in the Firebase console (and re-run
`flutterfire configure` after adding it). Email/password is easy to add later if a
tester can't use Google.

## Firebase config via FlutterFire CLI

`flutterfire configure` registers the app and generates config, instead of manual
`google-services.json` placement. Re-run it after adding a SHA-1 so the Android
OAuth client lands in the config.

## Firestore in TEST MODE (rules pending) — RESOLVED 2026-07-18

~~Currently open read/write~~ — superseded by **Firestore security rules — v1**
(below), deployed 2026-07-18. Test mode is no longer in effect.

## minSdk = 23

Set in `android/app/build.gradle.kts`; required by Firebase Auth 6.x.

## Firestore security rules — v1 (deployed 2026-07-18)

`firestore.rules` written and deployed to `time-app-1e1c9`; **replaces TEST
MODE.** Rules mirror the app's actual read/write paths exactly (per
`lib/**/data/*_repository.dart`), so every real query is provably safe and
nothing extra is opened up.

Model:
- **users** — profile read = **any signed-in user** (name/avatar/home tz);
  writes owner-only. *(Decision ① — auth-gated read.)*
- **groups** — group doc (name, joinCode, memberUids) readable by any signed-in
  user so join-by-code can look it up; create only as owner + sole first member;
  the only permitted UPDATE by a non-member is a **self-join** that adds *only*
  the caller to `memberUids` (enforced: single-element diff, caller not already
  present). *(Decision ②.)*
- **members / plannerGrants / scheduleItems** — relationship-gated.
  - members: readable by group members; a user writes only their own member doc.
  - plannerGrants: **target-only consent** — caller must be the `targetUid` and
    the recorded `grantedByUid`, and both parties must be group members. Read by
    the planner/target of the grant or any group member.
  - scheduleItems: create by the creator, who is either the target or a planner
    holding an **active grant** over the target in the item's group; update is
    **target-only** (approve/reject/done/skip); createdByUid/targetUid can't be
    forged.

**Collection-group reads need `{path=**}` rules (fixed 2026-07-18).** Two screens
issue `collectionGroup` queries — Planner Activity (`items` where
`createdByUid == me`) and Schedule Builder (`plannerGrants` where
`plannerUid == me`). Root cause of the `permission-denied`: **a `collectionGroup()`
query is matched ONLY by a rule written with a recursive `{path=**}` wildcard;
a rule scoped to a specific parent path (`/scheduleItems/{targetUid}/items/...`)
never matches it, regardless of the condition** — so there was literally "No
matching allow statements." This is about the match PATH SHAPE, not the
condition. (Two earlier hypotheses were wrong: it was not a `resource` vs
parent-wildcard mix, and splitting one `allow` into two changed nothing —
verified on the Firestore emulator.)

Fix — keep the specific-path rules for DIRECT/path-scoped reads + writes, and add
top-level recursive rules for the collection-group reads:
```
match /{path=**}/items/{itemId} {
  allow read: if signedIn() && resource.data.createdByUid == request.auth.uid;
}
match /{path=**}/plannerGrants/{grantId} {
  allow read: if signedIn()
    && (resource.data.plannerUid == request.auth.uid
        || resource.data.targetUid == request.auth.uid);
}
```
`resource.data`-scoping DOES work for collection-group lists, so the model stays
restrictive: the client query must filter on the same field (the app's queries
do), and a user can read only items they created / grants naming them. No
denormalization needed (`createdByUid`, `plannerUid` already on the docs). Reads
were NOT opened to any-signed-in.

**How it was verified (do this, not console-eyeballing):** the Firestore emulator
(`firebase emulators:start --only firestore`) loads the real `firestore.rules`,
and its `emulator/v1/.../:securityRules` endpoint hot-swaps rulesets for a fast
loop. Ran the exact query shapes with a mock ID token, seeded a group/grant/item
as admin, and asserted ALLOW **plus negative controls** (can't read others'
items/grants, unfiltered collection-group query denied, non-member roster denied)
before deploying. The Rules **test API** / Playground could NOT verify this — they
evaluate `list` with `resource == null`, so they falsely deny any resource-scoped
list. See also the "diagnostic hazard" note below.

Deferred hardening (logged, not built):
- **Cloud-Function-mediated join** — server-validated "add only yourself" instead
  of a client `arrayUnion`. Needs the **Blaze** plan. The current rule already
  proves the self-join is single-element and caller-only, which is sufficient
  for v1; the CF version is the tighter form.
- **"Share-a-group" profile-read scoping** — restrict profile reads to users who
  share a group with the owner, rather than any-signed-in. Tighter than Decision
  ①; deferred.
- **Planner cancel/edit of an approved item** — the data model allows
  `cancelled`/`withdrawn` and commitment-edit → `pending`, but there is no code
  path yet, so item UPDATE is target-only for now. Widen the rule when that step
  is built.
- **Emulator rules unit tests** (`@firebase/rules-unit-testing`) — deferred; v1
  is verified by an on-device happy-path run plus manual negative tests
  (unauthenticated write blocked; grant-off write blocked).

---

# Plan / sequencing

## Validate the loop with a real friend BEFORE building alarms

Once security rules are in, test the current loop (no alarms — in-app reminders
only) with **one real friend** before investing in alarm work. The behavioral bet
("people accept a friend scheduling them") matters more than the alarm feature; if
that bet fails, the expensive alarm work is wasted. Alarms come *after* this test.

---

# UI: no silent infinite spinners (AsyncView)

All list/stream screens render through `lib/core/widgets/async_view.dart`, which
adds a **loading timeout** on top of the usual loading/error/empty states: if a
Firestore listener sits in `loading` past ~12s with no data or error, the screen
shows an actionable "taking longer than expected → Retry" instead of spinning.

**Why:** a Firestore `.snapshots()` listener does NOT surface `UNAVAILABLE`
(network) errors to the stream — it retries silently — so a query with no cached
data to fall back on hangs forever with no error. First seen 2026-07-18: the
planner's two collection-group screens (Schedule Builder, Planner Activity) spun
forever on the Redmi while every other screen worked.

**There were TWO stacked bugs, and the outer one hid the inner one:**
1. **App-scoped network block** — the device OS resolved `firestore.googleapis.com`,
   but the app process could not (HyperOS per-app network restriction). This made
   the listeners retry silently and never emit — a spinner with no error. Cached
   screens rendered; uncached collection-group queries hung.
2. **A real collection-group rules denial** (below) — once the network block was
   cleared, the true error surfaced immediately: `permission-denied`.

The timeout does not fix either bug; it makes both *visible* (spinner → error or
retry) so we stop mistaking a backend problem for a broken app.

## Diagnostic hazard: an offline app makes rules tests lie

While the network block (above) was in effect, a "broaden the rules to any
signed-in user" test was deployed to check whether permissions were the cause.
It changed nothing — but **only because the app couldn't reach the server at
all**, so no rule (loose or strict) could have mattered. That falsely exonerated
the rules. **Rule: never conclude "not a permissions problem" from a live-app
test until the app is confirmed to be actually reaching Firestore** (a genuine
`permission-denied` error, or a server-side query that returns). An
infinite/silent spinner means "no answer," not "allowed."

# Alarm reliability — platform research (2026-07-18)

Researched before committing to alarm work, because the whole premise assumes an
alarm can actually fire. Sources cited inline; this changes with OS versions, so
re-check before implementing.

## Android — achievable, but CONTINGENT on OEM-setting onboarding (not pure code)

- **Best native primitive is `AlarmManager.setAlarmClock()`**, not
  `setExactAndAllowWhileIdle()`. `setAlarmClock` is treated as a real clock alarm:
  highest priority, the system leaves Doze shortly before it fires, and it fires
  with battery-saver on and after reboot (with a boot receiver).
  `setExactAndAllowWhileIdle` is weaker (throttled to ~once per 9 min, still
  delayed). [nek12.dev](https://nek12.dev/blog/en/how-to-make-android-notifications-100-reliable/),
  [Android Doze docs](https://developer.android.com/training/monitoring-device-state/doze-standby)
- **Most bulletproof of all = native clock handoff** via the
  `AlarmClock.ACTION_SET_ALARM` intent: the system Clock app owns the alarm, so it
  survives app-kill and reboot and rings as a true alarm — but **no custom sound**
  (kills the voice note) and it shows a confirm screen. This is the spec's
  "reliable mode." The two modes (native-clock vs custom-voice-sound) remain
  mutually exclusive.
- **Xiaomi/HyperOS is the real risk.** By default "background processing simply
  does not work right and apps will break"; scheduled work/alarms are killed
  unless the user grants: **Autostart** (Security app), **Battery → No
  restrictions**, **lock/pin the app** in recents, and "keep running after screen
  off." Autostart also **resets after OTA updates**.
  [dontkillmyapp.com/xiaomi](https://dontkillmyapp.com/xiaomi),
  [flutter_foreground_task #343](https://github.com/Dev-hwang/flutter_foreground_task/issues/343)
- Android 12+ needs `SCHEDULE_EXACT_ALARM`; a bona-fide alarm app declares
  `USE_EXACT_ALARM` (auto-granted on 13+).
- Flutter options: `android_alarm_manager_plus` (has an `alarmClock` flag +
  `rescheduleOnReboot`) and the `alarm` package (gdelataillade, cross-platform,
  native audio). [pub: android_alarm_manager_plus](https://pub.dev/packages/android_alarm_manager_plus),
  [pub: alarm](https://pub.dev/packages/alarm)

**Honest read:** reliable firing after an OS kill is achievable on Xiaomi, but
**not by code alone** — it requires a first-run onboarding flow that walks the
user through the OEM exemptions above, plus native `setAlarmClock`/clock-handoff
scheduling and a boot receiver. Without the exemptions, alarms degrade to
delayed/dropped. Most bulletproof path (clock handoff) sacrifices the voice note.
This must be proven on the actual Redmi before it's trusted (see spike below).

## iOS — the premise CHANGED: iOS 26 AlarmKit makes true third-party alarms possible

- **Pre-iOS 26 (the old understanding, and still true for old devices):** no true
  third-party alarm. Local notifications respect the ringer switch and DND;
  "Critical Alerts" needs a special Apple entitlement (health/safety-oriented,
  approval not guaranteed) and alarms could fail after restart/app-update.
- **iOS 26 (WWDC 2025, shipped late 2025) introduced `AlarmKit`:** third-party
  apps get the **same alarm privileges as Apple's Clock** — rings through **Silent
  mode, the ringer switch, AND Focus/DND**, full-screen alert, Lock Screen,
  Dynamic Island, survives app termination, unlimited alarms. User grants a
  one-time system permission on first alarm.
  [MacRumors](https://www.macrumors.com/2025/06/11/ios-26-third-party-alarm-apps/),
  [WWDC AlarmKit writeup](https://dev.to/arshtechpro/wwdc-2025-wake-up-to-the-alarmkit-api-ios-26-4e67)
- A Flutter binding exists — `flutter_alarmkit` — but it is **very early (v0.0.x)**
  and requires **iOS 26+ / Xcode 26**.
  [pub: flutter_alarmkit](https://pub.dev/packages/flutter_alarmkit)

**Honest read:** iOS is **no longer** a hard "can't fire alarms." On **iOS 26+**
it's genuinely capable (comparable to Android's best). The catches: (a) hard
**version floor at iOS 26** — anything older degrades to notification-only
(respects DND, no true alarm); (b) the Flutter plugin is immature, so early work
may need a thin native AlarmKit platform-channel of our own; (c) whether AlarmKit
allows a custom **voice-note** as the alarm sound is unverified.

## iOS product-decision options (pending — the user's call, not technical)

1. **iOS floor = 26.** Full loop on both platforms; drop older iOS. Cleanest, but
   cuts the addressable iOS base to iOS-26-capable devices.
2. **iOS 26 full + older-iOS degraded** (notification reminder that respects DND —
   "soft nudge," not an alarm). Wider reach, but the core promise ("an alarm
   fires") is not kept on old iOS.
3. **Android-only v1**, iOS later. Matches "prove the loop on the aggressive
   killer first"; iOS via AlarmKit becomes a fast-follow.

## Proposed minimal Android spike (NOT built — awaiting direction)

Smallest thing that empirically answers "does an alarm fire after the OS kills the
app on this Redmi?" — a **throwaway app/branch, NOT the product, no consent loop,
no voice notes, no UI beyond a button**:

- One screen, one button: schedule a single alarm ~15 min out via
  `AlarmManager.setAlarmClock()` (through `android_alarm_manager_plus` with the
  `alarmClock` flag, or the `alarm` package).
- The **on-fire handler runs while the app is dead** — it must (a) show a
  full-screen/heads-up notification + sound, and (b) **record the actual fire
  timestamp** (append to a local file or a Firestore doc) so we can measure
  scheduled-vs-actual delay without reopening the app.
- **Kill the app** (force-stop; and separately, swipe from recents; and screen
  off) and do **not** reopen it before fire time.
- **Test matrix on the Redmi:** default settings (no exemptions) vs. exemptions
  granted (autostart + battery-unrestricted + locked). Also try the
  `ACTION_SET_ALARM` clock-handoff variant as the bulletproof baseline.
- **Pass criterion:** fires within ~1–2 min of schedule after force-stop, without
  reopening. Record the delay and which settings were required.

Rationale: this isolates the ONE unknown (survives-kill firing on HyperOS) with a
few hours of throwaway code, before investing in native scheduling, the consent
loop, boot receivers, and voice-note plumbing. Keeping it out of the product tree
also honors the CLAUDE.md rule that no alarm code lands in the app until the loop
is validated and alarm work is explicitly directed.

# Alarm permission & degradation model (decided 2026-07-18)

> **⚠️ SUPERSEDED 2026-07-23 — see "Product decision: this is a reminder/
> accountability app, NOT an alarm app" at the end of this file.** The whole
> "Alarm mode vs Reminder mode" duality below collapses: **Reminder mode is the
> only mode, on both platforms, by design.** There is no true-alarm path, no
> `setAlarmClock`, no AlarmKit, no OEM alarm exemption, no "make your alarms real"
> primer. The permission we ask for is the ordinary notification permission. The
> parts of this section still true: ask contextually with a soft primer, never
> work around a refusal. Everything framed as "true alarms with permission" is
> dead. Kept for history only.

**Decided constraint (do not violate):** alarms ring ONLY with explicit user
permission. Without it, the app degrades gracefully to **notifications on both
platforms** — an acceptable fallback, not a failure state. **Never work around a
user's refusal** (no re-prompt loops, no dark patterns, no background hacks to
force sound). With permission granted, we want true alarms on both platforms via
the sanctioned APIs (iOS 26 AlarmKit; Android `setAlarmClock` + boot receiver +
OEM-exemption onboarding). *(When alarm work is actually built, promote the
"never work around refusal" line to a CLAUDE.md guardrail.)*

## Two states, not many — the unifying model

Every user is in exactly one of two states per their device, and the UI names it:
- **Alarm mode** — permission granted AND the OS can do true alarms → rings
  through Silent/Focus/DND.
- **Reminder mode (fallback)** — permission refused, OR the OS can't do true
  alarms → a normal notification that respects the ringer/DND.

Crucially, **iOS < 26 collapses into the same Reminder-mode state as a refusal**,
so we don't design a third path — an incapable OS is treated exactly like a
declined permission.

## iOS floor question — answered

**iOS 26+ is required for the real (breaks-through) experience; it is NOT required
to run the app.** Below iOS 26 there is no sanctioned way to fire a true alarm —
the ceiling is `UserNotifications` (time-sensitive), which respects the ringer and
DND (Critical Alerts needs special Apple approval, health/safety-oriented, not a
v1 path). So iOS < 26 runs permanently in **Reminder mode**, which the decided
model already deems acceptable. Net: **iOS is not dropped**; it just means "true
alarms need iOS 26," identical in behavior to a user who declined.
[Apple requestAuthorization](https://developer.apple.com/documentation/alarmkit/alarmmanager/requestauthorization()),
[MacRumors AlarmKit](https://www.macrumors.com/2025/06/11/ios-26-third-party-alarm-apps/)

## When we ask (both platforms): contextually, with a soft-ask primer

Not at launch. Ask at the first moment of real value — when the TARGET first has
an approved item that would become an alarm (or in a short "make your alarms real"
step right after they accept being planned for). Precede the OS prompt with our
own **priming screen** ("soft ask") explaining the trade, so the one-shot system
prompt is never wasted on an unprepared user. This is standard iOS permission
hygiene and what the shipped AlarmKit apps do.

## iOS ask (AlarmKit)

- `NSAlarmKitUsageDescription` in Info.plist with a short, honest reason.
- Priming screen → on "Turn on alarms," call AlarmKit `requestAuthorization()`
  (system prompt). Read `authorizationState` (`notDetermined` / `authorized` /
  `denied`).
- **If denied:** don't nag. Schedule a time-sensitive notification instead, and
  show a calm, persistent status ("Alarms are off — reminders will be silent if
  your phone is") with a single deep-link to Settings to re-enable. Revocation
  lives in Settings → Notifications (per AutoSleep).
- **iOS < 26:** no ask (AlarmKit absent) → Reminder mode with honest copy that
  true alarms need iOS 26.

## Android ask (two layers)

1. **OS exact-alarm:** declare `USE_EXACT_ALARM` (auto-granted to bona-fide alarm
   apps on 13+); handle the `SCHEDULE_EXACT_ALARM` prompt on 12.
2. **OEM-exemption onboarding (the real Xiaomi gate):** a guided checklist that
   deep-links to Autostart, Battery→No restrictions, and lock-in-recents, tailored
   by manufacturer, using [dontkillmyapp.com](https://dontkillmyapp.com) as the
   reference content. Apps **guide, they don't fight** — none of this is grantable
   programmatically.
- **If the user skips the OEM steps:** degrade to best-effort notifications; show
  "Alarms may be unreliable on this phone — [Fix]" that reopens the checklist.
  Never block usage. Re-surface the checklist after a missed-alarm signal (also
  covers the autostart-resets-after-OTA problem).

## Making Reminder mode feel deliberate (not broken)

- **Name the mode** in the UI, per-item and as an account status ("Alarm mode" /
  "Reminder mode"), never a silent downgrade.
- Honest, non-alarming copy + one clear upgrade CTA.
- **Show the target's mode to the planner** — the accountability model depends on
  the planner knowing whether their scheduled item will truly ring or just notify.
- If a user had alarms then lost permission, tell them; don't fail silently.

## Best-practice patterns lifted from shipped apps (don't reinvent)

- **ToDo Alarm** — relies on the *standard* system prompt (doesn't over-customize);
  preaches "high signal: fewer alarms, set deliberately" — abuse alarm-level
  alerts and you lose the permission permanently. Its photo-proof "Prove It" gates
  alarm dismissal — structurally the same shape as our done/skip. Lesson: treat
  the permission as precious; only real scheduled items become alarms.
  [todo-alarm.com](https://todo-alarm.com/blog/ios-26-alarmkit-apps/)
- **AutoSleep** — migrated *from* notifications (missed/randomly silenced) *to*
  AlarmKit specifically to break through Sleep Focus; permission on first schedule;
  user-revocable in Settings; alarms count toward a system per-app limit. Lesson:
  AlarmKit fixes exactly our failure mode; budget alarms against the per-app cap.
  [AutoSleep smart alarm](https://autosleepapp.tantsissa.com/watch-use/smart-alarm)

## Package assessment (checked maintenance + iOS 26 support)

No single package covers both true-alarm paths. Likely composition:
- **iOS true alarms → `flutter_alarmkit`** (gdelataillade, v0.4.0, verified
  publisher, iOS 26+; throws `UNSUPPORTED_VERSION` below 26; exposes
  `requestAuthorization`, one-shot/countdown/recurring, **custom sounds
  `.caf/.aiff/.wav`**, stop/snooze, Live Activity). Young but moving fast; pin the
  version and be ready to maintain a thin native channel of our own.
  [pub](https://pub.dev/packages/flutter_alarmkit)
- **`alarm` (gdelataillade, v5.5.0, actively maintained)** — cross-platform but its
  **iOS path is the OLD silent-`AVAudioPlayer` hack (NOT AlarmKit)**: fails on
  termination, doesn't break DND. Android = foreground service + AlarmManager;
  delegates OEM survival to dontkillmyapp. **Not sufficient for iOS true alarms.**
  [pub](https://pub.dev/packages/alarm)
- **Android true alarms** → native `setAlarmClock` (+ boot receiver) or the
  clock-handoff intent; confirm the actual mechanism in the spike rather than
  trusting a package's foreground-service approach.
- **Fallback (both, and iOS < 26)** → local notifications.

**Bonus finding:** a **voice-note alarm sound is feasible on iOS** — AlarmKit
takes bundled custom sounds (`.caf/.aiff/.wav`), matching the spec's
"pre-downloaded, never streamed." (Android's bulletproof clock-handoff still can't
carry a custom sound — the reliability-vs-voice tradeoff stands there.)

## Android empirical spike — reaffirmed, unchanged

The minimal throwaway spike proposed 2026-07-18 stands (one `setAlarmClock` alarm,
on-fire timestamp recorded while the app is dead, force-stop + Xiaomi settings
matrix). It should also settle *which* Android mechanism actually survives on the
Redmi — native `setAlarmClock` vs. the `alarm` package's foreground-service vs. the
`ACTION_SET_ALARM` clock-handoff — before we commit to one. Still NOT built;
awaiting the go-ahead.

# Completion→planner push — transport = Cloudflare Worker now (no card), Cloud Function on card-day

**Decision (2026-07-19):** ship the non-negotiable completion→planner push
**without Blaze**, because we are not attaching a payment card yet (see the Blaze
research above — Blaze requires a payment instrument; an individual Indian account
can't self-serve UPI, only a debit/credit card). Transport for now is a
**Cloudflare Workers HTTPS endpoint, client-triggered** by the app after it writes
the outcome. The design is deliberately built so that moving to a
**Firestore-triggered Cloud Function** later is a **transport swap, not a
rewrite.**

## How the swap-ability is guaranteed (architecture)

- **One portable notification module** owns ALL the logic — recipient resolution
  (which planner is entitled to the outcome), payload shape, and invalid-token
  cleanup. It is transport-agnostic: it talks to Firestore + FCM through an
  injected `ctx` ({ projectId, db, fcm }), never through Worker/Cloudflare APIs
  directly. The Worker is just ONE caller that builds a REST-backed `ctx`; a
  future Cloud Function is a SECOND caller that builds an Admin-SDK-backed `ctx`
  around the same module.
- **The Flutter app calls an `OutcomeNotifier` abstraction, never the Worker URL
  directly.** Today its implementation POSTs to the Worker. On card-day it becomes
  a **no-op** (the server fires the push on the Firestore write) and nothing else
  in the app changes.

## Card-day checklist — exactly what changes when a card is attached

When Blaze is enabled, to move from client-triggered Worker → server-triggered
Cloud Function:

1. **Upgrade the Firebase project to Blaze** (attach debit/credit card; set a
   $0/₹0 **budget alert** so overage is visible). No code.
2. **Add a Cloud Function** (`functions/`) with a Firestore `onDocumentUpdated`
   trigger on `scheduleItems/{targetUid}/items/{itemId}`, firing when `outcome`
   transitions from absent → present. In it, build an Admin-SDK-backed `ctx` and
   call the **same** `sendOutcomeNotification(ctx, {targetUid, itemId, outcome})`
   module — reused verbatim, not rewritten.
3. **Flip the Flutter `OutcomeNotifier` provider** to the no-op implementation
   (one line). The app keeps writing the outcome exactly as it does now; it just
   stops making the HTTP call. No other app change.
4. **Move the FCM send credential** from the Worker secret to the Cloud Function's
   default service account (already present in the Firebase project) — the private
   key stops living in Cloudflare.
5. **Retire the Worker** (delete the Cloudflare deployment + its secret) once the
   Function is verified sending in production.
6. **Delete the Worker's ID-token-verification + caller==target authorization**
   code path — a Firestore trigger runs server-side with the write already
   authorized by Firestore rules, so that check becomes redundant (the rule
   `update: if request.auth.uid == targetUid` already proves the target authored
   the outcome).
7. **Reconciliation becomes free** — the Function is server-side at-least-once
   with built-in retry, which retires the silent-miss failure mode below without
   any client work.

**Net app-code delta on card-day: one provider line.** Everything else is
backend/ops. That is the whole point of the abstraction.

## Recipient scoping = creator ∩ active-grant (confirmed 2026-07-19)

The push goes to the item's **creator, and only while their planner grant is
still active** — not to every planner who holds a grant over the target. This is
forced by the current Firestore rules: the collection-group `items` read rule
only entitles a planner to read items where `createdByUid == their uid`, so the
creator is the ONLY planner entitled to the item's contents. Notifying any other
grant-holder would push them a title they cannot otherwise read — a leak.

**This broadens to the full active-grant set if and only if the rules widen to
co-planner reads — and the two MUST change together.** The day the `items` read
rule allows non-creator planners with an active grant to read a target's items,
the recipient query in `worker/src/notify.js` broadens from "creator ∩ grant" to
"all planners with an active grant over the target," in the same change. Neither
moves without the other: widen the rules without the module and co-planners get
no push; widen the module without the rules and the push leaks data the recipient
can't see in-app. The recipient logic lives in exactly one place (`notify.js`) so
this stays a single-point change.

## Silent-miss failure mode — knowingly accepted at N=2

The client-triggered transport has an unavoidable gap: **if the app is killed (or
loses network) in the window between writing the outcome to Firestore and calling
the Worker, the outcome is saved but the push never fires — silently, with no
error to anyone.** On the target's Xiaomi device this is a *real* risk: the same
aggressive process-killing that motivates the whole app is what can eat the
outbound HTTP call.

**Why it's tolerable for the two-person test (and we build NO retry queue):**
- The **in-app live outcomes view already shows the outcome** the instant the
  write lands, regardless of the push. The planner sees it next time they open the
  app. Push is a *timeliness* layer, not the source of truth — the accountability
  loop still closes without it.
- A client-side retry/reconciliation queue is disproportionate engineering for
  N=2, and the *correct* fix for reliable delivery is precisely the Firestore-
  triggered Cloud Function (server-side retry) — i.e. the reliability argument is
  an argument for card-day, not for building throwaway retry plumbing now.
- **Accepted explicitly:** at N=2 a missed push is a missed *notification*, never
  a missed *outcome*. Revisit only if real testing shows planners actually rely on
  the push arriving (then attach the card and swap transport — do not build
  client retries).

**Refinement (2026-07-23) — the miss window is narrower than "loses network."**
Traced the actual call path (`outcome_screen.dart` → `markDone`/`markSkipped` →
`notifyOutcome`). `markDone` is a Firestore `set()`, whose Future on mobile
**only resolves once the server acks the write** (offline it stays pending), and
`notifyOutcome`'s single HTTP POST is `await`ed *after* it. So the push attempt is
**connectivity-gated for free**: a user who taps Done in a dead zone but stays in
the app until signal returns gets the write synced *then* the POST fired — the
common spotty-signal case self-heals, with no retry logic. The genuine silent-miss
is therefore only: **tap Done while offline (or during an online blip on that one
POST), then the app is killed / phone reboots before the POST completes** — the
outcome still persists and syncs on next launch (never lost; visible in the in-app
outcomes view), but the in-memory `notifyOutcome` continuation is gone and no push
ever fires. Crashlytics `recordError` (added 2026-07-23) now surfaces the
*online-but-failed* variant; the offline-then-killed variant leaves no client
signal by construction.

**Known limitation — logged, not being built.** The eventual client-side fix (if
card-day's server-side Cloud Function isn't the chosen path) is a **persisted
outbox**: enqueue the outcome-push intent to durable local storage at tap time and
replay it on next app launch until the Worker 200s. This closes the offline-then-
killed variant without waiting for Blaze. **Do NOT build it now** — disproportionate
for N=2, and the server-side Cloud Function (card-day) retires this failure mode
without any client work (see item 7 in the card-day plan above). This entry exists
so the limitation and its fix are on record, not lost between sessions.

# Alarm persistence across reboot — HARD REQUIREMENT (not an optimisation)

> **⚠️ PARTIALLY SUPERSEDED 2026-07-23** by the reminder-app product decision (end
> of file). The *requirement* still holds — a scheduled reminder must survive
> reboot — but the *mechanism* changes: we are **not** using `AlarmManager` +
> a hand-rolled `BOOT_COMPLETED` receiver as the primary substrate. **WorkManager
> persists its scheduled work across reboot automatically** (its own DB, rescheduled
> on boot), so it — not a custom BootReceiver — is the reboot-durability answer for
> the inexact reminder layer. `BOOT_COMPLETED` is still relevant as a top-up hook
> and is still OEM-blocked on Xiaomi without autostart. See the reminder-layer
> write-up at the end for the current mechanism.

**Requirement (must-build when alarm work lands, not a nice-to-have):** every
pending alarm must be **durably stored** (its schedule survives process death and
device power-off) and **rebuilt on boot** via a `BOOT_COMPLETED` receiver
(`RECEIVE_BOOT_COMPLETED` permission + a `BootReceiver`). Android's `AlarmManager`
holds scheduled alarms **only in volatile memory** — a reboot silently drops
every registered alarm. Without boot-time re-registration, a target who restarts
their phone (or gets an OTA reboot — routine on HyperOS) loses all future alarms
with **no error and no signal to anyone**, which breaks the accountability loop
invisibly. That is a correctness failure, not degraded polish.

Scope of the requirement:
- **Persist** each pending alarm's identity + fire time to durable local storage
  (and the schedule state is already mirrored server-side per the spec's
  "reinstall/device-change can re-register" line — reuse that as the source of
  truth where possible; do not rely on in-memory state).
- **On boot**, the receiver reads the pending set and re-registers every
  still-future alarm; skip any already-past ones.
- The **iOS** side: AlarmKit persists its own alarms across reboot, so the boot
  receiver is Android-specific — but the durable-store half of the requirement is
  cross-platform (needed for reinstall / device-change re-registration anyway).
- This requirement is **coupled to the unverified Xiaomi spike**: the spike must
  include a reboot cell, because "fires after force-stop" and "fires after reboot"
  are different guarantees and both must hold.

# Outstanding verification debt (UNPAID)

Things that are **built/deployed but not yet exercised end-to-end** — plus
research conclusions we are now **building on top of without empirical proof.**
Listed here so they stay visible as debt — do NOT treat any of these as "done"
until the run is actually performed and the result recorded.

**Load-bearing assumption for everything built from here on: ALARMS FIRE.** All
work sequenced after this point (alarm UI, mode indicators, goal tracking, FCM,
voice notes) is built on the unproven premise that a `setAlarmClock` alarm
actually rings after the OS kills the app on the target Xiaomi device. If the
empirical answer comes back bad, the two-state Alarm/Reminder model and anything
that renders or depends on it may need rework. This debt is knowingly incurred.

**Deadline — Tests 2 & 3 are due BEFORE the debug APK goes to the friend, not
after.** A build must not reach a real user while the rules protecting their data
have never been exercised end-to-end. (The APK can be built and self-tested
first; the gate is the hand-off to the friend.)

- **Firestore rules — on-device happy path (Test 2).** Rules deployed 2026-07-18
  and verified only against an unauthenticated caller (Test 1: anon read + write
  both 403). The two-account happy path — A creates group → B joins by code → A
  grants B planner → B creates item → A approves + marks Done → B sees outcome —
  has **not** been run on a device. Until it is, "the rules don't break the app"
  is unproven.

  **DISCHARGED — Test 2 PASSED 2026-07-24.** See "Rules Test 2 — on-device happy
  path PASSED" below, under `# 2026-07-24 (later)`. The paragraph above is left
  standing rather than rewritten, so the debt and its discharge sit next to each
  other — same handling as the ARCHITECTURE.md amendment on 2026-08-14. **Test 3
  below is NOT discharged by it.**
- **Firestore rules — grant-off negative test (Test 3).** Not run. Need to
  confirm that with the planner grant revoked (`granted:false`), B's item-create
  is rejected with `PERMISSION_DENIED`.
- **Cross-timezone planning (build step 5g) — real two-timezone run.** An early
  on-device resolution check was done with a Chicago planner + Kolkata target,
  but the user is (correctly) tracking the full step-5g run as **not yet paid**:
  it has not been exercised as a real two-people / two-devices loop, and neither
  side of the earlier check sat in a DST-observing zone, so the known DST
  gap/overlap edge case (below) is still completely unverified. Do not mark 5g
  done until a run across a DST-observing timezone pair is recorded.

- **Alarm firing on Xiaomi — the whole premise, empirically UNVERIFIED
  (PARKED).** The alarm platform research (above) is desk research only. **No
  spike has been run on a real device.** The proposed Redmi test matrix — default
  settings vs. OEM exemptions granted, `setAlarmClock` vs. `alarm`-package
  foreground-service vs. `ACTION_SET_ALARM` clock-handoff — remains **entirely
  unrun; every cell is open.** In particular:
  - **Short-offset firing after force-stop** (the spike's pass criterion,
    ~1–2 min) is UNVERIFIED.
  - **Overnight alarm reliability on Xiaomi is UNVERIFIED** — an alarm scheduled
    hours ahead, surviving Doze + OEM battery-killing across a full night with the
    app dead, has never been observed. This is the single scariest unknown and is
    explicitly parked for now.
  - **What IS "proven": nothing empirical.** Only the mechanism choice
    (`setAlarmClock`/clock-handoff), the package assessment, and the permission /
    degradation model are settled — all on paper. Treat as hypothesis, not fact.

- **Alarm-persistence Tests 2 & 3 (rules on-device) remain the near-term gate**
  and are unaffected by parking the alarm spike — they block the friend hand-off
  regardless (see below).

# Open questions (unresolved)

## Consent setup: toggle vs. "planner requests → target approves"

**Current:** the target flips a per-member "can plan for me" switch to grant
consent (built in 5c).

**Concern:** the product vision is a friend taking initiative to help someone
who's *overwhelmed* — but the toggle puts all setup burden on the person least
likely to do it (the target). A **request model** (planner asks → target taps
approve) may fit the vision better by letting the initiator drive.

**Decision deferred** until after the first real end-to-end test — decide from how
the loop actually feels, not in the abstract. Do not rebuild before then.

## DST-invalid / ambiguous local times (known edge case, unhandled)

Resolving a wall-clock time in a zone can hit two DST problems:
- **Invalid/skipped** — the wall time falls in a spring-forward gap (that local
  time never occurs).
- **Ambiguous** — the wall time falls in a fall-back overlap (it occurs twice).

`resolveWallTimeToUtc` currently just trusts `TZDateTime`'s default resolution and
does not detect or warn about either case. **India (Asia/Kolkata) does not observe
DST, so this won't bite the first test** — but it must be handled before testing
with anyone in a DST-observing zone (US/EU/etc.). Handling = detect the gap/overlap
and either warn the planner or pick a defined rule.

## Quiet hours = warning-only in v1 (enforcement deferred to the alarm layer)

Spec (§3, §6) frames quiet hours two ways: "no alarm *can be scheduled*" AND
"planner *sees a warning*." There is no alarm layer yet (and none may be built
until directed), so v1 ships only the half that's buildable now: **a non-blocking
warning to the planner in the schedule builder.** Nothing is blocked — "Send for
approval" still works — and the target still approves every item, so consent
stays the real gate. Hard enforcement (refusing to arm an alarm in the window)
lands with the alarm work.

- The target sets their **own** quiet-hours window on their profile
  (`quietHoursStartMinutes`/`EndMinutes`, minutes-since-local-midnight, may wrap
  past midnight). Consent-consistent: nobody else sets your quiet hours.
- **11pm–6am is a fixed, always-on band** flagged regardless of whether the user
  configured a window (spec §6). The two warnings are independent — the builder
  shows whichever apply.
- Warning math lives in a pure helper (`core/timezone/quiet_hours.dart`): no
  alarm/notification/scheduling side effects, just "which warnings apply to this
  instant in the target's tz."

## Self-planning (a user plans for themselves)

The app must be useful solo from day one, so a user can create items for
themselves — not only be planned for by a granted planner.

- **No self-grant; the grant check is bypassed when creator == target.** The
  rules already special-cased `request.auth.uid == targetUid`, and grants live
  under a group — requiring one would force a solo user to have a group.
  Planning for yourself is inherent consent, so no `plannerGrant` record is
  written.
- **`groupId` is optional.** Self-items carry no group (stored as `''`). No
  permission widens: the grant check is simply never reached on the self path.
- **Self-items are born `approved`** and skip the pending queue — approval
  exists to gate what *others* impose on you; approving your own item is pure
  friction. They appear straight in My Schedule with Done/Skip.
- **UI:** "Myself" is always the first target in the schedule builder (present
  even with zero grants, so the builder never dead-ends for a solo user).
  Self-items are **filtered out of Activity** (Activity = people you plan FOR;
  the self-item already lives in My Schedule). The completion→planner **push is
  suppressed when creator == target** — no point notifying yourself.

## Security fix: constrain initial item `status` on create (independent of self-planning)

Enabling self auto-approve forced a look at create-time `status`, which exposed
a latent hole: the old `scheduleItems` create rule did **not** constrain
`status`, so a planner holding an active grant could have written an item
already `status: approved`, **bypassing the target's per-item approval** — the
core consent gate. The app never did this (it always wrote `pending`), but the
rule permitted it.

Create is now constrained by path:
- **planner path (active grant): `pending` only.**
- **self path (creator == target): `pending` or `approved`.**

This closes the bypass regardless of self-planning, and enables self
auto-approve as a side effect. It is **create-only** — it does not touch items
already in Firestore (rules evaluate writes at request time, never documents at
rest; reads and the separate `update` branch are unchanged), so no migration.

## DST-invalid / ambiguous wall times — now handled (was a known gap)

The earlier "unhandled" note is resolved. `resolveWall()` (in `tz_resolver.dart`)
now detects both DST edge cases and applies a defined rule, and the planner is
warned in the builder:

- **skipped** (spring-forward gap — the clock time never happens): push forward
  past the gap (java.time's rule) so the item still fires that night.
- **ambiguous** (fall-back overlap — the clock time happens twice): take the
  FIRST occurrence.

Detection method: label the wall fields as if UTC, shift by the two stable
offsets bracketing the moment (±24h — a DST shift is ≤ a couple of hours and
never twice within a day). A candidate instant is *real* only if the zone's
actual offset there equals the offset used to compute it. Zero real candidates ⇒
gap; two distinct real candidates ⇒ overlap. Covered by `tz_resolver_dst_test`
against real 2026 US + Australia transitions.

### Sub-fix: wall times must be UTC-kind field carriers, not local DateTimes

Root cause found while testing: the app built the entered wall time as a
host-local `DateTime(y,m,d,h,min)`. If those fields land in a DST gap **on the
PLANNER's own device zone**, Dart silently normalizes (shifts) them *before*
resolution — corrupting a time meant for the target's zone, dependent on where
the planner happens to be. Fix: build the wall time as `DateTime.utc(...)`, a
pure tz-agnostic field carrier that never normalizes. The resolver only reads
the fields, so this is the correct representation of "the clock time typed."

## Locale-aware date/time display (worldwide consistency)

The app is worldwide, so it can't show "9:00 PM" in a picker and "21:00" in the
preview on the same screen, nor English-only dates. All user-facing date/time
rendering now goes through ONE helper (`core/format/datetime_format.dart`) built
on `intl`'s `DateFormat`, so the whole app shares:

- **one locale** — the device's, via `Localizations.localeOf(context)`, and
- **one 12h/24h decision** — the device's setting, via
  `MediaQuery.alwaysUse24HourFormat`.

Scaffolding added to make that real:
- `flutter_localizations` + `intl` deps; `GlobalMaterial/Widgets/Cupertino`
  localization delegates and a broad `supportedLocales` on `MaterialApp` (the
  app had NONE before, so `localeOf` always resolved to en_US). This also
  localizes the Material date/time picker dialogs.
- `initializeDateFormatting()` in `main()` so `DateFormat` works in any locale.

The old pure `formatInZone` (hardcoded English day/month names, always 24h) and
`formatMinutesOfDay` (always 24h) are DELETED — every screen (outcomes, pending
approvals, activity, schedule builder preview + DST/quiet banners, profile
quiet-hours labels, the builder's date/time buttons) now uses the helper. The
machine-format `formatWallTime` (persisted `localWallTime`, never shown) stays.

## Target-zone label on the planner's Activity view (b)

The planner's Activity list rendered a bare time (e.g. "09:00") with no cue it
was the TARGET's local time, not the planner's — the most misleading thing in
the app for a cross-timezone pair. Each Activity card now appends the zone and
an explicit qualifier: "for {name} · {localized time} ({IANA zone}, their local
time)". (The target's own views — My Schedule, Pending Approvals — don't need
this: those times are already in the viewer's own zone.)

## Locale coverage = every Material-supported locale, not a hand-picked list

Superseding the earlier ~23-locale `supportedLocales`: the app now accepts ANY
locale Flutter's Material localizations support (~80, spanning South Asia, MENA,
SE Asia, Africa, Latin America) via a `localeResolutionCallback` that returns the
device locale when `GlobalMaterialLocalizations.delegate.isSupported(it)`, else
English. No region is silently dropped, and it's a single guarded callback — no
list to keep in sync.

**Date/time localization vs. UI translation are separate, and only the former is
in scope.** Adding a locale gives correct local date/time formatting on its own:
`intl`'s `DateFormat` carries its own locale data (loaded by
`initializeDateFormatting()`), independent of any translation files. Verified in
a throwaway test that hi/bn/ur/ta/ar/fa/th/vi/id/sw/am/es/pt/zh/ja all format
dates in their own scripts and digits (e.g. Bengali "৯:৩০ PM", Persian
"۲۱:۳۰"), and that the Material date/time PICKER dialogs localize too (Flutter's
bundled translations). Our OWN labels ("Plan for", "Send for approval") stay
English — translating those would need ARB files + gen-l10n, which is NOT done
here and is not required for correct date/time. So a device set to Hindi shows
Hindi dates/times with English UI labels — by design.

**Platform caveat:** on iOS the app must also declare `CFBundleLocalizations` in
Info.plist for the OS to report a given locale to the app; Android delivers the
device locale regardless.

### `CFBundleLocalizations` added — DONE, but UNTESTABLE until iOS is wired up (2026-07-22)

Added the `CFBundleLocalizations` array to `ios/Runner/Info.plist`, listing the
language codes `GlobalMaterialLocalizations` supports (en + ~80). This mirrors the
"every Material-supported locale" `supportedLocales` policy so that, on iOS, the
OS hands the app the user's actual preferred language and `Localizations.localeOf`
resolves to it (Android already delivers the device locale without this key).

**This is verification debt, not verified work.** There is **no iOS target wired
up yet** (no configured Xcode signing / run target that we've built and launched),
so this cannot be exercised: whether iOS actually reports, say, Bengali and dates
render in Bengali digits is **unconfirmed on-device**. Logged here so it doesn't
resurface later as a mystery — the entry is done in source; proving it is blocked
on the iOS build existing. UI strings stay English-only regardless (by design,
above); this only affects date/time locale resolution.

## Timezone snapshot on relocation — v1 = pure snapshot, no re-anchor (decided 2026-07-22)

**Decision: an approved item is a frozen snapshot and stays that way. Chosen
option (1); no behaviour change.**

An item created by `ScheduleRepository.createItem` freezes three fields together:
`localWallTime` (the clock time as typed), `timezone` (the **target's** profile
`homeTimezone` at creation), and `scheduledInstantUtc` (the absolute instant,
resolved once against that zone). Every view renders
`formatInstant(context, item.scheduledInstantUtc, item.timezone)` — the **stored**
zone, never a live device zone — so the item is fully self-contained. Nothing
recomputes when a profile's `homeTimezone` later changes; there is no code path
that revisits an existing item on relocation.

**Behaviour, by who moves:**
- **Planner relocates → nothing changes, and that is correct.** The planner's zone
  is never stored; wall times were always interpreted in the *target's* zone. No
  decision needed for this direction.
- **Target relocates (updates their profile tz) → existing approved items keep
  their frozen instant and frozen zone label.** A "9am Asia/Karachi" item still
  fires at that same absolute moment (05:00 wall-clock in London) and still renders
  its `Asia/Karachi` label. New items use the new zone → a mixed schedule until old
  items are manually recreated.

**Alternatives considered and rejected for v1:**
- **(2) Live re-anchor** (drop the frozen instant, re-resolve `localWallTime`
  against the target's current zone at read/fire time so "9am stays 9am"):
  **rejected — it breaks consent.** The target approved a *specific moment*; silently
  moving it when a profile field changes is a re-consent regression, and it reopens
  the DST gap/overlap edge cases at read time where no planner is present to see the
  warning.
- **(3) Snapshot + detect-and-re-approve** (keep the frozen instant as source of
  truth, but when the target's zone changes, surface affected items and offer
  "keep the moment / shift to same clock time in the new zone," where shifting
  re-runs the resolver and sends the item back through per-item approval):
  **this is the right eventual answer, but it is deferred to the alarm layer** —
  "shift the fire time and re-approve" only fully matters once items arm alarms, and
  it wants the same changed-zone detection plumbing built then. Building it now is
  speculative UI ahead of loop validation.

**Known limitation accepted for v1:** a relocated target's pre-move items fire at
the old zone's clock time until recreated. Bounded, rare at N=2, and *visible* (the
stale zone label makes a mis-timed ring traceable, not a mystery). Revisit as
option (3) when alarm work lands.

# Product decision: reminder / accountability app, NOT an alarm app (decided 2026-07-23)

**This is the load-bearing decision. It supersedes every "alarm" framing earlier in
this file** (see the banners on "Alarm permission & degradation model" and "Alarm
persistence across reboot").

**The product is an accountability / reminder / planner app. We are NOT trying to
wake anyone up.** Push notifications and local reminders are the deliberate
**ceiling on both platforms** — not a degraded fallback we're apologising for. There
is no "true alarm" tier above them.

**What this closes / changes:**
- ~~**We do NOT need `USE_EXACT_ALARM`**~~ and do not have to qualify under Google Play's
  alarm-clock/calendar exemption. (That restriction was the thing that looked like it
  might make an *alarm* premise unshippable — see the 2026-07-23 notifications
  diagnosis. As a *reminder* app the question is moot.)
  > **⚠️ REOPENED 2026-08-19** — see "Exact alarms: the Play-policy assumption was
  > wrong" at the end of this file. Two errors here: (a) the policy's acceptable
  > use case is literally *"the app is an alarm or timer app"*, which is a
  > plausible fit, not an obvious exclusion; and (b) *needing* it was never the
  > question — `SCHEDULE_EXACT_ALARM` reaches the same code path with no Play
  > review at all. "We do not need exact alarms" was a product choice made when
  > reminders were framed as peripheral. They are the core. Undecided pending the
  > spike.
- ~~**We do NOT need `SCHEDULE_EXACT_ALARM`** either~~ (the user-granted exact-alarm
  flow). ~~Inexact scheduling is sufficient~~ — see the reminder-layer write-up below.
  > **⚠️ REOPENED 2026-08-19.** "Sufficient" was asserted, never measured. The
  > accepted drift budget it rests on — *tens of minutes to 1h+ in deep Doze* —
  > is the thing the spike is now measuring. This permission needs no Play
  > review and is available to us today.
- **The earlier iOS finding (no third-party access to the native Clock / AlarmKit
  gating on iOS 26) STOPS being a blocker.** We were never going to fire a true iOS
  alarm; we don't need to. **iOS is back in scope for v1** as a first-class target
  (local notifications via `UNUserNotificationCenter`).
- **The "Android-only in v1" conclusion is withdrawn.** v1 is cross-platform again.
- **iOS 26 is no longer a floor for anything.** Local notifications work far below it.

**What stays true:** ask for the (ordinary notification) permission contextually with
a soft primer; never work around a refusal; a target who declines degrades to
in-app-only, which the loop already tolerates.

# Reminder layer — how we build it with inexact scheduling only (research 2026-07-23)

> **⚠️ PREMISE REOPENED 2026-08-19.** The *research* below is sound and still
> the reference for how inexact scheduling behaves. What is no longer settled is
> the title's word "only". Read this as **the inexact arm of a comparison**, not
> as the chosen design. See "Exact alarms: the Play-policy assumption was wrong"
> at the end of this file.

Framing above means: **no exact alarms.** Reminders may drift; the product tolerates
it ("start your study block" 15 min late is fine; we are explicitly NOT doing "leave
now for your interview"). Research, current docs, cited.

## Android — mechanism, drift, reboot
- **Mechanism:** inexact scheduling via **WorkManager** as the durable substrate,
  optionally with a one-shot inexact `AlarmManager.set()` / `setWindow()` /
  `setAndAllowWhileIdle()` near the fire time. We do **not** use
  `setExactAndAllowWhileIdle` (that needs the exact-alarm permission we've dropped).
- **Drift, and it gets worse under Doze:** in Doze, **alarms don't fire — they're
  deferred to the next maintenance window**, and windows grow farther apart the
  longer the device idles (minutes early on → up to hours in deep idle overnight).
  `setAndAllowWhileIdle` is rate-limited to roughly **once every ~9–15 min per app**
  in idle. WorkManager's minimum periodic interval is **15 min**. So realistic drift:
  **a few minutes when the phone is in active use; tens of minutes to 1h+ in deep
  Doze** (screen off, stationary, unplugged — i.e. overnight is the worst case).
  ([Android — Schedule alarms / Doze](https://developer.android.com/develop/background-work/services/alarms),
  [Exact-alarms denied by default on 14](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms))
- **Xiaomi/HyperOS makes it worse:** aggressive app-standby + background killing
  throttle or drop WorkManager jobs AND block `BOOT_COMPLETED` unless **Autostart is
  on and battery is "No restrictions."** ⇒ **the Group-3 Xiaomi onboarding primer is
  a prerequisite for reliable reminders too, not just for push.**
  ([Xiaomi FCM/background delivery](https://help.pushwoosh.com/hc/en-us/articles/26443659354653-Why-are-push-notifications-not-being-delivered-to-my-Xiaomi-device),
  OEM `BOOT_COMPLETED` blocking is documented across Xiaomi/Samsung/Huawei/OnePlus.)
- **Reboot survival:** **`AlarmManager` does NOT survive reboot** — the OS cancels
  every alarm on shutdown; you'd need a `RECEIVE_BOOT_COMPLETED` receiver to
  reschedule, and even then it won't run until the app has been launched once and is
  OEM-blocked on Xiaomi. **WorkManager persists its work across reboot automatically**
  (own DB, reschedules on boot) — so **WorkManager is the reboot-durability answer**;
  the boot receiver becomes a top-up hook, not the primary mechanism.
  ([AlarmManager cleared on reboot / BOOT_COMPLETED](https://developer.android.com/develop/background-work/services/alarms))
- **Fallback when a local reminder is dropped/late:** the completion→planner FCM push
  path already exists; the *server clock* is authoritative for "was this ever marked
  done," so a missed local ring never corrupts the accountability record — it just
  means the target got reminded late or not at all on-device. Acceptable at this tier.

## iOS — mechanism, accuracy, reboot, and the one hard limit
- **Mechanism:** local notifications via **`UNUserNotificationCenter`** with
  `UNCalendarNotificationTrigger` / `UNTimeIntervalNotificationTrigger`. Same
  notification-authorization permission as push; no special entitlement.
- **Accuracy:** **fires on time.** No Doze equivalent; the system delivers scheduled
  local notifications at the scheduled minute (minor delay only under Low Power Mode).
  **iOS is the MORE precise platform here** — the inverse of Android.
- **Reboot / app-not-running:** the notifications are **held by the system, not the
  app process**, so they fire even if the app is never relaunched and persist across
  app updates (same bundle id). Reboot delivery is generally preserved — **verify
  on-device when iOS is wired up** (the docs are explicit about app-update/quit
  persistence, less so about power-cycle).
  ([Apple — scheduling local notifications](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html))
- **The hard limit that shapes the design: 64 pending local notifications per app.**
  iOS keeps only the **soonest-firing 64** and silently discards the rest (a repeating
  trigger counts as 1). ⇒ we cannot "schedule everything up front." We need a
  **rolling-window scheduler**: schedule the nearest N, and top up (on app open, and/or
  when the completion push arrives) as they fire. This is the iOS analogue of Android's
  Doze problem — different engineering, same UX goal.
  ([64-limit, developer forums](https://developer.apple.com/forums/thread/811171),
  [flutter_local_notifications #2312](https://github.com/MaikuB/flutter_local_notifications/issues/2312))

## The honest cross-platform picture
- **Android:** the hard problem is *"will it fire on time"* — Doze + OEM killing. Needs
  WorkManager + the Xiaomi primer; accept minutes-to-an-hour drift in deep idle.
- **iOS:** the hard problem is *"the 64-pending ceiling"* — timing itself is reliable
  and reboot-durable for free. Needs a rolling-window top-up scheduler.
- **Both are shippable as a reminder app.** Neither is shippable as an alarm app, which
  is exactly why we made the product decision above. STILL PARKED until directed — this
  is now a "how we'll build it" record, not a "can we ship it" open question.

# New scope grouping + design decisions (2026-07-23) — DESIGN ONLY, no code yet

Six requested features, grouped. Prerequisite that is not itself a group: the
**foreground-banner fix** (old step 2 — `onMessage` currently only `debugPrint`s, so
any push is invisible to someone with the app open). It gates Group A and is a real
bug regardless. Build it first / alongside A.

## Group A — notification events on ONE generalized path (agreed, with a design caveat)
Generalize the Worker from outcome-only to an **event-discriminated** endpoint firing
push for: (1) planner creates plan → **target** notified; (2) target approves/rejects
→ **planner** notified; (3) target marks done/skip → **planner** notified (already
live — fold in). Keep the existing dedup guard, grant check, token cleanup.

**Caveat the "one endpoint" framing must account for — the events are NOT symmetric:**
- The live Worker authorizes **caller == the item's target** and always notifies the
  **planner (creator)**. That holds for events (2) and (3) — both are target-triggered.
- **Event (1) is planner-triggered** (caller == `createdByUid`), notifying the
  **target**. So the endpoint must **branch authz + recipient by event type**, not
  assume caller==target. One endpoint, yes; one authz rule, no.
- **Dedup:** `notifiedOutcome` is outcome-specific. Generalizing needs a per-event
  guard (e.g. `notified.{created|decided|outcome}`) so one event firing doesn't
  suppress another on the same item.
- Recipient tokens: event (1) reads `users/{targetUid}/fcmTokens`; (2)/(3) read the
  planner's. The `notify.js` recipient-resolution branch already centralizes this —
  extend it, don't fork it.

## Group C — cancel-before-accept — folds into A's path + needs a rules change
Planner withdraws a still-**pending** plan; **refused once approved.** The domain enum
already has `withdrawn`. Two moving parts:
1. **Rules change (new):** today `scheduleItems/{targetUid}/items/{itemId}` allows
   `update` **only by the target**. Withdrawal is a **creator/planner** write, so we
   must add a narrow rule: the item's `createdByUid` may update **status `pending` →
   `withdrawn` ONLY** (no other field, and denied if status != pending — that's what
   enforces "refused once approved").
2. **It's just event (4) on Group A's path:** "plan withdrawn → notify target."
- **What the target sees — RECOMMENDATION: show as withdrawn, do NOT vanish silently.**
  A pending item the target may have already read shouldn't disappear without a trace
  (looks like a bug, erodes trust). Render it greyed as **"Withdrawn by {planner}"**,
  non-actionable, dismissible/auto-expiring so the queue doesn't accrue tombstones.
  Push: low-priority, and arguably only if the target had already *seen* it (ties to
  Group B) — if they never saw it, silently removing from the queue is fine.
⇒ **Grouping note: C is not a separate notification path. It's one rules change + one
more event registered on A.** Sequence it right after A.

## Group B — "seen" status — RECOMMENDATION: item-level, not app-level
Question was: does "seen" mean *opened the app* or *opened that specific item*?
**Recommend item-level ("she opened this plan"), for both usefulness and creepiness.**
- **App-level = the WhatsApp "last seen online" pattern** — it leaks when you were on
  your phone at all, which is ambient monitoring unrelated to any plan. This app
  already sits near the surveillance line; app-level pushes it over.
- **Item-level is scoped to the shared accountability object** — "has my plan reached
  her / is she sitting on it" is exactly the signal the planner legitimately needs, and
  nothing beyond it. Less surveillance-y *because* it's bounded to the artifact you both
  already share, not the person's general activity.
- **Scope it to pending items only:** store `seenByTargetAt` once, set when the target
  opens the item detail while `status == pending`. After approve/reject the decision
  supersedes "seen," so the bit is moot. Planner UI: "Seen · not yet responded."
- **No push for "seen"** (a seen-ping would be noisy and is the creepy end). Passive
  field the planner reads. Independent of Group A.

### Group B — the three states, incl. the ABSENT state (clarified 2026-07-23)
The *absent* signal is the more valuable one — "she hasn't looked in three days" tells
the planner more than "she looked and is sitting on it." Define all three, all showing
elapsed time, none of them a nag (no reminder-to-respond; just legible state):
- **Not seen:** `Sent 3d ago · not seen yet` ← the high-value one.
- **Seen, pending:** `Seen 2h ago · not yet responded`.
- **Decided:** seen-bit is moot; show the decision.
**Elapsed time must go through the locale-aware helper** — extend
`core/format/datetime_format.dart` with relative-time formatting; never hardcode an
English "3d ago" (standing worldwide requirement). Note: Group B (pending-only) and
Group D archive (terminal-only) are **disjoint by item state**, so they never interact.

## Group D — "delete for me" — RECOMMENDATION: do NOT build it; solve the real worry
The user's dilemma is real and both horns are bad:
- *If the planner still sees a target-deleted item* → "delete for me" **misleads** the
  target the moment the planner references it.
- *If the planner stops seeing it* → the target can **silently erase accountability
  history**, which defeats the product.
**These are unresolvable because a shared accountability ledger and a unilateral
per-party delete are fundamentally incompatible.** So:
- **The actual worry is access-control, not data-model:** "someone picks up my
  *unlocked* phone." Solve it with an **app lock (biometric/PIN on open) + hide-in-
  recents / `FLAG_SECURE`** so content isn't shown in the app switcher or
  screenshotted. This addresses "someone opens my app" **without touching the shared
  record** — no misleading, no erasure. **This is the recommended v1 answer.**
- **Reject "delete for me" as history deletion.** Accountability data should be
  **append-only from the target's side**: you can mark done/skip, you cannot make a
  miss disappear.
- **Streaks/stats seal it:** if deleted items still counted toward stats → a **lie by
  omission** (the number reflects data the user was told was gone); if they DON'T count
  → the target games stats by deleting misses. Either way deletion + stats is corrupt —
  another reason not to build it.
- **If a genuine "this item is wrong" need arises,** serve it with Group C withdrawal
  (before accept). *(The earlier "mutual, logged removal" future-out is **superseded**
  by the per-user soft-archive below — no handshake needed.)*

### Group D — CHOSEN: per-user, UI-only soft-archive of SETTLED items (decided 2026-07-23)
Supersedes the mutual-clearing idea. Each user may **archive (hide from their own view)**
a **settled** item; the Firestore document is **untouched**; the other party's view is
unaffected and isn't told. This is honest in a way "delete for me" was not: the original
objection was that the planner still saw an item the *target thought was gone* — but
**post-outcome the outcome is already on the record and both parties already know it**,
so hiding a settled item from your own view hides it from no one.

**Why it beats the handshake:** no pending state, no notify, no accept/decline UI (far
less to build); stats stay honest *for free* because they read the **record, not the
view**; nobody can touch anyone else's data; and the data survives for a future summary.

**Shape — CHOSEN: store the archive set in the archiver's OWN subtree, NOT on the shared
item doc.** i.e. a per-user doc such as `users/{uid}/state/archived` holding an
`itemId → archivedAt` map (one cheap read to filter; `archivedAt` comes free; unarchive =
delete the key). This is a deliberate refinement of the "hiddenBy array on the item"
sketch: keeping the flag **off** the shared doc means the planner never needs write access
to the item to hide it, which is truer to "nobody can affect anyone else's data," and the
rules become trivial. (Subcollection `users/{uid}/archivedItems/{itemId}` is the drop-in
scale-up if the map ever gets large — not needed at this scale.)

**Constraints (enforced):**
- **Settled-only.** Archive is offered ONLY on `done`/`skipped` items — never `pending`
  or `approved`-not-done. (Rationale: hiding a live item would let you bury a plan you
  never responded to.) **Enforced at the UI** (surface the action only on settled items).
  We accept client-only enforcement here because the flag is per-user and view-only, so a
  bypass affects **only the bypasser's own view** — no cross-user and no stats impact; not
  worth paying a rules `get()` on the item for. Server-enforcement is available if ever
  wanted (rule reads the item's `outcome`), explicitly declined for now.
- **Filter at the query/repository layer, once** — apply the archive filter in the shared
  data layer so it covers EVERY surface a settled item appears on (target schedule,
  planner activity feed, outcomes list). Per-screen filtering would leak.
- **Never called "delete" anywhere** — action + view use **"Archive" / "Archived"** (or
  "Hide"/"Hidden"); UI copy and code identifiers must not imply data is gone. "Archive"
  is preferred: it connotes retrievable, which it is.
- **Reversible — CHOSEN.** Not one-way. Provide a **"Show archived" / Archived view** to
  unarchive (just remove the map key). One-way hiding would itself feel like the "delete"
  we're avoiding; since the data is untouched, reversibility is free and reinforces
  "archived ≠ deleted."
- **Rules: own-flag only.** Owner-only read+write on the archiver's own subtree:
  `match /users/{uid}/state/{doc} { allow read, write: if signedIn() && request.auth.uid == uid; }`
  (mirrors the `fcmTokens` pattern). A user structurally cannot set the other party's
  archive flag — it lives in their own subtree.

**Answers to the three questions:**
1. **Any reason it doesn't work?** No dealbreaker. Watch-items: enforce settled-only and
   filter at the repo layer (both above); archiving a *terminal* item is stable (terminal
   docs don't change, so nothing un-hides unexpectedly). The refinements above are the
   whole of it.
2. **Does it change the Group D known gap?** It **narrows but does not close** it, and the
   gap stays as logged. Archive is **hide, not remove** — the record is still append-only
   from the target's side, so "the target cannot remove an item from the shared record"
   remains literally true. What changes: the target can now declutter their *view* of
   *settled* items. The residual gap is **pre-settlement** — a target stuck with an
   `approved`-not-done item they don't want, whose only exits are done/skip. See the
   Known-gap note below.
3. **Does it change how a future summary reads data?** Invisible to it — **as long as the
   summary reads the canonical record (`scheduleItems`/outcomes), not the archive-filtered
   view.** The archive flag lives in a user subtree the aggregator never joins. **Load-
   bearing constraint on that future feature:** summaries MUST read the record layer, not
   reuse the hidden-filtered list query — else archived items silently vanish from stats
   and we've recreated the lie-by-omission we're avoiding. **The summary feature is a
   benefit of this shape, not a dependency — we are NOT committing to building summaries.**

### Group D — KNOWN GAP (named, not an oversight; clarified 2026-07-23)
With app-lock chosen over delete-for-me, C's withdrawal being **planner-side only**, and
archive being **settled-only + hide-not-remove**, **the target has no way to REMOVE an
item from their own record.** Pending → they can reject; settled → they can archive (hide)
but not remove; `approved`-not-done → the only exits are done/skip, no removal. This is
append-only-from-the-target's-side working **as intended** — it's the accountability
point, not a bug. **Accepted for v1, logged so it's already named if it surfaces in
testing.** Future out (if ever needed): a target-initiated removal the planner confirms
(mutual + logged) — deliberately NOT built now.

**All of the above is design/logging only. No code until the user picks per group.**

# Notifications diagnosis — "nothing fires" (investigated 2026-07-23)

First real-pair APK run: core loop validated (build/approve/mark-done all show on
both sides via the **in-app** views). Reported symptom: **no notification of any
kind ever fires, no error surfaced.** Split into the two independent systems and
diagnosed each against the code + current vendor docs. **Nothing built was found
broken; the gaps are things never built (correctly, per build order) plus a
device-layer suspect. No code changed — diagnosis only, awaiting a transport pick.**

## System 1 — LOCAL notifications (on-device scheduled reminders for your own items)
**Verdict: NOT built. This is the parked alarm/reminder layer — its absence is by
design, not a regression.** There is *no code path that could ever fire a local
reminder.* Concretely:
- No `flutter_local_notifications` dependency (pubspec has only `firebase_messaging`).
- No `zonedSchedule` / `AlarmManager` / any scheduling call anywhere.
- No notification channel is created in code. The manifest's
  `high_importance_channel` id is only an **FCM fallback pointer**, never registered
  by a plugin.
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` are **not declared** (only `INTERNET`
  and `POST_NOTIFICATIONS` are).
- `POST_NOTIFICATIONS` **is** requested at runtime — but incidentally, via
  `firebase_messaging`'s `requestPermission()` on sign-in (for FCM). So the Android
  13+ runtime prompt does appear; the permission is not the blocker.
- No Xiaomi Autostart / battery-exemption prompting exists.

Design note for when reminders ARE built (not now): under the Android 14 change,
`SCHEDULE_EXACT_ALARM` is **denied by default** for newly installed apps targeting
API 33+, and `USE_EXACT_ALARM` (auto-granted, non-revocable) is **restricted by
Google Play policy to alarm-clock/calendar apps** — an accountability app likely
does **not** qualify, so the reminder layer must be designed around either the
user-granted `SCHEDULE_EXACT_ALARM` flow or inexact alarms. Flagged, not decided.
> **⚠️ CORRECTED 2026-08-19.** "Likely does not qualify" was a guess about how a
> reviewer would classify us, recorded in a hedge and then read downstream as a
> finding. The policy text is narrower than the paraphrase and the disjunction at
> the end of this paragraph is the important part: **`SCHEDULE_EXACT_ALARM` was
> always open to us.** See the entry at the end of this file.
(Sources: Android 14 "Schedule exact alarms are denied by default"; Play exact-alarm
policy — cited in the session transcript.)

## System 2 — PUSH notifications (planner pinged on outcome; target pinged on schedule)
- **FCM is fully set up.** Permission requested on sign-in; token written to
  `users/{uid}/fcmTokens/{token}`, refreshed on rotation, deleted on sign-out;
  background handler + tap-routing wired.
- **Already on FCM HTTP v1, not the deprecated legacy API.** The Worker mints an
  OAuth2 access token from the service account (`google-auth.js` + `fcm-rest.js`).
  The legacy HTTP/XMPP send API was deprecated 2023 and **shutdown began
  2024-07-22** — it does not apply to us; we are on the correct API.
- **Outcome push (target marks done → planner pinged) is built AND the Worker is
  live.** Verified from here: `GET` → 405, `POST {}` → 400 `invalid-body` (the
  Worker's own validation). Wired into `outcome_screen.dart` → `HttpOutcomeNotifier`
  → live Worker.
- **The OTHER direction — "I get pinged when the planner schedules something" — was
  never built.** The Worker only handles outcomes; there is no push on item-create
  or invite. That half of the reported symptom is a genuine missing feature.
- **Foreground gap:** `onMessage` only `debugPrint`s — no in-app banner. FCM
  `notification` payloads auto-display in the tray **only when backgrounded/
  terminated**. If the recipient's app is open when the outcome lands, they see
  nothing. Deliberate v1 choice, but it masks a working push during a live test.

### Why the (built, live) outcome push shows nothing — ranked suspects
1. **Xiaomi/HyperOS killing FCM (prime suspect — both test devices are Xiaomi).**
   MIUI/HyperOS blacklists background delivery for apps without **Autostart** on and
   battery set to **No restrictions**; FCM is well-documented as unreliable there
   until the user enables both. The app does not prompt for either.
2. **Recipient app foregrounded during the test** → no banner (see foreground gap).
3. **Recipient FCM token never written** (`getToken` failed / permission declined) →
   Worker returns `no-tokens`, silent no-op. Would show in Crashlytics as the
   token-save failure we record.
4. **Notification permission actually denied** on the recipient device.

### The decisive diagnostic (no code, no USB) — run BEFORE changing anything
`wrangler tail` on the Worker prints the per-call `reason` for every outcome. Have
the friend mark an item done while tailing:
- `reason:"sent"` but nothing appears → **device-side** (Xiaomi autostart/battery, or
  foreground-only banner). Fix is settings + a foreground display, not the transport.
- `reason:"no-tokens"` → recipient token never registered.
- `reason:"no-active-grant"` / `"self-planned"` / `"already-notified"` → recipient/
  dedup resolution, not delivery.
- **No log line at all** → the app never reached the Worker → check Crashlytics for
  the recorded "outcome push to Worker failed" error (permission/network/endpoint).

## Transport options for the push side (free, no card) — comparison + migration cost
Constraint restated: **no payment, prefer no card on file.** The app **already has
option (c) built, deployed, live, and on HTTP v1.**

- **(a) Client-side FCM HTTP v1 from the completing device** — service-account
  private key ships inside the APK; anyone can extract it and push to any user / abuse
  the project. No server-side dedup or dead-token cleanup. **Migration cost to
  release: blocking** — must be ripped out and replaced with a server path. Reject.
- **(b) Supabase Edge Functions** — free, no card, 500K invocations/mo, but **free
  projects pause after 7 days idle** (fatal for an always-on push endpoint) and it is
  a second vendor holding the service account on a different runtime (Deno/TS).
  **Migration cost: lateral** — discards the working Worker and adds an idle-pause
  failure mode. Reject.
- **(c) Cloudflare Workers — RECOMMENDED.** Free, no card, 100K req/day, commercial
  use allowed, never pauses. **Already built + live**, holds the key server-side, on
  HTTP v1. **Migration cost: lowest** — the *policy* lives in transport-agnostic
  `notify.js`; the card-day plan already swaps `outcomeNotifierProvider` →
  `NoopOutcomeNotifier` and reuses `notify.js` verbatim in a Firestore-triggered
  Cloud Function. Keep indefinitely, or swap only the trigger later.
- **(d) Blaze with a $0 budget alert** — Cloud Functions free allowance (2M
  invocations/mo etc.) almost certainly covers us at any realistic scale, and it is
  the eventual "right" architecture (server-side trigger closes the N>2 silent-miss
  gap). **But it requires a card on file — the exact thing to avoid — and a budget
  alert only *notifies*, it does NOT cap spend.** This is the documented **card-day**
  path, not a now-path.

**Recommendation: stay on (c).** There is no transport problem to solve — the send
path is live and on the modern API. The failure is almost certainly device-side
(Xiaomi) or the foreground-banner gap. (c) is free, cardless, and was explicitly
architected so the later move to (d)/Blaze is a one-line provider swap with zero
rewrite of `notify.js`. Confirm with `wrangler tail` before building anything.

**Awaiting user's pick before any code changes.** (Sources for this entry:
Firebase FCM legacy→v1 migration notice; Android 13 POST_NOTIFICATIONS + Android 14
exact-alarm behavior change; Cloudflare Workers, Supabase, and Firebase Blaze
free-tier docs — all cited in the 2026-07-23 session transcript.)

# PRODUCTION INCIDENT (2026-07-24) — deployed rules were stale for 6 days

Found while diagnosing why the outcome push reported `no-tokens`. Root cause was
not the push stack at all: **the deployed Firestore ruleset was six days behind
`firestore.rules` in git.** A correct rules file in the repo proved nothing about
what was being enforced.

**Live ruleset:** `57de3ae0-a15a-4963-af6b-18fc2868e6d9`, deployed
**2026-07-18T17:42:14Z**. It was the newest of only 6 rulesets, all pushed 7/15–7/18.
Nothing was deployed after that until today.

Two separate defects rode on that staleness.

## (A) Consent bypass — LIVE 2026-07-18 → 2026-07-24. Severity: high.

The deployed `scheduleItems/{targetUid}/items/{itemId}` create rule was:

    allow create: if signedIn()
      && request.resource.data.targetUid == targetUid
      && request.resource.data.createdByUid == request.auth.uid
      && (request.auth.uid == targetUid
          || callerHasActiveGrant(targetUid, request.resource.data.groupId));

**No constraint on `status`.** Any planner holding an active grant could create an
item already `status: 'approved'`, skipping the target's per-item approval — the
consent mechanic the entire product rests on ("A approves each item" in the core
loop). Not a theoretical hole: the grant is exactly what a friend-planner holds.

- **Never closed at:** `57de3ae0` deploy, 2026-07-18T17:42:14Z. (Earlier rulesets
  had the same gap — the constraint has never been enforced in production.)
- **Fixed locally in:** `ea87d6d`, 2026-07-21 22:14 -0500. Sat undeployed 3 days.
- **Deployed:** 2026-07-24.

The fix (now live) splits the two creation paths — planner may create `pending`
only; self-planning may create `pending` or `approved`, since consent is inherent:

    && (
      (request.auth.uid == targetUid
          && request.resource.data.status in ['pending', 'approved'])
      || (callerHasActiveGrant(targetUid, request.resource.data.groupId)
          && request.resource.data.status == 'pending')
    )

### Exploitation audit — result: NOT EXERCISED. No data integrity loss.

Audited every `collectionGroup('items')` doc in `time-app-1e1c9` (read-only, via
Firestore REST). **9 items total: 7 planner-created, 2 self-planned.**

Discriminator: a pre-approved create writes `status:'approved'` and `decidedAt` in
the *same* write as `createdAt` (identical server timestamps, `createTime ==
updateTime`). A genuine approval writes `decidedAt` in a later update.

**All 7 planner-created items show `decidedAt` strictly later than `createdAt`,
with human-plausible gaps** (14s, 15s, 16s, 66min, 80s, 9h, plus one `rejected`).
Every one went through a real target decision. Sample:

| item | createdBy → target | status | createdAt → decidedAt |
|---|---|---|---|
| `gkqNGOnxckqg6tuLdvO7` "Namaz" | `42ml93AS…` → `P5eNrQfN…` | approved | 07-23 06:35:04 → 15:48:39 |
| `rgo6xYwi2ab7FhxUDFTV` "Please do breakfast on time" | `P5eNrQfN…` → `42ml93AS…` | approved | 07-24 15:23:00 → 15:24:20 |
| `0QHHr49nf18T9EF1ITU8` "test reject" | `brY8JaR7…` → `42ml93AS…` | rejected | 07-17 05:15:15 → 05:15:30 |

**Conclusion: the bypass was reachable but never used.** No item in the database
reached `approved` without its target approving it. The approval flow can be
represented to the friend-tester as having behaved correctly throughout — the
guarantee was unenforced, but it was never violated.

## (B) `_registeredUid` latch — known defect, NOT fixed by the deploy

`messaging_service.dart:41-42` sets the dedup latch *before* any `await`:

    if (_registeredUid == uid) return;
    _registeredUid = uid;          // set BEFORE the await that can fail

`requestPermission()` (line 47) also sits **outside** the `try`. Consequences:

- One failure — the rules denial, a network blip, any transient Firestore error,
  or `requestPermission()` simply hanging — **disables token registration for the
  entire app session.** No rebuild retries, because the latch already matches.
- **Zero user-visible signal.** The app looks fine. The failure only surfaces much
  later as a push that silently never arrives.
- If `requestPermission()` *hangs* rather than throws, there is not even a
  Crashlytics record — the silent no-token state with no evidence anywhere.

**Deploying the rules removed today's trigger, not the failure mode.** The next
transient error reproduces the identical silent state.

**Proposed fix (NOT BUILT — queued, see below):**
1. Set `_registeredUid` **only after** a confirmed successful token write.
2. Move `requestPermission()` **inside** the `try`.
3. Add a **timeout** on `requestPermission()` / `getToken()` so a hang fails loudly
   instead of hanging forever.
4. Add a **retry path** — on app resume and/or auth-state change — so a transient
   failure self-heals instead of persisting for the session.

**Queue position (user's call, 2026-07-24): immediately after the banner test,
AHEAD of Group A.** Rationale: Group A adds three more event types on the same
delivery path; shipping them on a registration path that can silently disable
itself would multiply the blind spot rather than expose it.

## (C) Process note — rules deploy separately from code

**A correct `firestore.rules` in git proves nothing about what is enforced.** Rules
ship via `firebase deploy`, not with the app build or the commit. This incident cost
6 days of an unenforced consent guarantee and one fully misdiagnosed bug.

Standing rules from here:

- **Any change touching `firestore.rules` carries a deploy step in the same commit's
  checklist.** The commit is not done until the ruleset is deployed and the new
  ruleset id is confirmed live.
- **On any unexplained `PERMISSION_DENIED`, check the deployed ruleset id FIRST** —
  before reading the local rules file, and before forming any hypothesis from it.
  Fetch it from the Rules API (`firebaserules.googleapis.com/v1/projects/
  time-app-1e1c9/releases` → `rulesetName` → fetch source) or read it in console at
  Firestore → Rules, which shows the *deployed* text plus its deploy timestamp.
- **Diagnostic lesson from this session:** rules were eliminated as a cause by
  reading `firestore.rules:56` in the repo. That elimination was wrong and cost a
  full diagnostic round-trip. Reading a local config file is never evidence about a
  separately-deployed system.

# 2026-07-24 (later) — FOREGROUND DELIVERY VERIFIED; background still open

## Rules deploy confirmed live

Ruleset `57de3ae0-a15a-4963-af6b-18fc2868e6d9` (stale, 2026-07-18) replaced by
**`45d5f8bc-73d7-463f-99f6-22100b790826`, deployed 2026-07-24T15:55:56Z**. Fetched
the deployed source from the Rules API and confirmed **both** hunks are present in
what is actually enforced, not just in git:

- `match /fcmTokens/{token}` — deployed line 55.
- `status in ['pending', 'approved']` create constraint — deployed line 145.

The consent bypass in (A) above is closed **in production**, not merely in the repo.

## Token registration works — the six-day blackout is over

First tokens ever written to `users/{uid}/fcmTokens` in this project:

| account | tokens | first write |
|---|---|---|
| `42ml93AS…` (owner) | 2 | 2026-07-24T15:57:57Z |
| `P5eNrQfN…` (friend/planner) | 1 | 2026-07-24T16:06:11Z |

Two docs on the owner account is expected, not a defect — one per device/registration
(the doc id is the token, so a rotation or a second device adds a row). The Worker
sends to all of them and deletes any that FCM rejects.

**Note for the latch-fix commit (B):** `saveToken` writes `createdAt:
serverTimestamp()` on every `merge` write, so `createdAt` is overwritten on each
re-registration and actually means "last registered at" — hence `createdAt`
(16:06:35Z) reading *later* than the doc's own `createTime` (15:57:57Z) above. Cosmetic,
but if we're editing that file anyway, `createdAt` should be write-once.

## FOREGROUND DELIVERY — VERIFIED END TO END (first time)

**Full chain proven:** Worker (`sent:1`) → FCM → recipient device → `onMessage` →
in-app banner rendered with the View action, recipient foregrounded at the time.

The earlier "she saw nothing" report was a **reporting gap, not a failure** — it
predated the token fix, and the later run did deliver. The foreground-banner fix
from `c3b921e` **works**.

**The "unverified delivery path" caveat is retired.** Delivery is no longer
hypothetical: the transport, the Worker's authz/recipient resolution, the token
lookup, and the foreground render are all now exercised against a real second person
on a real device.

## Rules Test 2 — on-device happy path PASSED

The two-account sequence from the 2026-07-18 debt list, run with a real second
person on a real device:

    A creates group → B joins by code → A grants B planner →
    B creates item → A approves → A marks Done → B receives the outcome

Every step succeeded. Test 2 is the deadline condition recorded in that debt
list — *"Tests 2 & 3 are due BEFORE the debug APK goes to the friend"* — and
this discharges it **for Test 2 only**.

**Test 3 is still NOT run.** Revoking the grant and confirming B's item-create is
refused `PERMISSION_DENIED` remains open (CLAUDE.md "Parked & unverified", item
2). Test 2 shows the rules do not break the app; it says nothing about whether
they refuse what they are meant to refuse. Do not let one stand in for the other.

**Provenance, stated because this entry is back-dated.** Written 2026-08-21. It
is a transcription of the assertion that had been carried in CLAUDE.md's
"VERIFIED 2026-07-24 — do not re-open these" list since that day — not a fresh
observation and not new evidence. Two details are therefore left unclaimed: the
exact time, and whether the run sat on the `45d5f8bc…` ruleset deployed at
15:55:56Z that morning. The same-day grouping implies it, but the original record
does not say so, and an inferred ruleset id is exactly the kind of thing this
file exists to stop people quoting as fact.

**Why it is being written down now.** It existed in exactly one place in the
repo. A condensation pass over CLAUDE.md on 2026-08-21 proposed collapsing that
list, which would have deleted the only record of the pass — while the debt list
above still read "has **not** been run on a device". The file would then have
asserted the opposite of the truth, with nothing to catch it. A verification
result that lives in one summary line and nowhere else is not recorded, it is
remembered.

## REMAINING OPEN QUESTION — backgrounded / killed-app delivery

**Foregrounded is precisely the case that sidesteps Xiaomi.** An app in the
foreground has a live process, so the message is handed to `onMessage` without ever
depending on OEM background policy. That is *not* how the app is used: in real use
nobody is sitting in the app when a plan arrives.

**Still unproven: system-tray delivery to a backgrounded or process-killed app** on
HyperOS. This is the case the whole reliability premise rests on, and it is exactly
what the **Autostart / battery-optimization primer** exists to address — the primer's
placement in the onboarding order should be decided from this test's result, not
before it.

Nothing about the foreground result predicts the background result. Do not treat
delivery as "working" in the general sense until a backgrounded run is recorded here.

## Revised build order (user's call, 2026-07-24)

1. ~~Verify deploy + tokens landed~~ — **DONE, this entry.**
2. **`_registeredUid` latch fix** — the four-part proposal in (B) above. Diff, one commit.
3. **Group A** generalized endpoint (event discriminator, per-event dedup, authz
   branched by event since plan-created is planner-triggered) **+ Group C's
   withdrawal event**. Diff, one commit.

# 2026-07-24 (later still) — Group A SHIPPED: event-discriminated push + Group C withdraw

Generalized the outcome-only Worker into one event-discriminated endpoint, and
added Group C's withdraw event. Code committed; deploy is coupled (see below).

## The four events — NOT symmetric

`event` is a discriminator, never trusted as state: the Worker re-reads the item
and DERIVES the sub-type from Firestore, so a caller cannot assert an
outcome/decision that didn't happen.

| event      | triggered by     | notifies         | sub-type (from Firestore)        |
|------------|------------------|------------------|----------------------------------|
| created    | planner (creator)| target           | —                                |
| withdrawn  | planner (creator)| target           | —                                |
| decided    | target           | planner (creator)| approved \| rejected (item.status)|
| outcome    | target           | planner (creator)| done \| skipped (outcome.result) |

Recipient is computed structurally (`NOTIFIES_TARGET.has(event) ? target :
planner`), so the recipient is ALWAYS the party that did not act — the actor can
never be notified about their own action. The one coincidence (self-planned,
creator == target) is guarded three ways: the client skips the call, and the
Worker returns `self-planned` for every event before sending.

**Authz is branched, not uniform.** `index.js` requires caller == creator for
planner-triggered events (created/withdrawn) and caller == target for
target-triggered events (decided/outcome), plus `item.targetUid == targetUid` so
a caller can't aim a push at another target's subtree. One endpoint, one authz
BRANCH — the "one endpoint" framing explicitly does not mean one rule.

## Per-event dedup — FLAT fields, deliberately not a nested map

Each event has its own guard slot so one firing can't suppress another:
`notifiedCreated` / `notifiedDecided` / `notifiedOutcome` / `notifiedWithdrawn`,
each stamped only after `sent > 0`.

These are FLAT top-level fields, not a nested `notified.{created|decided|...}`
map, and that was a correctness choice, not a style one. The Worker's Firestore
REST `patchDoc` builds its `updateMask` from top-level keys and the value encoder
only handles flat scalars. Writing a nested `{notified: {...}}` under a top-level
`notified` mask would REPLACE the whole map and clobber the sibling slots — the
exact opposite of the guarantee. Flat fields are independent by construction.
Bonus: `notifiedOutcome` keeps the old name, so items already outcome-notified by
the pre-Group-A Worker stay deduped across the cutover.

## Group C withdraw — the one non-target item write, and its rules dependency

Planner may withdraw a plan they created while it is still `pending`
(planner_activity → `withdraw()`), flipping status to `withdrawn`. This is the
ONLY item write a non-target may make, gated by a tightly-scoped
`firestore.rules` update branch: caller == `createdByUid`, current status
`pending`, new status `withdrawn`, and `affectedKeys().hasOnly(['status',
'withdrawnAt', 'updatedAt'])` — cannot resurrect a decided item or touch
title/time. Planner edit is still deferred.

## DEPLOY COUPLING — the lesson from earlier today, applied

The POST body changed `{outcome}` → `{event}`, and withdraw needs the new rules.
So this is a coordinated cutover, and rules/Worker MUST go live BEFORE any app
install:

1. Deploy `firestore.rules`, then VERIFY the deployed source (not the green
   deploy) shows the withdraw branch and a new ruleset id.
2. Deploy the Worker.
3. Only then rebuild + install.

Mismatch during the window is SAFE — analyzed exhaustively: neither version's
body passes the other's input validation, so every mismatch fails closed at the
400 gate before any Firestore/FCM work. Worst case is one missed push; no state
corruption, no double-write, no double-send (the client writes state once, then
fires the push as a separate best-effort call with no retry and no write-back).

## Retest matrix (run once deployed + installed, `wrangler tail` throughout)

Expect `sent:1` per event and the banner on the RIGHT device, foregrounded:
- created:   she plans an item for me   → I am notified
- decided:   I approve                  → she is notified
- outcome:   I mark done                → she is notified (already proven)
- withdrawn: she withdraws a pending item → I am notified

Backgrounded delivery for all four remains the open question (foreground
sidesteps HyperOS) — do not mark any event "reliable" on a foregrounded pass.

# 2026-07-24 (status stamp) — Group A deployed + verified; retest BLOCKED on friend

Where we are, so nothing is lost until the pair session:

**DONE + verified against deployed reality (not just green output):**
- Firestore rules deployed — ruleset `1ced7bb3-ddc8-4dfe-ab27-ae35e60d4a63`
  (2026-07-24T21:18Z). Withdraw branch confirmed IN the deployed source; the
  earlier fcmTokens block + item-create status constraint did NOT regress.
- Worker deployed on the `{event}` contract. Negative probe (old-shape
  `{outcome}` body) now returns 400 invalid-body — positive proof the new
  contract is live (the old Worker would have returned 401).
- Owner token registered on the new build (`42ml93AS…`, token `eACQrpNW…`). The
  latch-fix write-once schema is confirmed live: an existing token re-registered
  with `createdAt` FROZEN and `lastRegisteredAt` advanced.
- Install-over from the shared `app-debug.apk` file proven (not just USB).

**BLOCKED — needs the friend online (two real people):**
- The four-event foreground retest (created / decided / outcome / withdrawn).
  ALL four require creator != target; self-planned items are skipped by the
  self-planned guard, so none can be tested against oneself on one account.

**Solo options assessed while waiting (2026-07-24):**
1. Worker-contract happy path IS reachable solo, but needs a SECOND sender —
   switching accounts on one phone deletes the target's live token via
   `signOutWithTokenCleanup`, so single-device account-switch self-defeats. Clean
   path: real Redmi stays signed in as target (foregrounded, live token); an
   emulator signed in as `benbillclash` (active grant → `42ml93AS…`) sends a
   `created`. You then see the banner on the real phone + `sent:1` in tail. The
   emulator is SENDER-only, so the "never an emulator" rule (about background
   delivery on real OEM devices) is not violated — the receiver is the real Redmi.
2. **Backgrounded / killed-app delivery on HyperOS is the higher-value solo step
   and the real open question.** Do NOT design the Autostart/battery primer yet —
   it must target the MEASURED failure mode, not a guessed one. Right order:
   send a push (via option 1's setup) → background, then separately swipe-kill,
   the real phone's app → observe whether/when the tray notification arrives.
   Design the primer FROM that result. Primer also brushes parked alarm-layer
   scope (boot-persistence) — confirm scope before building regardless.

## Design system — green/orange balanced palette, tokens, and UI-RULES.md (2026-07-24)

The app had no design system: one `ColorScheme.fromSeed(Colors.indigo)` line, no
dark theme, 12 hardcoded `Colors.*` sites, 6 ad-hoc font sizes, 10 off-grid
spacing values, and **two separate private `switch`es mapping the same domain
statuses to different colours** (`planner_activity_screen` vs `outcome_screen`).

**The doctrine: two colours of equal presence, divided duty.** Green (~157°,
sage) owns action and affirmation; orange (~24°, terracotta) owns attention and
pending state. Balanced presence falls out of the app itself — this app is about
the gap between proposed and resolved, so pending states are as common as
actions. Green is primary rather than orange because a saturated warm fill on
every button, FAB and nav selection is the loudest surface in the app and fights
the "calm, muted" target.

Consequences accepted:
- **Warning folds into orange.** Amber sat ~10° off our orange and read as a
  muddy near-miss. Warning is attention pitched up (rule + icon + weight).
- **Rejected and Skipped are neutral, never red.** A target rejecting or skipping
  is the consent model working, not a failure. Red is rationed to destructive
  actions and system errors, and never appears as a status badge.
- **Flat by default** — elevation 0 + a 1px `outlineVariant` border everywhere;
  shadows only on nav bar, dialogs and bottom sheets.

**Order that earned its keep: document → tokens → migrate ONE screen → verify on
device → only then enforce.** Migrating screen one surfaced three gaps before
they could propagate: the `labelSmall`/`bodySmall` boundary was ambiguous for
sentence-shaped metadata (resolved: prose wins, §3), italic had no token and 4
screens depended on it (resolved: quoted content uses `onSurfaceVariant` colour,
italic stays out of the scale), and showing both a status badge and an outcome
badge stated the same fact twice (resolved: the outcome badge replaces it).

**Two defects caught by measurement, not by eye:**
1. The planned *dimmed* neutral badge variant measured **4.43:1** in dark — under
   AA, passing in light. Dropped; all four neutral statuses now share one
   treatment and the label differentiates them.
2. A neutral badge bordered in `outlineVariant` measures **1.42:1** in dark — the
   badge's only structure, invisible. Neutral borders use `outline`.

**One defect caught only by rendering.** On the Redmi the Pending chip at
`#5A3520` read as a muted brown, just 1.49:1 off the card — the app's core
attention state, not pulling. Raised to `#9C531C` (2.8× luminance, chroma
0.64→0.82, 2.78:1 off the card), with `onAttentionContainer` brightened to
`#FBEDE2` because the old `#F3D3BC` drops to 4.05:1 on the lighter fill. Done
(8.16:1) stays the heaviest badge. Knock-on: `attention` on `attentionContainer`
fell to **2.69:1** in dark, below even the 3:1 non-text floor — so the warning
panel's left rule and icon use `onAttentionContainer`, not `attention`.

Pixel-sampling the rendered screenshots (rather than eyeballing) confirmed every
value matched spec exactly on the real panel.

**Enforcement:** `test/ui_rules_lint_test.dart` scans `lib/app.dart`,
`lib/features`, `lib/core/widgets` and `lib/dev` for raw `Colors.*`, `Color(0x`,
inline `fontSize`, literal spacing/radius/elevation, and emoji-as-status. An
analyzer lint would need the `custom_lint` dependency; a source-scanning test
needs none and runs under `flutter test`. Turned on only after screen one
validated the token scale — the enforcement gap was never wider than one screen.

Full spec: **UI-RULES.md**. Changing any token requires an entry here first.

## New role: `attentionContainerStrong` — the warning panel's fill (2026-07-24)

Rendering the warning panel at size (the harness's Panel tab) exposed an
asymmetry the badge-sized checks could not: the panel separates from its
background **3.13:1 in dark but only 1.19:1 in light**. In dark it reads as a
solid orange block; in light it is a soft tint where only the 3px rule works. A
warning is the single most important thing to notice on a screen, and light was
the weak mode.

**Why the shared token could not simply be raised.** Measuring the whole
container family against the card exposed the real cause:

| vs card | `primaryContainer` | `attentionContainer` | `errorContainer` |
|---|---|---|---|
| dark | 1.71 | **2.78** (1.63x pull over Approved) | 1.30 |
| light | 1.30 | **1.24** (0.95x — no pull at all) | 1.28 |

The 2026-07-24 Pending fix raised **dark only**. In light, Pending does not
out-pull Approved by any margin — the same defect, still live in the other mode.
Raising the shared `attentionContainer` to the 2.78 the panel needs would give
the light Pending badge a **2.14x** pull over Approved, harder than dark's 1.63x
— fixing the panel by over-loading the badge.

**Decision: the panel takes its own role, the badge tint is untouched.**

- `attentionContainerStrong` — light `#DD8643`, chosen to match dark's panel
  separation exactly (2.78:1 vs card, 2.66:1 vs scaffold). Same hue (26 degrees)
  and saturation (69%) as the tint it is pitched up from, so §2.4 still holds:
  warning is attention pitched up, not a third hue.
- In **dark it is `#9C531C`, identical to `attentionContainer`.** The two roles
  coincide there because dark already had the separation; only light diverges.
  A role that is the same value in one mode is not redundant — it is the seam
  where the two modes legitimately differ.
- `onAttentionContainer` (`#43220F` light / `#FBEDE2` dark) serves as the text,
  rule and icon colour on **both** fills: 5.13:1 on the strong light fill, 11.46
  on the light tint, 4.99 on dark. No new `on*` role is needed.

**Rejected: `#D9792F`**, which matches dark's 3.13:1 vs *scaffold* rather than
its 2.78:1 vs *card*. Its text pairing measures **4.56:1** — passing, but 0.06
off the floor. This project has already rejected 4.43 and 4.05; a value that
close to AA is not worth 0.35 of extra separation.

**Still open, deliberately not changed here:** light's Pending badge remains at
1.24:1, i.e. the dark Pending fix has never been applied to light. Correcting it
means raising `attentionContainer` (light) to about `#E6A574` — 2.10:1 vs card,
a 1.62x pull over Approved, matching dark's 1.63x almost exactly. That is a
badge change, not a panel change, and it is the user's call.

## Colour presence: structure vs state, and the filled-vs-line firewall (2026-07-25)

After using the built app, the verdict was that it reads "green-and-white in
light, green-and-black in dark" — orange barely present, green not present
enough either.

**The cause was a missing category, not weak values.** Colour only ever entered
the system as *state*. Every persistent surface was neutral by construction:
`appBarTheme` used `onSurface` on the scaffold colour, `listTileTheme.iconColor`
was `onSurfaceVariant`, dividers and card edges were `outlineVariant`. So on a
screen with nothing pending, orange was not quiet — it was **absent**, and green
was down to a single button. Raising saturation would have made the state
colours louder without putting colour anywhere new.

**The frame: three categories, with a firewall between two of them.**

| Category | What it is | Rule |
|---|---|---|
| **State** | Pending, Approved, Done, warning | **filled shapes only** — pills and panels |
| **Structure** | app bar, section rules, list icons, empty states | **line work and text only** — never a fill |
| **Temperature** | the neutral ramp's own hue cast | not an element at all |

**The firewall — filled = state, line/text = structure — is what protects the
doctrine.** "An orange *filled pill or panel* means something is waiting on you"
stays learnable and true, because structural orange never appears as a fill. It
is a falsifiable rule, and `ui_rules_lint_test.dart` now enforces it: the
`attention*` roles may not be used as a `BoxDecoration`/`Container` colour
outside `status_style.dart` and `warning_panel.dart`.

**What shipped (Tiers 1–3):**

1. **Temperature (decorative, zero semantic cost).** The neutral ramps carry a
   terracotta cast in both modes. This is the honest always-on orange: nothing
   *becomes* orange, so nothing can be misread as state. Dark was pushed
   deliberately hard — ~2.4x the warm chroma of the old ramp (bg `#16171A` ->
   `#1F1916`) — after a subtler first pass rendered as barely distinguishable.
2. **Green into structure.** App bar title and icons -> `primary` (the biggest
   single win; it is on every screen). List-tile icons -> `primary`. Section
   headers gain a 28x3 rule. Empty-state icon -> `primary`.
3. **Orange, strictly semantic.** Light `attentionContainer` `#F7E3D4` ->
   `#E6A574`, closing the fix that had been open since the dark Pending fix
   (1.24 -> 2.05 vs card). The Pending/Approved pull is now **1.62x in both
   modes** — previously 1.63x dark and 0.95x light. Section rules go orange only
   for genuinely attention-bearing sections. The nav bar carries a pending count
   badge.

**Accepted limitation, stated plainly:** this does not put orange on every
screen and nothing honest can. Orange means attention, so always-on orange is
decorative by definition and spends the trust that makes the badge readable. A
form screen with no pending state still shows orange only in temperature and in
a warning panel. That was reviewed against mocks and accepted.

**Held, not rejected: option O3** — a 2px always-on orange rule under the app
bar. It is the one change that genuinely costs doctrine (§2.1 would need a
clause giving orange a non-semantic chrome role). Deferred until the shipped
Tiers 1–3 have been lived with on-device. The mock is kept for comparison.

**§6.5 was amended rather than allowed to veto this.** It previously mandated
`onSurfaceVariant` for the empty-state icon. That rule existed to keep `outline`
out of a text-adjacent role, and `primary` does not reintroduce that problem
(6.50 light / 8.92 dark on the scaffold, against a 3:1 non-text floor).

**The error state is NOT green.** Implementing this exposed that `AsyncView`'s
only icon lived in the *error/timeout* widget, while the genuine empty state was
bare centred text with no icon at all — §6.5 was never actually implemented for
the empty case. Green means action and affirmation; a failure is neither. So the
empty state gained the §6.5 recipe with a `primary` icon, and the error/timeout
icon stays `onSurfaceVariant`.

Full values and the re-measured contrast table: **UI-RULES.md** §2.2, §2.7, §7.

## Icon system — one vocabulary, two rules, and a shipped notification defect (2026-07-25)

Icons were the last uncodified visual axis. Colour got `status_style.dart`, type
got the `TextTheme`, spacing got `Space` — icons had nothing, so 47 `Icons.*`
literals sat at call sites across 17 files with no rule about which glyph meant
what. This is the same drift the type scale was fixed for (18 on two screens, 17
on a third, for one element), caught earlier because the palette work made the
pattern recognisable.

### What the audit found — the reason this is a system, not a catalogue

**One glyph doing several jobs** (the damaging direction):
- **`Icons.check` had three jobs** — the Approved badge, the Done badge, and "this
  row is selected" in the schedule builder (twice). Affirmation and selection are
  not the same thing, and a user who learns the check as "agreed" is then shown it
  as "highlighted."
- **`Icons.inbox_outlined` had three jobs** — `AsyncView`'s default empty icon,
  the pending-approvals empty state, and the app-bar **action** that navigates to
  the approvals queue. The same glyph meant "there is nothing here" and "go to
  your queue" — opposite messages.
- **`Icons.login` had two jobs** — sign in, and join a group.

**Several glyphs for one concept:** three clock/calendar glyphs (`schedule`,
`access_time`, `event`) with no rule about which belongs where. Worse,
`Icons.schedule` and `Icons.access_time` are the *same drawing* in Material, so
the Pending badge and the time picker were already rendering an identical glyph
under two different names.

**Fill weight silently encoding a third meaning.** The nav bar uses
outlined-unselected / filled-selected correctly. But `groups_screen.dart` used
filled `Icons.group` in a list tile where nav uses `group_outlined` for the same
concept; and the schedule builder used `person_outline` for "Myself" versus
`person` for other targets — **fill weight encoding self-vs-other**, a convention
that exists nowhere else in the app and that no user could decode.

**A name that contradicts §2.4.** `warning_panel.dart` used
`Icons.warning_amber_rounded` while UI-RULES §2.4 states "Amber is banned." The
rendered colour was always correct (`onAttentionContainer`); the collision is in
the *name*, which is a Material naming artifact, not our hue. Resolved by naming
the concept `AppIcons.warning` so no call site ever types "amber" again.

### Decided — `lib/core/theme/app_icons.dart`, the one vocabulary

Same shape as `status_style.dart`: one file, and no call site names a glyph.
Names are **semantic, never glyph-named** — `AppIcons.pending`, not
`AppIcons.schedule`. Same reasoning as `attention` versus `tertiary`: the call
site reads the meaning, and the glyph can be re-picked without touching a screen.
`status_style.dart` now pulls its icons from `AppIcons` too, so there is genuinely
one source rather than two files that happen to agree.

**Rule 1 — one concept, one glyph.** Resolutions taken:
- `approved` = `check` (they agreed) · `done` = `task_alt` (they did it) ·
  `selected` = `check_circle` (filled — see rule 2). Three concepts, three glyphs.
- `pending` = `pending_outlined`, NOT `schedule`. This also breaks the accidental
  tie with `time` = `access_time`, which was the same drawing.
- `approvals` (the queue destination) = `assignment_turned_in_outlined`, distinct
  from `emptyGeneric` = `inbox_outlined`. An empty inbox and a queue you are being
  sent to are different messages and no longer share a glyph.
- `joinGroup` = `group_add_outlined`, distinct from `signIn` = `login`.

**Rule 2 — filled = selected or active; outlined = available or at rest.** Only
the nav bar has a selected state today, so in practice nav destinations carry both
variants and everything else is outlined. This is the same instinct as the §2.7
firewall — a visual weight is allowed to carry exactly one meaning — applied to
the fill axis of a glyph instead of the fill of a shape.

Consequence, accepted deliberately: **"Myself" and other targets in the schedule
builder now render the same person glyph.** The distinction is carried by the
label ("Myself" versus the person's name) and the subtitle, both of which are
legible. Fill weight was not — it was a private convention. This is the icon-axis
version of §2.6(3), "never encode state in colour alone."

**Colour of icons — no new rules, just §2.7 restated in icon terms.** Structural
icons are `primary` (already delivered by `listTileTheme.iconColor` and
`appBarTheme`); status icons take their colour from `statusStyle`; `AsyncView`'s
error and timeout icons stay `onSurfaceVariant` (§6.5's deliberate carve-out —
green means affirmation and a failure is neither); the warning panel's icon stays
`onAttentionContainer` (§6.3). **No icon is given an inline colour at a call
site.** This feature cannot touch the palette and does not.

**Tokens.** `Sizes.listIcon` and `Sizes.appBarIcon` (both 24) added, so the two
most common icon sizes in the app are stated rather than inherited implicitly from
Material.

**Enforced.** `ui_rules_lint_test.dart` gains a rule banning bare `Icons.` in every
governed file. Deliberately strict: "it's a one-off" is exactly how the type-scale
drift started. The escape hatch is adding a name to `app_icons.dart`, which costs
one line and forces the concept question — which is the point. `lib/dev/` is
inside the governed set, on the same reasoning as the colour firewall: the preview
harness demonstrates the system rather than sitting outside it, and a rule with a
door in it is not a rule.

### Notification icon — a real defect in already-shipped push

Found while scoping the launcher work, and worth separating from the design system
because it affects users of a feature that is already deployed and verified:

`AndroidManifest.xml` declared `default_notification_channel_id` but **no
`com.google.firebase.messaging.default_notification_icon`**. FCM therefore fell
back to `@mipmap/ic_launcher`, and since Android 5.0 the notification small icon
is rendered as an **alpha-channel silhouette** — a full-colour launcher PNG
becomes a white blob. Every tray notification the shipped Worker has ever
triggered would have rendered that way. The foreground verification on 2026-07-24
did not catch it because a foreground message is drawn by our own in-app banner
and never touches the system small-icon path at all.

Fixed with a **vector** `res/drawable/ic_notification.xml` (white on transparent,
a simple clock ring plus hands — simple enough to survive silhouetting at 24dp),
one file instead of five PNG densities, plus
`default_notification_color` → `@color/notification_accent` so the silhouette
tints our green instead of system grey.

**Tint value = the LIGHT `primary`, `#356150`, as a single fixed value.** The tray
sits on the *system's* surface, not ours, so our light/dark pair does not map onto
it — there is no "dark mode" for us to answer there, only the OS's. Held to the
same standard as everything else: **verify on the Redmi in both system themes
before calling it done** (§8), by the same framebuffer sampling that caught the
Pending chip reading brown.

### Deliberately NOT done in this pass — logged so they are not lost
- **Launcher artwork (adaptive icon + `<monochrome>` themed-icon layer).** The app
  still ships the stock Flutter demo icon: five `mipmap-*/ic_launcher.png`, no
  `mipmap-anydpi-v26/ic_launcher.xml`, so no adaptive icon and no themed-icon
  support on Android 13+. Deferred as its own piece: designing a brand mark must
  not gate the blob fix.
- **`android:label` is still `time_app`** — the raw project name, underscore and
  all, is what shows under the launcher icon. **Blocked on the product name**,
  which the user has explicitly not settled and is not rushing to unblock a build
  step. Left untouched on purpose.
- **Per-item category icons (icon-system reading (i))** — deferred and co-designed
  with goal tracking so `ScheduleItem` migrates once. When built, the stored value
  must be a **stable string key**, never a raw codepoint: codepoints are not stable
  across Flutter versions and defeat icon tree-shaking.

### Enforcement gap found while writing the lint (not fixed here)
`_governedFiles()` scans `lib/app.dart`, `lib/features`, `lib/core/widgets` and
`lib/dev` — it does **not** scan `lib/core/theme`. So the §2.7 firewall test's
owners set listing `lib/core/theme/status_style.dart` is dead code: that file was
never scanned to begin with, and its doc comment claiming "a new file added to that
directory is still governed by the firewall" is false. Harmless today (the theme
directory is where the roles are legitimately defined, which is why it is exempt
from §1), but the comment overstates the guarantee. Left as-is rather than widened
silently — changing what the firewall covers is a doctrine change, not a cleanup.

# Archive — Group D shipped (2026-07-26)

The per-user, UI-only soft-archive of settled items, built exactly to the shape
chosen 2026-07-23 ("Group D — CHOSEN"). Nothing in that design was reopened. What
follows is what the implementation added on top of it.

## Deploy order held
Rules first, verified before the client that writes archives existed on any
device. Ruleset **`d4b82acc-d9d0-4dd8-8845-fe2b5528382b`**, released
**2026-07-26T01:17:42Z**, replacing `1ced7bb3-…`. The *deployed source* was
fetched back from the Rules API and diffed against `firestore.rules`: identical,
`match /state/{doc}` present, and the `fcmTokens` block, the item-create `status`
constraint and the planner-withdraw branch all confirmed unregressed. This is the
third consecutive deploy verified by reading back the live ruleset rather than
trusting the CLI's success line — the 2026-07-18 incident's standing lesson.

## The archive read is ISOLATED from the schedule — the one thing designed beyond spec
Archive is a **join** onto My Schedule and Activity, which makes it a new way for
those screens to fail. If an archive read error propagated, `AsyncView` would drop
into its error state and a *view convenience* would take down the product — on
every offline cold start, and on any device running before this ruleset went live.

**Archive can hide rows. It must never be able to hide the schedule.** Two layers,
because one is a single edit away from being removed by someone who doesn't know
why it's there:

1. `archivedIdsStreamProvider` transforms an error event into an empty-set **data**
   event, so the provider cannot hold an error at all.
2. `archivedIdsProvider` exposes a plain `Set<String>`, reading `.value ?? {}` —
   so loading *and* error both mean "nothing is archived".

The filtered views use `.whenData`, which keeps the **items** stream's own loading
and error states intact. A genuine schedule failure still reaches `AsyncView`, as
it must; an archive failure structurally cannot.

**Verified, not asserted.** `test/archive_isolation_test.dart` covers the errored
read, the never-emitting read, both hide routes, and the record-layer constraint.
**Every rule is mutation-checked** — asserted by making the test go red, not by
claiming it: removing isolation layer 1 turns one test red; removing both turns
four red, including "My Schedule still shows every item"; removing the auto-hide
rule turns two red. The tests are pure Dart, which is why
`currentUidProvider` now exists (a `String?` projection of `authStateProvider`, so
the join is exercisable with no Firebase in the test).

**The cost, named:** during the first frames of a cold start the archive hasn't
resolved, so archived rows are briefly visible before filtering out. That is the
correct direction to fail. Archive is decluttering; **app lock is the privacy
answer**. A flash of a settled item beats a schedule that won't load.

## Record layer vs view layer, made explicit in the code
`allItemsAsTarget/PlannerProvider` are the record; `myItemsAsTarget/PlannerProvider`
are the record minus this user's archive. The filter is applied **once**, at the
provider seam, so it covers every surface a settled item reaches (My Schedule, the
pending queue, Activity) — per-screen filtering would leak the first time a screen
was forgotten. The `whenData` derivation means the "my" providers are now plain
`Provider<AsyncValue<…>>`, not `StreamProvider`s, so **every `onRetry` was
repointed at the source stream**: invalidating a derived Provider recomputes a
filter without reconnecting the Firestore listener that actually failed. Three
screens plus the theme preview's override were updated for the type change.

### The records-vs-UI split, and who is bound by it
**Every summary, stats, streak, goal-progress or records-generation consumer MUST
read `allItemsAsTargetProvider` / `allItemsAsPlannerProvider` — never `myItemsAs*`
or `archivedItemsProvider`.**

A consumer that counted a filtered view would silently drop *every rejected item*
(auto-hidden the instant it is rejected) and every manually archived one, out of
that user's own numbers — with no error to trace, discoverable only by noticing the
totals look wrong. That is the lie-by-omission "delete for me" was rejected over,
reintroduced through the back door. Archived means **hidden from view, fully intact
in Firestore**; the record layer is where that promise is kept.

**Audited 2026-07-26: there is currently NO such consumer.** The only readers of
item data are the four screens and the pending-count badge, all of which correctly
want the filtered view. So this is written down as a **constraint for the
goals/effort-tracking phase**, which is where the first record-layer consumer will
be written. The constraint is stated in a comment at the top of the record-layer
providers, i.e. where it can be violated, and `archive_isolation_test.dart` asserts
that rejected and archived items are still present in the raw streams.

## The terminal-state split — RESOLVED (2026-07-26, supersedes both earlier readings)
The 2026-07-23 entry contradicted itself: the constraint block said archive is
offered "ONLY on `done`/`skipped`", while the same entry called it "terminal-only".
**Both are wrong.** Corrected by the user on 2026-07-26, and this is the rule:

**Terminal states split two ways.**

| | route | why |
|---|---|---|
| `rejected`, `withdrawn` | **AUTO**-hidden on entry, no tap | Rejecting *is* the clearing action. A rejected row must never sit in the Activity feed piling up. |
| `done`, `skipped` | **MANUAL**, via the card action | Not clutter the instant they happen. Hide them when you're ready. |

`pending` and `approved`-not-done are hideable by **neither** route — the
constraint that always mattered. In the model: `isAutoArchived`,
`isManuallyArchivable`, `isSettled`. (`cancelled` rides with the auto pair; no
code path sets it today.)

### AUTO-archive CANNOT be a write — this is structural, not a shortcut
The obvious implementation (write an archive entry when the reject lands) is
impossible, and the reason is worth keeping:

**The person who rejects is not the person whose feed is cluttered.** A rejected
item never appears in the *target's* own views at all — My Schedule filters
`approved`, the pending queue filters `pending`. The pile-up is entirely in the
**planner's** Activity feed. So for the target's reject to clear it, the target
would need write access to the planner's `users/{uid}/state` subtree — destroying
the single property that makes this whole shape safe: *nobody can affect anyone
else's data.*

So auto-archive is a **pure view rule** in the filtered providers: no write, no
stored flag, no rules change, applied identically for both parties. It also cannot
half-fail, and it survives a broken archive read — the rule reads a field already
in hand, so a rejected row cannot reappear just because the archive doc is
unreachable. The `users/{uid}/state/archived` set stays exclusively for manual
done/skipped archives.

### Reject-undo vs auto-archive — no collision, by construction
**There is no reject-undo today** and none was added here: `_reject` writes and
notifies, with no snackbar and no undo affordance. Un-rejecting is a
*decision-reversal* feature, not an archive feature, and is not in this pass.

The collision risk was creating the *wrong* undo — one that un-hides an item while
it stays rejected, putting the clutter straight back. It cannot arise: auto-archive
writes nothing, so there is no archive entry to undo, and the only undo that could
ever be built is un-rejecting. Concretely, **auto-hide fires silently** — the Undo
snackbar belongs to the manual route alone.

### Consequences that had to be handled
- **Auto-hidden items DO appear on the Archived screen, read-only** (no Unarchive).
  Listing them keeps their record reachable; offering Unarchive would restore
  exactly the clutter rejecting had cleared. Manual archives keep Unarchive.
- **The Archived screen is now the SYSTEM OF RECORD for rejection reasons.** Say
  this plainly so no future reader thinks the reason was lost: rejected rows no
  longer render in Activity, so `_reasonLine` on the Archived screen is **the only
  place in the app a rejection reason is readable.** This is the deliberate,
  accepted consequence of rejected rows leaving the feed — the reason is intact in
  Firestore and intact on screen, just in one place instead of two. Anything that
  changes what the Archived screen lists, or stops listing auto-hidden items there,
  **takes the reject reasons down with it.** The now-unreachable rejected arm of
  Activity's own `_reasonLine` was kept, not deleted: it is the correct rendering
  for the state if the auto rule is ever narrowed.

## Copy and icons
Never "delete", never a bin glyph — `AppIcons.archive` / `unarchive` are the
archive-box pair, and `emptyArchive` is a **third** glyph so "hide this" and "you
have hidden nothing" don't share one (the `inbox_outlined` mistake §6.6 names).
Archiving shows a snackbar reading "Archived — hidden from your views only." with
Undo; no confirmation dialog, because a dialog would frame as consequential
something that is one tap from reversed. The Archived screen's empty state states
the honesty guarantee outright rather than leaving the user to infer it.

**Manual Archive lives in a card overflow menu (`AppIcons.overflow`), not an
inline button.** Settled cards sit in scrollable lists, and an always-visible
control whose whole job is to make a row vanish is a mis-tap waiting to happen
mid-scroll. Archive is a *secondary* action on the card, so it goes behind the ⋮.

**Unarchive on the Archived screen stays inline, and the asymmetry is deliberate.**
There, putting a row back is the card's *primary* action — the reason you opened
the screen — and burying a screen's primary action behind an overflow is the
opposite trade. Same list shape, different role.

## Shape as built
- `users/{uid}/state/archived`, one `items` map of `itemId → archivedAt`.
- Keys are raw auto-ids, not `targetUid_itemId`. A planner's archive spans several
  targets' subcollections, so the key space is a union in principle — but two
  20-char auto-ids colliding is not a thing that happens, and a composite key
  would have to be threaded through every call site to buy nothing.
- One shared **Archived** screen from the account menu, both roles, deduped by id
  (a self-planned item is in both source streams).

# Security hardening DEPLOYED (2026-08-10) — recorded 2026-08-13

The §6/§6.1 rules + join-code work is **live**; only the record was missing.

- Ruleset `1cff4c97-3dbf-4e6b-abec-8d3d9a048a8e` — created 2026-08-10T18:40:30Z,
  released to `cloud.firestore` 18:40:31Z.
- Backfill ran first, per the deploy order: 4 `joinCodes` docs written
  18:38:32–36Z, one per group (4 groups, every one carrying a `joinCode`).
- Verified 2026-08-13 by fetching the **deployed** source via the Rules API and
  diffing against `firestore.rules`: byte-identical (md5 `9e72bc5f…`), that file
  committed and unmodified at HEAD. Never trust the local file — this project
  shipped a 6-day-stale ruleset once (2026-07-24).

# Device verification CLOSED (2026-08-14)

**All five on-device steps passed against the live rules.** This closes the loop
opened by the 2026-08-10 deploy: the hardening is not just released, it is
confirmed to work from the client, on real devices, under the ruleset actually in
force (`1cff4c97-3dbf-4e6b-abec-8d3d9a048a8e`).

This retires the concern in WORK_PLAN.md §0.3 — *"the app on the devices is either
running old client code (with three live security holes) or new client code that
is broken."* Neither is true any more: the current client and the current rules
are the pair that is deployed, and they were exercised together rather than
assumed compatible. `createGroup`'s `joinCodes/{CODE}` write — the specific thing
that would fail closed under the old rules — is among what passed.

ARCHITECTURE.md's "Nothing here is deployed" bullet is amended in place rather
than deleted, so the false claim stays visible next to its correction instead of
vanishing from the record.

# Worker service-account key VERIFIED, rotation complete (2026-08-14)

The rotated `FIREBASE_SERVICE_ACCOUNT` secret is **confirmed working in
production**, and the service account is now down to **one key** (the two older
admin keys deleted by the user on the strength of this run).

**The evidence** — a `created`-event push for a real planner→target pair returned:

```
{"sent":0,"cleaned":2,"recipientUid":"42ml93…","reason":"no-delivery"}
```

`sent:0` is a *recipient-device* result, not a credential result. Reaching that
line at all exercises the whole credential chain, and every link had to succeed
to produce it:

1. `getAccessToken()` minted an OAuth2 token — an RS256 sign with the private key
   plus a live token exchange. A bad key throws here → HTTP 500
   `send-failed / "OAuth token exchange failed"`. It didn't.
2. Firestore REST **read** the item doc, the grant doc, and listed `fcmTokens`
   (returned 2) — scope `datastore`, authenticated.
3. FCM v1 **accepted the caller** and rejected the two *tokens* specifically.
   An auth failure at FCM (401/403) maps to `OTHER` in `fcm-rest.js` and is
   never cleaned; `cleaned:2` means both responses were `UNREGISTERED` or
   `INVALID` — per-token verdicts FCM only issues *after* authenticating the
   sender. Scope `firebase.messaging` confirmed.
4. Firestore REST **wrote** — two `deleteDoc` calls succeeded. `deleteDoc` throws
   on any non-ok, non-404 status, which would have propagated to a 500. So the
   key is proven for datastore **writes**, not just reads.

Both scopes, both directions, one request. That is a stronger verification than a
successful `sent:1` would have been on its own, since `sent:1` proves only the
FCM leg.

**What `no-delivery` actually was:** stale tokens. Both were written 2026-07-24
and the recipient's app had been reinstalled repeatedly across the archive +
app-lock work in the three weeks since; a reinstall invalidates the FCM token
(`UNREGISTERED`). The Worker did the right thing — sent nothing, cleaned both,
and left `notifiedCreated` **unstamped** (`notify.js` stamps the dedup guard only
`if (sent > 0)`), so the same item stays deliverable on a genuine later attempt.

**Caveat recorded, not resolved:** `cleaned` collapses `UNREGISTERED` (stale) and
`INVALID`/`SENDER_ID_MISMATCH` (token belongs to a different Firebase sender)
into one counter, so the log line alone cannot distinguish "reinstall the app"
from "wrong `google-services.json`". Staleness is near-certain here given the
dates. If a freshly-registered token ever cleans again, that ambiguity is the
first thing to break — the two causes have completely different fixes.

# D1 — app lock VERIFIED ON DEVICE (2026-08-14, Redmi / HyperOS, Android 16)

The privacy claim the app had been making since the lock shipped is now **true and
observed**, not inferred. Run on the primary test device, against a real install.
Commits `bb52989` (FLAG_SECURE handler, subtitle, test deletion) and `50b2113`
(the FragmentActivity fix found *by* this run).

**FLAG_SECURE applies on EVERY launch — the thing the deleted test only pretended
to cover.** `setSecure(true) → FLAG_SECURE applied=true` observed across **three
separate process launches (PIDs 29212, 7734, 29556)**. `applied` is read back off
the window in `MainActivity.kt`, so this is the OS's answer, not an echo of the
request. Three distinct PIDs is the load-bearing evidence: the flag is per-window
and dies with the process, so one launch proves nothing about the next.
`setSecure(false) → applied=false` on toggle off.

- **Screenshot: blocked while ON, restored while OFF.** Both directions checked —
  a flag that never clears would be its own bug.
- **Recents thumbnail: blank** on the kill-and-reopen path.

**Known limit, recorded rather than buried.** With the lock ON, tapping the
recents *button* (not a full kill) shows app content for **~1 second** before it
blanks. This is OS-level and not a defect in this code: the system animates the
**live window surface** into the card, and FLAG_SECURE governs snapshot capture,
not a surface that is legitimately on screen. Once the live surface is swapped for
the stored snapshot, the flag takes effect — which is why the full-kill path is
blank from the first frame. **Deliberately not fixed.** A cover-on-`inactive`
widget would close it, but that is a different mechanism, not FLAG_SECURE, and the
threat model does not justify it: the flash is only visible to someone already
holding the phone with the app open in front of them, so it leaks nothing they
cannot already see.

## The lock-out bug this run found — and why nothing caught it earlier

**The app was permanently unopenable and no test, build or review had noticed.**
`MainActivity` extended `FlutterActivity`; `local_auth` returns
`ERROR_NOT_FRAGMENT_ACTIVITY` (`LocalAuthPlugin.java:124`) *before* constructing a
BiometricPrompt unless the host is an AndroidX `FragmentActivity`. The resulting
`PlatformException('no_fragment_activity')` was swallowed by the blanket
`on PlatformException → return false` in `device_auth.dart`, so tapping Unlock
produced a brief spinner and nothing else, forever.

**What hid it is worth keeping.** Enabling the lock kept working the whole time,
because `setEnabled` only calls `canAuthenticate()` — a capability query with no
FragmentActivity guard. `authenticate()` is reached from exactly one place,
`unlock()`, so the prompt was first *required* on the first relaunch. Every
cheaper check passed: the unit suite, `flutter analyze`, and a successful Kotlin
compile. **Only a real device on the real path could find it**, which is the same
lesson as the deleted fake-based test, arriving twice in one session.

**Fixed and verified:** `FlutterFragmentActivity` (`50b2113`). Unlock now raises
the biometric/PIN prompt on relaunch.

**Trade accepted, and CLOSED — not left open.** AndroidX `FragmentActivity`
reserves the upper 16 bits of `onActivityResult` request codes, which can break
plugins on the legacy activity-result path; Google Sign-In was the exposure, and
it is the only way into this app. **Verified by a real sign-out and sign-in on the
Redmi: no error, no regression.** The CredentialManager path in
`google_sign_in_android` 7.2.15 survives the superclass change. This item is
closed; do not re-open it as a risk.

**Lock coupling observed correct on-device.** With the lock ON, signing out
prompted for unlock first; with it OFF, it did not. The coupling asserted at
`app_lock_test.dart:214` — *"FLAG_SECURE rides the same switch, not a second
one"* — now has a real-device observation behind it, not only a fake.

**Native changes need a full uninstall.** `flutter install` / `flutter run` did
not replace `MainActivity`; only `adb uninstall` + `flutter run` did. `flutter run`
skips installation when the device sha1 stamp matches
(`android_device.dart:400`), and hot reload never replaces native code at all.
**Rule for any `.kt` / manifest / Gradle / plugin change: uninstall first.** Cost
each time: signed out, app-lock setting reset, and the FCM token invalidated.

# D2 + D11 — the tabs became a StatefulShellRoute (2026-08-14)

Three code commits plus a docs pass. All reasoning below is against
**go_router 17.3.0**, and parts of it are version-specific — re-check the cited
source if that constraint moves.

## The tabs are branches, and each tab owns its detail screens

**Decision: one registration per screen, and a screen's *location* names the tab
it belongs to.** `GroupsScreen`, `OutcomeScreen` and `PlannerActivityScreen` were
registered twice — as tabs inside `HomeShell` and as flat top-level routes — which
is what made a notification `go()` replace the whole stack with a bare, doorless
screen (D2). They are now the three branches of a
`StatefulShellRoute.indexedStack`.

**Then the second, less obvious half: the detail screens were *nested*, not
"pushed on top of the shell" as WORK_PLAN's Session 3 plan had it.** Sub-routes
resolve into their branch's own navigator, so the nav bar stays, Back returns to
the tab, and each branch keeps its own stack. go_router forbids a leading `/` on
a sub-route, so two locations changed:

| screen | before | after |
|---|---|---|
| Pending approvals | `/approvals` | `/outcome/approvals` |
| Schedule builder | `/schedule-builder` | `/activity/schedule-builder` |
| Group detail | `/groups/:groupId` | unchanged (already under `/groups`) |

Every call site goes through the `Routes` constants, so the constants absorbed
the change. The one hardcoded literal in the app — `groups_screen.dart`'s
`'/groups/${g.id}'` — still resolves because that path did not move. It was
grepped for explicitly, not assumed.

**`/profile`, `/archived` and `/dev` stay root-level.** They are opened from the
account menu, which every tab shows, so they belong to no branch and should cover
the bar rather than live under one tab.

**`_handleTap` needed no code change.** Once both destinations are branch
locations, a plain `go()` *is* the shell-aware navigation: `go(Routes.approvals)`
selects the My Schedule branch and stacks the queue on it, and
`go(Routes.plannerActivity)` is a tab switch. Session 3's decision 1 — target-
facing events push over My Schedule, planner-facing events switch to Activity —
holds as written.

## The dev menu had to use `go`, and that cost something

**Pushing an in-shell location from `/dev` does not reuse the shell — it clones
it.** `RouteMatchList._createNewMatchUntilIncompatible` (`match.dart:634`) reuses
the existing shell only when the top of the current stack *is* that shell route.
Standing on the dev menu the top is `/dev`, so the routes are unequal and control
falls to `_cloneBranchAndInsertImperativeMatch` (`:663`), which copies the shell
branch and appends it. Two `ShellRouteMatch`es for one `StatefulShellRoute`, and
since `_buildPageForShellRoute` (`builder.dart:280`) uses `match.navigatorKey`,
that is the same branch-navigator `GlobalKey` live in two subtrees — a duplicate-
GlobalKey crash, not a cosmetic second nav bar.

So each dev-menu entry carries an `inShell` flag: **five destinations use `go`,
and only root-level `/profile` is pushed.** Note this hazard arrived with the
shell conversion itself, not with the nesting; nesting only raised the count from
three to five.

**Rejected: registering those screens again as dev-only root-level aliases** so
`push` would work. That is exactly the duplicate registration D2 removed. Being
debug-only does not make it not a second registration.

**Trade accepted:** `go` drops the dev menu from the stack, so Back from those
five returns to the tab, not to the menu. A launcher that teleports you into a
tab cannot also be a modal you come back to. WORK_PLAN's device checklist section
D was rewritten to expect two different behaviours rather than one.

## D11 — `ref.onDispose`, and why it is defensive

`routerProvider` now holds the refresh stream in a local and registers
`ref.onDispose(refresh.dispose)`, which cancels the `authStateChanges()`
subscription. **go_router never disposes a `refreshListenable`** — the provider
only calls `removeListener` on it (`information_provider.dart:318`) — so the
subscription was always the caller's to cancel, and there is no double-dispose
risk in adding this.

**Recorded honestly: this is defensive, not a live leak.** `routerProvider` is
never invalidated, `authRepositoryProvider` never rebuilds, and no test reads the
router, so today the only dispose is app teardown. It becomes real the moment a
scoped container or a widget test overrides either provider — the pattern
`currentUidProvider`'s own doc comment recommends — and the failure has no
symptom to catch it by later.

## What is NOT verified

**Routing has zero automated coverage.** Nothing in the suite builds the router;
`flutter analyze` clean and 65/65 passing say nothing about any of the above. The
verification is the manual device matrix in WORK_PLAN.md, sections A–E.
**RESOLVED — run 2026-08-15, see the next entry.** Sections A, B and D pass; C and
E3–E5 remain unrun. Automated coverage is still zero and that has not changed.

# Session 3 device pass (2026-08-15) — D2 verified, five defects found

Redmi / HyperOS, Android 16, debug build. Device restored to its prior build and
theme afterwards.

## The verdict on D2

**The routing work is correct.** Tabs, tab-state persistence, pushed detail
screens over the nav bar with working back arrows, nested routes, and all six dev
menu destinations — every one behaved as designed (A1–A3, A5, A6, B1–B9, D1–D8).
The notification dead end that D2 was about is closed *as far as navigation goes*;
the notification events themselves (C) are still unrun.

**A4 is recorded as "behaves as written, spec superseded" — not as a failure.**
The checklist itself asked that Back at a tab root exit the app. It does. The
expectation was wrong, and reversing it is a product decision taken today, not a
defect found against the design. Keeping this distinction matters: if A4 were
filed as a failure, the shell conversion would carry blame for behaviour it never
touched.

**Not run, and not to be treated as passing:** C1–C8 (needs a second device with a
live FCM token) and E3–E5. The `wrangler tail` showing no delivery is the expected
no-tokens progression following the stale-token cleanup — the Worker and the admin
service-account key are fine (verified 2026-07-24, unchanged). The notification
retest must re-register a device token before section C means anything.

## The five defects — every one pre-existing

Stated up front because it decides how each is filed: **none of these is a Session
3 regression.** The pass found them because it was the first end-to-end drive of
the app in one sitting, not because the refactor caused them. All five are fixed
in the commits following this entry, one per commit.

### 1. Back exits the app from a tab root, with no confirmation

`GoRouterDelegate.popRoute()` (`go_router-17.3.0/lib/src/delegate.dart:57-79`)
walks the current navigators calling `maybePop()`. At a tab root the branch
navigator has a single route and declines; the root navigator holds only the shell
route and declines; no `onExit` is defined; it returns `false`, and the engine
finishes the activity. Silent exit.

**Pre-existing.** `grep -rn "PopScope\|WillPopScope\|onPopInvoked\|SystemNavigator"
lib/` is empty — the app has never had back handling. Before the refactor
(`git show 6c31364^:lib/features/home/presentation/home_shell.dart`) the tabs were
a local `int _index` over an `IndexedStack`; switching tabs pushed no route, so
Back at any tab exited identically. The refactor changed the mechanism, not the
outcome — and it is what makes the fix clean, since `goBranch(0)` now exists.

**Decision: Back returns to the Groups tab from any other tab; Groups itself takes
a "press again to exit" confirmation (~2s window).** Implemented as a `PopScope` in
`HomeShell`. Placement is load-bearing: the shell route is built on the **root**
navigator, so the `PopScope` registers there and is consulted only after the
branch navigator has declined — which is the order that makes "Back inside a tab's
own stack still pops that stack" keep working.

### 2. The Archived–Undo snackbar outlives sign-out — two independent causes

**(a) It never auto-dismisses, and adding a `duration` would not help.**
Flutter 3.44.6 (`snack_bar.dart:303`):

```dart
persist = persist ?? action != null;
```

**Any `SnackBar` carrying a `SnackBarAction` defaults to `persist: true`**, and the
dismiss timer then fires into a no-op (`scaffold.dart:619-626`):

```dart
_snackBarTimer = Timer(snackBar.duration, () {
  if (snackBar.persist) { return; }   // never dismisses
  hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
});
```

Blast radius is exactly the two actioned snackbars in the app:
`archive_menu_button.dart:65-73` (Undo), and the FCM foreground banner
`app.dart:134-152` (View) — **whose explicit `duration: 6s` at `app.dart:135` has
been dead code the whole time.** The three action-less snackbars
(`groups_screen.dart:127`, `schedule_builder_screen.dart:106,123`) dismiss
normally, which is why this was never noticed.

**(b) It survives an auth change, because it lives outside the navigation tree.**
`MaterialApp` builds the `ScaffoldMessenger` **above** the Router:
`flutter/packages/flutter/lib/src/material/app.dart:1047` wraps a `childWidget`
that already contains our `builder` (`AppLockGate`) and the `Router`. So no route
change, branch switch, or sign-out can reach the snackbar queue. Worse,
`scaffold.dart:211-222` `_register()` hands the live snackbar to any **newly
mounted** root `Scaffold` — so `AuthScreen`'s fresh Scaffold re-renders it on
sign-out, and the next account's shell does it again. Combined with (a), only the
process ends it. Nothing in `signOutWithTokenCleanup`
(`messaging_service.dart:182-188`) tears down UI.

**The sharp edge is not cosmetic.** The `Undo` closure
(`archive_menu_button.dart:70`) captures `uid` at show time, so a stale snackbar
tapped after switching accounts writes to the **previous** account's archive doc.
A UI element crossing an account boundary is a state-scoping leak, and this one has
a write on the end of it.

**Pre-existing** — `archive_menu_button.dart` last changed in `ec25862`
(2026-07-25), three weeks before the refactor.

### 3. Edit Profile discards silently on Back; empty name is a reachable state

Draft state is local (`profile_edit_screen.dart:23-33`); Back is a plain
`Navigator.pop` with no `PopScope`, no dirty check, no confirmation; reopening
re-prefills from `profileProvider` behind the `_initialised` latch (`:94-111`).
**No decision was ever recorded for this** — `grep -rn "unsaved\|discard"` over
DECISIONS.md and UI-RULES.md finds nothing on topic. It was default behaviour, not
a choice.

Clearing the name greys out **Save changes** (`:62-65`, `:171`) with no `errorText`
on the field (`:123-128`) — a dead button and no stated reason.

**Can an empty name be saved?** Not through today's client: both writers gate on
the same non-empty check (`profile_edit_screen.dart:62-65`,
`complete_profile_screen.dart:62-64`). But `ProfileRepository` only calls
`name.trim()` (`profile_repository.dart:30,54`), and **`firestore.rules:90` is
ownership-only with zero field validation.** So the invariant lives entirely in two
widget getters. If it were ever bypassed, `Text(m.name)` in the roster
(`group_detail_screen.dart:94`) renders blank, and the join path denormalizes the
empty string into the member doc via `profile?.name ?? user.displayName ?? 'Me'`
(`groups_screen.dart:124`), where `''` is non-null and beats both fallbacks. The
`?? 'someone'` fallbacks elsewhere are null-guards; an empty string sails through
all of them. `_initial()` (`group_detail_screen.dart:124-125`) is the one place
that handles it.

**Decisions: (i) confirm-on-back — a "Discard changes?" dialog when the draft is
dirty**, not silent discard and not a hard block on Back; **(ii) the server
enforces a non-empty name.** A required field the server does not enforce is a real
gap, so the rules change ships — but as its **own commit**, because it is a
coordinated deploy (rules first, verify the *deployed source*, then install).

### 4 / 5. Archive copy is too long

`archived_screen.dart:44-46` (three lines) and `archive_menu_button.dart:67`.
Rewritten to keep the one honest point — hidden from you, unchanged for everyone
else — and **within UI-RULES.md**: neither string uses the word "delete" or a bin
glyph, per the standing rule at `archive_menu_button.dart:18-21`. "Everyone else
still sees it" carries the honesty as a positive statement rather than by negating
"deleted", which is why it was preferred over "not deleted".

### 6. A cancelled sign-in shows a red error with a raw exception

`auth_screen.dart:30-32` catches every throw into `_error = 'Sign-in failed: $e'`,
rendered in `context.colors.error` at `:62-72`.
`GoogleSignIn.instance.authenticate()` (`auth_repository.dart:33`) throws
`GoogleSignInException(code: canceled)` when the user backs out — and
`auth_repository.dart:27-28` already documents that it "throws on failure (e.g.
user cancels)". The caller just never discriminated.

**This is not debug-only.** It is our own widget; there is no `kDebugMode` guard
anywhere near it (`main.dart` holds only the Crashlytics wiring at `:28`). A
release build shows the same red text with the same raw SDK `toString()`. The
initial assumption that debug was hiding it in release was wrong, and the fix is
therefore a release-affecting fix, not a debug nicety.

**Decision: a cancel is a user decision, not a failure** — catch the `canceled`
code and return silently to the sign-in screen. Red stays rationed for genuine
failures (UI-RULES.md §2.5) and gets a human message instead of a `toString()`.

## Chatbot entry point = the account menu (2026-08-18)

The language-practice chatbot was reachable only from the dev menu, which is
debug-only scaffolding stripped from release builds: the feature existed in
release and had no door. It needed a permanent entry point in normal navigation.

**Chosen: an item in the account menu (`AccountButton`), above a divider that
separates it from the account block.**

The account menu is already the documented home for exactly this shape of route.
`app_router.dart` groups `/profile`, `/archived` and `/dev` as "account-level
routes … reached from the account menu on any tab and belong to no tab", and
`/chatbot` was declared in the same words for the same reason. `AccountButton`
renders in all three tab AppBars, so one menu item makes the feature reachable
from everywhere in the app, in release, with a working back arrow.

**`/chatbot` stays top-level and pushed.** Nothing about the shell moves, so
`/chatbot/settings` keeps nesting under it, Back from settings still returns to
the chat, and the dev-menu entry keeps working unchanged as a pushed root-level
destination (Back returns to the dev menu).

### The fourth-tab alternative, and why it was rejected

A fourth `StatefulShellRoute` branch labelled *Practice* was considered first and
briefly chosen, then reversed. It buys discoverability — the account menu is
where you go rarely and deliberately, which is written into the Archived
rationale, while language practice is a place you visit. Three costs sank it:

1. **It dilutes the "three role-agnostic tabs" doctrine.** The nav bar says
   something precise today: each tab is one stance in the delegation loop, and
   the same person occupies all of them. A fourth tab that is not part of that
   loop turns the bar into "the app's top-level places" and spends a meaning
   that is hard to get back.
2. **The dev-menu link would have to change from `push` to `go`.** In-shell
   destinations must use `go`; pushing a shell location from `/dev` makes
   go_router clone the shell and crash on a duplicate `GlobalKey` (the long
   comment in `dev_menu_screen.dart`). Back would stop returning to the dev menu.
3. **It silently breaks the chat's session boundary.** `ChatScreen` holds its
   transcript in `State` and its `session_id` in a `late final`, deliberately: a
   practice session is one sitting, so leaving the screen ends it, matching the
   boundary `session_id` draws on the service. `StatefulShellRoute.indexedStack`
   keeps every branch mounted — that is the point of it — so as a tab the
   transcript and session id would live for the whole process lifetime under a
   session the backend may long since have forgotten. Fixing that needs a
   *New conversation* action and a mutable session id; none of that is needed
   while the screen is pushed and disposed on leave.

If discoverability turns out to be the real problem in use, the fourth tab is
the upgrade path — but it is a product decision with the three costs above
attached, not a wiring change.

**The seam is untouched either way.** `lib/features/chatbot/` still shares only
the theme, the icon vocabulary and the router: no group, no schedule item, no
approval, no outcome, no Firestore document, no FCM, no Worker. This decision
adds one menu item that pushes a route.

## On-device chatbot model — download + storage (2026-08-19)

Part 1 of moving the language-practice bot off the laptop and onto the phone.
This session builds **only** the acquisition layer: fetch the model files, store
them, prove they are intact. No inference, no engine, no change to which
implementation the seam returns.

### The files are downloaded, never bundled

~143MB of ONNX weights, a tokenizer, an embeddings index and its metadata. In the
APK they would roughly quadruple the download for every user of the *delegation*
app, who is the actual user and does not want a German practice bot. They are
hosted on a **GitHub Release** and fetched on first use into app-private storage.

`kModelReleaseBaseUrl` in `features/chatbot/data/model_manifest.dart` is the one
line that moves when the release moves — the same shape as `kNotifyEndpoint`, and
for the same reason: an address that will change should be a named constant, not
a string spread across a data layer.

### It does not gate the chat

The setup screen is a **destination** (`/chatbot/model`), not a wall in front of
`/chatbot`. The HTTP implementation still answers every message exactly as it did
yesterday. Gating now would put a 130MB download in front of a feature that
currently works, and — while the manifest still holds placeholder URLs — would
make the chat unreachable entirely.

Part 2 is what flips `chatbotServiceProvider`; the gate belongs in the same
change as the thing it gates.

**The door is the chat's AppBar overflow, not the settings screen.**
`chatbot_settings_screen.dart` is documented as dying with the HTTP
implementation, so hanging the on-device entry point off it would mean deleting
HTTP also deletes the only way to reach the on-device model. The AppBar menu
outlives both: today it holds *Service address* (HTTP-scoped) and *Offline
model*; when HTTP goes, the first item goes with it and the second stays.

### Verification is fail-closed, and degrades honestly

Every file lands as `<name>.part` and is renamed to `<name>` **only after it
verifies**. A rename within one directory is atomic, so a file with the real name
is by construction a file that passed — an interrupted download cannot present as
a finished one, and `isReady()` needs no separate bookkeeping to trust.

`ModelFile.sha256` and `.sizeBytes` are **nullable**, because the real values do
not exist until the files are uploaded. Null means "verify what is knowable":
bytes received must equal the `Content-Length` the server declared. Filling the
real digests into the manifest turns strict checking on with **no code change** —
`verify()` already reads them. This is a deliberate weak state with an expiry, so
`isPlaceholder` names it and the setup screen says so on screen rather than
implying a guarantee it cannot make.

### Resume, with a restart fallback

A 130MB download over a phone connection will be interrupted. The `.part` file is
kept and a retry sends `Range: bytes=<already-have>-`.

The fallback matters more than the happy path: a server that ignores `Range`
answers **200 with the whole body**, not 206. Appending that to a partial file
produces a corrupt file of plausible size — which is exactly the failure a
checksum is for, but it is better not to create it. So the response code decides:
`206` appends, `200` truncates and restarts, `416` means the part is already at
or past the full length and is discarded. Nothing infers resumption from the
request it sent.

A **per-chunk** idle timeout, not a whole-download timeout: a large file has no
sane total budget, but 30 seconds with no bytes arriving is a dead connection on
any budget.

### `Sizes.progressBar = 8` — new token (UI-RULES.md §9)

A determinate progress bar is the first the app has had; `app_theme.dart` themes
no progress indicator and UI-RULES.md had no recipe. Value and reasoning are in
the new **§6.7**, added before the screen was written.

**Green, not orange.** A download in flight is *action in progress*, which is
what `primary` means. Orange is reserved for "waiting on you" (§2.7) and a
progress bar is a filled shape — the one thing the firewall says must not borrow
that colour. The failure state uses `WarningPanel`, which is where orange
legitimately lives.

### What is not built

No inference, no ONNX runtime, no second `ChatbotService`. Nothing in
`chatbot_service.dart`, `http_chatbot_service.dart`, `chatbot_endpoint_store.dart`
or `chat_screen.dart`'s transcript changed — the seam is untouched, which is the
whole point of having had it before this work started.

---

## On-device chatbot engine — Part 2 (2026-08-19)

Part 1 put the files on the phone. This makes them answer. `chatbotServiceProvider`
now returns `OnDeviceChatbotService`, and the chat is gated on the model being
present. **A reply now requires no laptop, no Tailscale and no internet.**

The chat screen did not change to make this happen — one provider line did. That
was the whole promise of keeping `ChatbotService` to a single method with no
transport in its signature (2026-08-18), and it held.

### The pipeline is a port, not a reimplementation

`backend/search.py` and `backend/app.py`, step for step:

```
Precompiled charsmap -> WhitespaceSplit + Metaspace -> Unigram Viterbi (128 incl. specials)
  -> ONNX MiniLM int8 (mean pooling INSIDE the graph) -> L2 normalise
  -> cosine vs the 5,275-row index -> top 10
  -> best < 0.55 ? decline : serve, skipping a repeat of the session's last line
```

This is deliberately not "close enough". Query and index vectors are only
comparable if both sides tokenize and pool identically, and a tokenizer that is
*nearly* right raises no error — it just lands somewhere else in the embedding
space and retrieves a worse line. So every stage is a port of the reference, and
correctness is measured against the reference rather than against anyone's idea
of what XLM-R ought to do.

**The normalizer had to be ported whole.** Dart has no Unicode normalization, and
NFKC would not have been enough anyway: SentencePiece's charsmap also folds tabs,
newlines, zero-width spaces and the BOM to a plain space, which NFKC leaves alone.
289 of the 5,275 corpus lines are changed by it. `precompiled_normalizer.dart` is
a port of HuggingFace's `spm_precompiled`, darts-clone double-array and all,
including the grapheme-then-character fallback that looks wrong and is what the
reference does.

**Verified, not assumed:** the Dart tokenizer reproduces the real 250,002-piece
HuggingFace tokenizer on **5,302/5,302 texts** — the entire corpus plus adversarial
Unicode (BOM, tab, zero-width, full-width, ligatures, Roman numerals, emoji,
Cyrillic, CJK, Hebrew, a 300-word truncation case). Not one id differs.

### The threshold is 0.55, matching the server

`MATCH_THRESHOLD` in `app.py`. The 0.545 named in the session prompt appears
nowhere in the chatbot repo. Both sit inside the measured void between the worst
genuine query (0.6893) and the best meaningful off-topic query (0.4552), so no
measured query behaves differently — this is about the server and the phone
having one source of truth. Its known limit is inherited too: keyboard mash is
not caught (`qqqqqqqqqq` scores 0.7867), which is an input-validation problem on
both sides and is still unsolved.

Thresholding is on the **best** score, never on the score of the line finally
served — `app.py` asks "is this answerable at all?" before the anti-repeat rule is
allowed to move the answer to a lower-scoring line.

### English glosses are precomputed, not translated on-device

The server calls Argos Translate (CTranslate2) per request. On-device that is
~159MB more download, an autoregressive decoder loop in Dart, a second
SentencePiece tokenizer and no Flutter binding for CTranslate2.

**It is also unnecessary.** Retrieval can only ever return one of the 5,275 corpus
lines, so the runtime translator was a function over a finite, known domain.
Evaluating it ahead of time is not an approximation of it — it is the same answer.
`subs_en.json` (210KB, a fifth release asset) was produced by running the very
same installed Argos de→en pipeline over the corpus, so the phone's English is
byte-identical to what the server would have replied.

+0.2MB instead of +159MB. The alternative's only advantage — translating text
outside the corpus — cannot occur.

`EmbeddingIndex` treats the gloss file as **optional**: a build that reaches a
phone before the asset does answers in German rather than refusing to start.
It is required in `kModelFiles`, so the download fetches it.

### The download is a choice, not a side effect

`ModelSetupController.build()` used to start downloading. It now only **checks**,
ending at `ModelReady` or the new `ModelNeeded`, and only a tap moves it on.
143MB is not something to start on someone's behalf because they opened a screen —
they may be on mobile data, or just looking.

`ChatGate` is what `/chatbot` builds. The chat has no fallback any more: replies
come from files on this phone, so without them there is nothing to talk to and no
address to fix. The gate sits **outside** `ChatScreen` and hands over to it whole,
because `ChatScreen`'s State mints the `session_id` — a session should begin when
practice begins, not when someone glanced at a download prompt.

Both entry points render `ModelSetupBody`, one widget. Two copies would drift, and
the one that drifts is the gate — the screen a first-time user actually meets.

### Loading happens off the UI isolate

17MB of tokenizer JSON and 8MB of compressed vectors, parsed on the main isolate,
freeze the frame that opened the chat. Both are built inside `Isolate.run`, which
is only possible because the parsed results hold nothing but plain data — asserted
in a test, not assumed. The ONNX session is created on the main isolate: it is a
platform-channel handle and does not survive being sent.

### "Service address" left the chat menu

It edits an address nothing reads while the on-device engine is selected, so
leaving it on the chat's own menu would invite someone to fix a connection problem
they do not have. The screen and route stay, reachable from the dev menu, because
they become meaningful again the moment `chatbotServiceProvider` is pointed back
at HTTP for a comparison. `HttpChatbotService` is kept for exactly that reason: it
is the reference the on-device pipeline is checked against.

### What is NOT verified

**Nothing has run on a device.** The ONNX session, the 118MB model load, inference
latency and memory on the Redmi are all unproven — that is the device pass. What is
proven here is everything either side of the ORT call: the tokenizer against the
real tokenizer, the `.npz` reader against a NumPy-written file, the ranking, and
every retrieval decision that has to agree with the server.

# Exact alarms: the Play-policy assumption was wrong (2026-08-19)

**Context:** the user restated that alarms/reminders/notifications are **the core
of this app, not a side feature**, and asked whether the 2026-07-23 decision to
drop exact alarms was made on a bad premise. It was, in two distinct ways.

## What the policy actually says

Google Play, *Permissions and APIs that Access Sensitive Information*, verbatim:

> "`USE_EXACT_ALARM` is a restricted permission and apps must only declare this
> permission if their core functionality supports the need for an exact alarm."

Acceptable use cases, the complete list:

> - "The app is an alarm or timer app."
> - "The app is a calendar app that shows event notifications."

> "If you have a use case for exact alarm functionality that's not covered above,
> you should evaluate if using `SCHEDULE_EXACT_ALARM` as an alternative is an
> option."

Declaring it also requires a **Play Console restricted-permissions declaration**
("Complete Play Console declaration to indicate app functionality"), reviewed by
a human, typically with a video of the core feature.

The Android platform docs put the same thing the other way round:

> "Calendar or alarm clock apps need to send calendar reminders, wake-up alarms,
> or alerts when the app is no longer running. These apps can request the
> `USE_EXACT_ALARM` normal permission. The `USE_EXACT_ALARM` permission will be
> granted on install, and apps holding this permission will be able to schedule
> exact alarms just like apps with the `SCHEDULE_EXACT_ALARM` permission."

## Error 1 — the qualification call

DECISIONS.md (2026-07-23, notifications diagnosis) recorded *"an accountability
app likely does **not** qualify"*. That was a guess about how a reviewer would
classify us, written as a hedge and then read downstream — in the product
decision and in WORK_PLAN.md §2.1 — as an established finding. It hardened
without ever being checked.

Against the actual text, **we are a plausible fit**: the app's central,
user-facing function is a scheduled item that must alert the user at a specific
time when the app is not running. That is much closer to *"an alarm or timer
app"* than the phrase "accountability app" made it sound. It is not a certainty
— we are not a *dedicated* clock app, the reviewer sees a social/planning
product, and there is no appeal worth betting a launch on. **Honest read:
plausible yes, not guaranteed.**

## Error 2 — the one that actually mattered

**Qualification was never the load-bearing question.** `SCHEDULE_EXACT_ALARM`
reaches the **identical `AlarmManager` code path** — same exactness, same Doze
exemption, same `setExactAndAllowWhileIdle`/`setAlarmClock` — with **no Play
review of any kind**. The only differences are how the grant is obtained
(a user prompt vs. granted on install) and that the user can revoke it.

There is also a **third route that needs no exact-alarm permission at all**: per
the Android 14 docs, apps on the **power allowlist** (`ACTION_REQUEST_IGNORE_
BATTERY_OPTIMIZATIONS`) *"are always allowed to call the `setExact()` or
`setExactAndAllowWhileIdle()` methods."* That is a grant we would very likely be
asking a Xiaomi user for regardless.

So **exact alarms were available to this project the entire time.** "Inexact
scheduling is sufficient" was a **product choice made under a mistaken sense of
constraint**, and it was made at the moment reminders were being framed as
peripheral to the accountability loop. With reminders restated as the core, the
choice does not survive its own reasoning.

## What is NOT reopened

The 2026-07-23 product decision itself — **we are not trying to wake anyone up**,
there is no true-alarm tier, no AlarmKit floor, iOS stays in scope — **stands.**
Exact alarms are about *"the 09:00 item alerts at 09:00, not 09:40"*, which is
table stakes for a planner, not an escalation to a ringing-through-silent alarm
clock. Nothing here unparks voice mode, quiet-hours enforcement, or any parked
feature.

## What is genuinely unverified (and always was)

Not the permission. **Whether any scheduled alarm survives HyperOS's battery
policy on the Redmi.** Exact alarms are exempt from Doze by the *framework*; OEM
app-standby is a separate layer that the framework guarantees say nothing about.
No amount of policy reading answers it.

`spikes/alarm_spike/` (throwaway, off the product tree, package
`com.timeapp.alarm_spike`) arms **four mechanisms at one instant** —
`setAlarmClock`, `setExactAndAllowWhileIdle`, `setAndAllowWhileIdle` (the current
plan's baseline) and a WorkManager one-shot — plus a direct-boot-aware boot
receiver, and writes every fire's **actual-vs-scheduled delay** and device state
to a CSV in device-protected storage. Procedure, grant matrix (G0–G3) and
pass criteria are in its README, **fixed before the run so the result cannot be
rationalised afterwards.**

**Nothing about the reminder layer is decided until that matrix is filled in
here.** In particular, do not let this entry be read as "we chose exact alarms" —
it says the choice was foreclosed on a bad premise and is now open.

## Sources

- [Play — Permissions and APIs that Access Sensitive Information](https://support.google.com/googleplay/android-developer/answer/9888170)
- [Play — same policy, current article id](https://support.google.com/googleplay/android-developer/answer/16558241)
- [Android — Schedule exact alarms are denied by default](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms)
- [Android — Schedule alarms](https://developer.android.com/develop/background-work/services/alarms/schedule)

---

# Alarm spike — the numbers (2026-08-20)

The matrix the entry above said had to be filled in before anything was decided.
Raw data: `spikes/alarm_spike/run_2026-08-20_G2.csv`.

## What was actually run

**One configuration, G2** — exact alarms granted, battery "No restrictions",
Autostart **off**. Runs A and B (short, screen on / app foregrounded) and one
long overnight-shaped run. The full G0→G3 sweep was not done, and Runs C
(force-stop) and E (reboot) were not completed. **This entry records only what
the CSV supports.**

| Cell | Armed → fired | ALARM_CLOCK | EXACT_IDLE | WORKMANAGER | INEXACT_IDLE |
|---|---|---|---|---|---|
| Short, screen on | 18:53 → 18:55 | **+0.17s** | **+0.14s** | (already fired) | +90.0s |
| Short, screen on | 19:03 → 19:05 | **+0.12s** | **+0.10s** | +0.11s | +90.0s |
| **Long, screen off** | **04:51 → 09:30** | **+0.55s** | **+0.62s** | +0.68s | **+110.2s** |

The third row is the one that matters: a 4h39m gap with `interactive=0` at fire
and `batt_opt_ignored=1`. **Both exact mechanisms landed inside a second.**

Also recorded, and worth as much as the timings:

- **G0 is not a degraded mode, it is a broken one.** With the permission not yet
  granted, both exact variants returned `SCHEDULE_FAILED` with a
  `SecurityException` — *nothing was scheduled at all*. There is no silent
  downgrade to catch you; the call fails and only the app can notice.
- **The inexact baseline is 90–110 seconds late, consistently.** That is what
  DECISIONS.md's previous plan ("inexact scheduling is sufficient") would have
  shipped, and it is not a reminder.

## What is decided

**Exact alarms, via `setExactAndAllowWhileIdle`.** `setAlarmClock` measured
marginally better (0.55s vs 0.62s in the only cell where the difference could
matter) and is **not** chosen: it plants a system-wide alarm icon in the status
bar and publishes the next-alarm time to any app that asks. That is a claim on
the device an accountability app has not earned, and 70ms does not buy it. If a
later part finds a cell where `setAlarmClock` is the difference between firing
and not, this gets revisited — the two are one enum value apart.

**`SCHEDULE_EXACT_ALARM`, not `USE_EXACT_ALARM`.** Both reach the same
AlarmManager path. The first is a user prompt with no Play review; the second is
auto-granted but reviewed against a list we are not on. Settled.

## What is NOT decided, and must not be read as decided

- **Reboot durability is UNPROVEN.** Run E was never completed. The only `BOOT`
  rows in the CSV are the install-time artifact the spike README warns about
  (trap 2) — no reboot happened, and there is not a single `REARMED` row
  anywhere in the file. Both boot receivers are shipped on the strength of the
  argument, not a measurement.
- **Autostart's contribution is unmeasured** (G3 never run). Whether
  `BOOT_COMPLETED` is delivered at all on this HyperOS build without it is
  exactly the open question, and it is what decides whether an OEM primer is
  needed. Part 1 does not answer it.
- **Force-stop was not tested** (Run C). Expected to kill everything on every
  configuration — that is stock AOSP, not a Xiaomi finding — but unverified here.
- **G0/G1/G3 were not swept.** The battery allowlist and the exact-alarm grant
  were changed together, so their individual contributions are entangled.

---

# Reminder layer, Part 1 — the core scheduling engine (2026-08-20)

The first reminder code in `lib/`. Gated on the entry above, and scoped
deliberately: **the engine only.** No OEM onboarding, no iOS, no quiet-hours
enforcement, no edge cases beyond the ones the engine cannot be correct without.

## The shape, and why

**`ReminderScheduler` is a seam, in the same sense `ChatbotService` is.** One
interface, four methods, and no OS vocabulary crosses it — no
`AndroidScheduleMode`, no channel id, no `TZDateTime`. Everything above it
reasons about items and instants. That is what makes the iOS implementation a
second class rather than a fork of the logic, and it is what lets the part of
this feature that can actually be wrong be tested without a phone.

**The decision layer is TWO pure functions.**

- `desiredReminders(items, uid, now)` — the one rule for whether an item is
  reminded: I am the target, status is `approved`, no outcome, instant is
  future. It is the only place the reminder layer knows what a `ScheduleItem` is.
- `reconcileReminders(desired, mirror, now)` — the difference between what we
  want and what we believe we have, as a plan.

Neither touches a plugin, a clock or Firestore. `ReminderService` is a thin
applier: sequencing and nothing else.

**Reminders are driven off the ITEM STREAM, not off transitions.** This is the
central design call. The obvious implementation hooks `approve()`, `reject()`,
`withdraw()`, `markDone()`, `markSkipped()` and the builder's edit path — six
call sites that must each be right, and a seventh the day someone adds a
transition. Instead there is one rule ("is this item still desired?") applied to
whatever the stream currently says, so **withdraw, reject, outcome and edit are
not special cases at all** — each merely stops producing a desired entry.
`OutcomeScreen._markDone` cancels no reminder and mentions none.

Reconciliation additionally runs on **app start** and **every resume**, because
the events that invalidate a scheduled alarm happen while the app is not running
and produce no stream emission: a reboot, an app update, a permission revoked or
granted in Settings, or simply time passing. It is idempotent by construction —
re-running it against its own output produces an empty plan — which is what makes
running it that often free.

## The local mirror

**`shared_preferences`, not a query.** Android cannot be reliably asked what it
holds: `pendingNotificationRequests()` reports flutter_local_notifications' own
bookkeeping, which is a different thing from an AlarmManager registration and
stays confidently wrong after a reboot, an update, or a revoked exact-alarm
permission. So the app keeps its own record and treats it as a **belief**, told
to the OS and never read back from it.

The two error directions are deliberately asymmetric. Mirror-says-yes /
OS-says-no loses a reminder silently and is the failure worth engineering
against. Mirror-says-no / OS-says-yes re-schedules under the same deterministic
id, which **replaces** rather than duplicates, and is harmless. Every ambiguous
case therefore resolves toward re-scheduling: a corrupt row is dropped, an
unreadable store reads empty.

**A refused schedule is kept OUT of the mirror.** Recording it as armed would
make every later reconcile believe it exists and never retry — a reminder lost
permanently, silently. Left out, granting the permission and returning to the app
repairs it with no extra code.

## Notification ids

Deterministic FNV-1a over the Firestore id, masked to a positive 31-bit int.
Determinism is the requirement, not uniqueness: cancelling means reproducing the
id exactly, from a cold start, possibly with no mirror. A counter cannot do that.

**The collision story is real, not hand-waved.** 31 bits over 20-character ids is
a birthday collision at ~46,000 simultaneous reminders, and the failure it causes
is silent (item B's alarm overwrites item A's, and A simply never fires). So the
hash is a *preference*: `allocateNotificationId` linear-probes past a taken id,
the incumbent keeps its id, and the winner is recorded in the mirror, which is
the authority thereafter. Pinned by test, including that the incumbent is not
displaced and that allocation does not depend on Firestore's arrival order.

## The POST_NOTIFICATIONS ask moved

`MessagingService._attempt()` called `FirebaseMessaging.requestPermission()`
during token registration — i.e. on the first signed-in build, before the user
had seen a screen. Android grants that prompt roughly once and a denial is
effectively final. **That call is removed.** Token registration is unaffected:
`getToken()` never needed the permission, and the old code already proceeded
whether the prompt was granted or denied.

The ask now belongs to `ReminderPrimerCard`, which appears on My Schedule only
when the user has an approved item still ahead of them *and* the OS will not
deliver it — and explains itself before the system dialog appears. The two
permissions are asked **separately, in order of consequence**: POST_NOTIFICATIONS
decides whether a reminder appears at all, SCHEDULE_EXACT_ALARM decides whether
it appears on time, and the spike measured the second as 0.6s versus 110s.
Bundling them would make the second invisible.

Dismissal is session-scoped and deliberately not persisted: the card is the app
saying "the reminders you approved will not arrive", which stays true until it is
fixed.

## Tap routing

`NotificationRouter` is now the one place that decides where a notification tap
lands, because there are two tap sources (FCM and local) arriving through
unrelated plugin callbacks. Two copies of the destination table would drift the
first time a route moved — and these routes already moved once, in the Session 3
shell refactor.

A reminder carries **only the item id** as its payload — a string the OS holds
for hours should be a key to look up, never a copy of anything. It routes to
`/outcome?item=<id>`, which scrolls that card into view and outlines it for six
seconds. A query parameter rather than an `/outcome/item/:id` sub-route: the
destination is the same list with the same Done and Skip controls, and a
sub-route would be a second rendering of one item to keep in step, with a Back
that drops you onto the list you were already looking at.

The fade is not cosmetic. My Schedule is a shell branch, so its location —
query parameter included — survives every tab switch for the life of the
process; without the fade, an item tapped this morning would still be outlined
tonight.

## The audit CSV came with us

`spikes/alarm_spike/`'s logging is ported into `android/.../reminders/` and
`reminder_audit_log.dart`. A **silent shadow alarm** is armed at the same instant
and by the same mechanism as each reminder, and its receiver appends one row:
delay, plus the device's Doze / power-save / battery-optimisation / screen state
**at the moment of delivery**, without which a 40-minute delay is
uninterpretable.

Why a second alarm rather than a callback: flutter_local_notifications posts its
notification from its own native receiver and never starts Dart, so there is no
Dart callback at fire time to hook — and one that existed would fold Flutter's
cold start into the number being measured. Device-protected storage, and a
direct-boot-aware receiver, so a reboot can be recorded before the first unlock.

**Cost, stated plainly: two exact alarms per reminder.** It is an instrument, not
a feature — deleting the two receivers, `ReminderAudit*.kt` and
`reminder_audit_log.dart` removes it with no effect on whether reminders fire.
It earns its keep as long as real-world fire timing on this device is an open
question, which it is: the spike answered the laboratory version, and Runs C, D
and E are still unfilled.

## Deliberately deferred to later parts

OEM autostart/battery onboarding (and the Run E result that should decide where
it goes); iOS (`DarwinInitializationSettings`, the 64-notification cap, and the
`CFBundleLocalizations` question that is still blocked on there being an iOS
target at all); quiet-hours *enforcement*, which remains warnings-only —
filtering reminders here would silently drop items the user approved; recurring
reminders; snooze; a lead-time offset ("remind me 10 minutes before"), which is
the first thing that will want `ScheduleItem.durationMinutes` and should be
decided with the goals phase, not before it.

## Icon vocabulary additions

`AppIcons.reminders`, `AppIcons.exactTiming`, `AppIcons.clearLog` — three new
concepts under §6.6 rule 1, not re-uses. `exactTiming` is separate from
`reminders` on purpose: "will I be reminded" and "will I be reminded on time"
are two permissions with two system screens, and a user who has one and not the
other has to be able to tell which is which.

## Ending a relationship — leave / remove / stop planning (2026-08-20)

Until now the only relationship control in the app was the target's
"can plan for me" switch. There was no way to remove anyone, no way to leave a
group, and no way for a *planner* to give up a grant they held. The rules made
that structural, not accidental: `allow delete: if false` on every collection,
and the `groups` update rule was a self-join-only shape (caller not already a
member, exactly one element added). Membership could only ever grow.

**Three rule changes, all narrow.**

1. **`/groups/{groupId}` update** now admits a second shape beside `isSelfJoin()`:
   `isMemberRemoval()` — exactly one uid dropped, nothing added, and **never the
   owner**. The remover is either that member (leaving) or the owner (ejecting).
   The owner exclusion is not politeness: `/groups` has `delete: if false`, so a
   group that lost its owner could never be cleaned up by anyone, ever. **The
   owner therefore cannot leave their own group** — a real product limitation,
   recorded here rather than discovered later.
2. **`/groups/{groupId}/members/{memberUid}` delete** — self, or the owner, and
   never the owner's own doc. Gated on `callerInGroup()`, which is why the client
   must delete the roster doc *before* dropping the uid from `memberUids`. That
   is the exact inverse of the join, and the ordering is load-bearing: reversed,
   the caller locks themselves out of their own cleanup.
3. **`/groups/{groupId}/plannerGrants/{grantId}`** split `create` from `update`.
   The target still sets consent either way. A **planner may now write
   `granted: false` and nothing else** — giving up a power you already hold is
   not a coercion risk, and it is what "stop planning for them" needs. A planner
   who could write `true` could grant themselves authority over another person,
   which is the single thing this model exists to prevent. `grantedByUid` is
   left as the target wrote it, so the consent trail survives revocation. The
   split exists because the planner branch reads `resource` via `changedKeys()`,
   which does not exist on a create.

Validated against Firebase's own rules compiler via
`firebaserules.googleapis.com/v1/projects/time-app-1e1c9:test` — compiles clean.
**NOT YET DEPLOYED.** Until it is, the new UI returns `PERMISSION_DENIED`; deploy
rules first, verify the *deployed source*, then install — the same discipline the
archive feature is held to.

**Known residue, accepted for now.** When an owner ejects a member, grants
between that member and a *third* party are left at `granted: true` — the ejector
is party to neither side and the rules refuse it. They are inert: creating an
item additionally requires the planner to still be in the group
(`uidInGroup`), so the stale grant buys nothing. Its only symptom is a stale row
in the ejected member's own target picker, which fails at save. The fix would be
an owner-may-revoke-any-grant-in-their-group branch; it was **rejected for v1**
because it hands the owner power over a consent relationship they are not part
of, and the consent model is the product. Revisit if it bites.

**`removeMember()` is deliberately not a transaction.** Three documents under
three different rules; atomicity is not on offer. `memberUids` is the single
source of truth for membership and it moves last, so a partial failure leaves
only inert residue and re-running cleans it up.

## Data reset — grants soft-cleared (2026-08-20)

All six planner grants involving `42ml93AS…` were set to `granted: false`
server-side (admin REST, since the rules correctly refuse a client the
planner-side revoke that this same session added). Groups, membership and
schedule items were left **untouched** — the chosen scope was the reversible one.
`brY8JaR7 → P5eNrQfN` (a grant between two other people) was deliberately left at
`granted: true`: it is not the signed-in user's relationship to end.

## Rules deploy verified (2026-08-20)

Live ruleset **`47c62b28-f776-4458-a12f-a5e0d5679168`**, released
2026-08-20T10:20:36Z. It **supersedes `1cff4c97-3dbf-4e6b-abec-8d3d9a048a8e`**.

Verified the way this project requires — a ruleset id proves *something*
deployed, not *what*. The deployed source was fetched back from
`GET firebaserules.googleapis.com/v1/{rulesetName}` and diffed against the local
`firestore.rules`: **byte-for-byte identical.** All three changes from "Ending a
relationship" are confirmed present in the deployed source, and the §6/§6.1
hardening, the `fcmTokens` block and the item-create `status` constraint did not
regress (they are in the same file that matched).

Also confirmed server-side the same day: the six planner grants involving
`42ml93AS…` all read `granted: false` (`updatedAt 2026-08-20T10:00:53Z`), and
`brY8JaR7 → P5eNrQfN` remains `true` — correctly untouched, being a relationship
between two other people.

**Not verified: anything on a device.** No leave / remove / stop-planning has run
against the live rules, and the installed APK predates the feature.

---

# Social profile layer — SHIPPED 2026-08-21

The first feature in the app that is **not** part of the delegation loop and is
nevertheless wired into it. `lib/features/social/`. Built in one session at the
user's explicit direction, after they were shown the phased alternative and
chose otherwise.

## The premise that had to be corrected first

The request framed cross-device planning and alarms as future work to leave room
for. **They already ship.** `groups/{id}/plannerGrants/{plannerUid}_{targetUid}`
is the permission model, the `pending → approved` state machine is per-plan
approval, FCM plus the Worker is the cross-device push, and
`lib/features/reminders/` fires the alarms. So the question was never "will the
schema support it later" but "how does a friend graph meet a group-scoped
permission model that is already deployed and device-verified".

## Friends sit ALONGSIDE groups. They do not replace them.

Chosen over two alternatives (friends replace groups; friendship gates group
membership), because the group model is shipped, rules-hardened and verified
with a real second person on 2026-07-24, and rewriting it to win conceptual
tidiness would put the working half of the product at risk for no user-visible
gain.

So: **groups remain the delegation mechanism; friendship is a social tie that
grants nothing.** Being someone's friend does not let them plan your day. That
separation is not a compromise — it is the consent model restated. Planning
permission stays a directed, revocable, target-granted thing, and a friend graph
is the wrong granularity for it.

**The migration path, if a friendship should ever carry planning permission:**
`watchTargetsFor()` is a COLLECTION-GROUP query on `plannerGrants`, so a
`friendships/{pairId}/plannerGrants/{id}` subcollection is picked up by the same
query with **no client change**. The bottom-of-file `/{path=**}/plannerGrants`
read rule already covers it too. That is the non-rewrite escape hatch, and it
exists by accident of good earlier design rather than by anything done here.

## Deterministic document ids are the load-bearing decision

**Rules can `exists()` a path they can construct; rules cannot run a query.**
Everything else follows from that one sentence.

A friendship under an auto-id, findable only by `where('participants',
arrayContains: …)`, is invisible to the rules engine — and a privacy toggle the
rules cannot evaluate is not a privacy toggle, it is a label. So:

- `friendships/{sortedPairId}` — **sorted**, because friendship is symmetric and
  both parties must compute the same address. One edge, no half-edge to leave
  behind, no second document for a rule to have to check.
- `friendRequests/{fromUid}_{toUid}` — **not sorted**, because a request is
  directed. Sorting would make crossing requests overwrite each other.
- `blocks/{blockerUid}_{blockedUid}` — **not sorted**, because A blocking B is
  not B blocking A, and both may exist.

`social_ids.dart` and the `sortedPairId()` helper in `firestore.rules` compute
the same ids and **must stay in step**. They are the two halves of one mechanism.

(The rules helper is named `sortedPairId`, not `pairId`, because
`match /friendships/{pairId}` binds a wildcard of that name which would shadow
the function inside the one block that needs it most. Caught by the emulator
suite; it would have been a silent always-deny.)

## Uniqueness: `usernames/{handle}`, the same trick as `joinCodes/{CODE}`

Firestore has no unique index and rules cannot query, so uniqueness is built out
of the only atomic primitive available: **a document id**. The canonical
lowercased handle IS the id, so two people racing for one handle race for one
document and Firestore serialises it.

`list` is **denied**, and this is the load-bearing half. `users` already has
`list: if false` because listing it leaked every user's name, home timezone and
quiet-hours window — when each person sleeps (ARCHITECTURE.md §4.1a). Allowing
`list` here would rebuild that capability one hop away: sweep the handles, get
each uid, get each profile.

**Consequence, accepted deliberately: search is exact-match only.** No prefix, no
fuzzy. People exchange handles out-of-band, exactly as they already do with group
join codes. `user_search_screen.dart` says so to the user in plain words rather
than letting them conclude search is broken.

**Canonicalisation is locale-independent** (`toLowerCase()` with no locale). The
Turkish dotted/dotless I would otherwise canonicalise the same handle to two
different reservation keys depending on the typist's phone — a uniqueness
guarantee that silently depended on the device.

### The claim is TWO writes, and it cannot be one

`UsernameRepository.claim` runs a transaction (reservation) and then a separate
plain write (the `users/{uid}.username` mirror).

**Rules see the last COMMITTED state, never the pending writes of the transaction
being evaluated.** The rule guarding the mirror asks "does this user actually
hold a reservation for the handle they claim to display?" — and if the mirror
write shared the transaction, that check would run against a world where the
reservation does not exist and *every claim would be denied*. This was found by
reasoning it through before writing the rule; it would otherwise have shipped as
a feature that never worked once.

Failure between the two steps leaves the reservation held and the profile showing
the old handle: visible, harmless, and fixed by pressing Save again.

The mirror rule matters because without it a user can write `username: 'admin'`
onto their own document without holding the reservation. Search is unaffected (it
resolves through `usernames/`), so the damage is impersonation on the profile
screen — the reserved-handle list defeated through a different door.

It is gated on `username` actually CHANGING. Re-checking on every profile write
would spend a `get()` per quiet-hours edit and — worse — would deny every future
write if the reservation ever went missing, locking a user out of their own
profile over a field they never touched. Same trap the `name` note in
`firestore.rules` describes.

## Privacy: stats live in a SUBCOLLECTION, and they had to

`users/{uid}` is `allow get: if signedIn()` **by design** — the planner needs the
target's name and home timezone and vice versa. That rule does not consult
`isPublic` and cannot. So a number stored on that document is published to every
signed-in user, and the privacy switch is a decoration.

Hence `users/{uid}/profileStats/summary`, with a rule that reads the toggle:

```
blocked?           → deny, before anything else is consulted
own document       → allow
owner isPublic     → allow          (the future leaderboard)
caller is a friend → allow
otherwise          → deny
```

**A pending request grants nothing.** If it did, a private profile would be
readable by anyone willing to tap Add friend and never follow up.
`profile_visibility.dart` mirrors this in Dart and is deliberately the stricter
of the two — the client being stricter hides a control that would have worked
(invisible, safe), the client being looser offers a control that always fails.

**Cost, named:** up to three document reads per stats read (two block ids, one
friendship id) plus the owner's profile. All `exists()`/`get()` on **computed**
ids, never a query. That is the price of expressing privacy in rules at all, and
it is paid only on a profile view.

## Stats are PUBLISHED, not derived on read

A visitor cannot compute your numbers: your items live at
`scheduleItems/{you}/items` and only you may read that subtree. So the owner's
device computes and writes a small document, and the visitor reads it if the gate
allows.

**Driven off the item stream, never off transitions** — deliberately the same
doctrine as the reminder layer, and stated in `app.dart` next to the reminder
wire. There is no `publishStats()` call in `markDone()`, `approve()` or anywhere
else. One recomputation is applied to whatever the stream currently says, so an
outcome, an edit, a withdrawal and a rejection are not special cases. A
per-transition hook would create a second place that decides, and the two would
disagree.

`myComputedStatsProvider` reads `allItemsAsTarget/PlannerProvider` — the RECORD
layer. It is **the first record-layer consumer in the app**, which is what the
constraint comment in `schedule_providers.dart` was written for.

**Extensibility is `kProfileStatDefinitions`.** Adding a statistic is one entry;
turning a placeholder live is giving that entry a `compute` function. Nothing in
the section widget knows what a streak is. Placeholders are **omitted from the
published map, never written as zero** — a stored `hoursTracked: 0` is
indistinguishable from a measured zero, so a visitor's tile would render a
confident, wrong number. Unknown keys are ignored on read, so an older build
reading a newer user's document degrades to what it understands.

Streaks count days in the **home timezone**. A streak breaks at the midnight the
person actually slept through, and the app already anchors every commitment to
`homeTimezone` for the same reason. It ends "today or yesterday" so it does not
break at midnight while the user is asleep and reappear next morning.

## Blocking is a cascade, not a write

Placing the document is the easy part. What makes it mean anything is severing
the standing permissions, and in this app those are unusually consequential — a
live planner grant is permission to put items on someone's calendar and ring
their phone.

Order, chosen so every intermediate state is safe:

1. **the block document first** — it is what every gate reads, so from that
   moment the two are invisible to each other even if nothing else succeeds;
2. planner grants, both directions;
3. the friendship;
4. pending requests, both directions.

A failure part-way leaves a live block with inert residue, and re-running cleans
up. Tidy-first-block-last would leave a window in which the relationship is
half-dismantled and the block is not yet in force.

**Existing schedule items are deliberately untouched.** They are a shared record
of something that was consented to, and rewriting them is the "delete for me"
dishonesty rejected on the archive feature. The grant revocation stops anything
new; withdraw and reject already handle what exists.

**Unblocking restores nothing.** Re-blocking must not be a way to silently re-arm
someone's permission over your calendar.

**The record is one-way; enforcement is both ways.** A one-directional check
would leave the blocked party reading the blocker's profile.

**A block and a missing account render identically** (`AppIcons.profileUnavailable`)
on the profile screen AND in search results. Telling someone they have been
blocked hands them the one fact the feature withholds. `ProfileRelation` keeps
`blocking` and `blockedBy` distinct internally so the viewer's own controls can
differ — someone who has been blocked can still block back, and removing that
control would announce the block by its absence.

**Cost, named:** `blocks/{id}` allows `get` to the blocked party, because the
client has to know it is blocked in order to hide the profile. A determined
reader can therefore detect a block by fetching a computed id. The UI never tells
them, but this is a UI property, not a data one. Closing it would mean the
blocked client could not hide the profile at all, which is worse.

## Profile pictures: Supabase Storage, via the existing Worker

**Firebase Storage is unavailable to us.** It needs Blaze, and this project has
no payment card attached — a documented, deliberate position (see
"Completion→planner push"). This is the second feature that constraint has
shaped.

Picked against three requirements: free **without a card** (Cloudflare R2 fails —
it wants one even on the free tier), genuinely open source and self-hostable
(Cloudinary, ImgBB fail), and able to serve animated GIF and WebP untouched.
Supabase Storage is Apache-2.0, has a 1 GB no-card free tier, and is plain object
storage.

**Uploads go through the Cloudflare Worker, not direct from the phone.** Supabase
authorises with its own JWT and has never heard of a Firebase uid; reconciling
them client-side means shipping a Supabase **write** key in the APK. The Worker
already solves exactly this for push — verify a Firebase ID token, hold
privileged credentials that never leave Cloudflare — so `/avatar` is 100 lines
next to `/notify` rather than a new service.

It is also where the caps are actually enforced. Client-side checks exist only so
the user hears "too large" before waiting through an upload.

- **Format is decided by SNIFFING THE BYTES**, not by `Content-Type`. A declared
  MIME is a claim. An SVG served from a trusted origin is a scripting primitive,
  not a picture; a mismatch between claim and reality is refused rather than
  silently corrected.
- **Two caps: 2 MB static, 5 MB animated.** Animated formats legitimately need
  more because they carry frames; one shared cap would either ban animation in
  practice or wave through enormous stills. Unknown types get the stricter one.
- **`image/webp` gets the animated cap even though most WebP is still**, because
  nothing can tell them apart without decoding the container.
- **No image transformation is ever requested.** Supabase's transform API is
  paid, and resizing an animated image server-side is the standard way to flatten
  it to one frame. No cropping or compression package on the client either, and
  `imageQuality`/`maxWidth` are not passed to `image_picker` — all of them
  re-encode. Originals only; the UI scales for display.
- **A key is only yours if it sits under `avatars/{uid}/`.** Every delete is
  checked against that, from the VERIFIED token — otherwise `X-Previous-Key`
  would let a caller have the Worker (which bypasses every storage policy) delete
  someone else's picture.
- **Delete answers 200 for a key that is not yours**, not 403. A 403 would
  confirm that some other user's key exists.

### Moderation: a flag, and an honest one

`AvatarModeration` defaults to **`approved`, not `pending`**. There is no
moderation queue and no moderator, so `pending` would mean nobody's picture is
ever shown. `flagged` stays visible — a report is an accusation, not a finding,
and hiding on accusation alone is a griefing tool. `pending` and `rejected` are
withheld, and an **unreadable** moderation value fails CLOSED to `pending`, so a
corrupt field cannot become a way to display a rejected picture.

The read path already branches on all four, so adding a classifier later changes
who writes the field, not who reads it. The Report control does not claim a
review will happen, because none will.

## What was NOT built, and why it is not an oversight

- **Another user's friend count.** The rules scope every friendship read to the
  caller, by design — the alternative is letting anyone map the social graph.
  `friendCountForProvider` exists as a named provider returning null, so the next
  person to look for it finds the reason instead of adding a query that will be
  denied. Publishing a count into `profileStats` would offer it; that is a
  disclosure decision and it has not been made.
- **A denormalised friend counter.** Cannot be maintained correctly without a
  server: accepting a request would be three writes across two users' documents,
  no client may write another user's profile, and any client that could would
  race. The viewer's own count is the length of a list already in memory.
- **Rate limiting on friend requests.** There is nowhere to put it without Blaze
  or a Worker KV namespace. Named here so it is not rediscovered as a surprise.
- **Push notifications for friend events.** The Worker's `/notify` contract is
  `{event, targetUid, itemId}` with authorization branched per event and the
  recipient computed structurally from a schedule item. A social event does not
  fit that shape; adding one is a Worker change and a contract decision.
- **Friends as a fourth nav tab.** The bar's three destinations are the three
  stances in the delegation loop and a friend graph is none of them — the same
  reasoning recorded for the chatbot on 2026-08-18. It lives in the account menu,
  above the divider, with the request count badge.

## This resolves two deferred questions

CLAUDE.md open item 7 ("share-a-group profile-read scoping") and the goals-phase
note that "who can see my goal stats" must be answered **together** with it. Both
are now answered by one mechanism: **a friend graph plus an owner-controlled
public/private toggle, gating a stats subcollection.** Goal stats, when they
arrive, are entries in `kProfileStatDefinitions` and inherit this gate — they do
not need a second visibility model, and `feature-ideas.md`'s "own share list, NOT
a reuse of plannerGrants" is satisfied by exactly this.

`users/{uid}` itself is still readable by uid. That was left alone deliberately:
tightening it needs a denormalised `groupIds` on every user document plus a
backfill, it would now ALSO have to admit friends, and the delegation loop
depends on it working. Unchanged scope, new answer for the part that matters.

---

# Test suite — two pre-existing failures fixed 2026-08-21

Not part of the social work; found because the suite had to be green to trust it.

**`test/reminder_scheduling_test.dart` was date-dependent and expired after one
day.** Its fixture pinned `now = DateTime.utc(2026, 8, 20, 12)` — the day it was
written — with every item two hours later. The pure-function groups are handed
`now` explicitly and were fine. `ReminderService.sync` is not: it reads
`DateTime.now()` itself (`reminder_service.dart:95`). So from 2026-08-21 every
fixture item was in the past, `desiredReminders` filtered them all out, and seven
service tests failed against an empty plan. Anchored to the real clock, truncated
to whole **milliseconds** — the mirror serialises `fireAtMs`, so a microsecond
component cannot round-trip and the round-trip test failed on it. Everything is
relative to `now`, so each test's meaning is unchanged and now true on any day.

**`firestore-tests` ran its files in parallel against one emulator.**
`node --test` runs each file in its own process concurrently, and every file
calls `clearFirestore()` in `beforeEach` — so adding `social.test.mjs` made the
two wipe the database out from under each other. It presented as a scatter of
`ALLOWS …` failures across unrelated describes, changing run to run, while each
file passed alone. `npm test` now passes `--test-concurrency=1`; the README says
why, so the next file added inherits it rather than rediscovering it.

---

# Killed-app alarm delivery — OneKeyClean answers open item 1 (2026-08-22)

**The first hard evidence on HyperOS's kill behaviour, gathered by accident.** A
routine "is my 7am reminder armed?" check caught the failure mode mid-flight,
because the phone had killed the app three minutes earlier. Everything below is
`dumpsys alarm` / `logcat -b events` on the Redmi (HyperOS, Android 16),
**release build** (`run-as` refused: `package not debuggable`), so the mirror and
the audit CSV were unreadable and `dumpsys` was the only witness.

## What happened, from the device

| Time (IST) | Event |
| --- | --- |
| 00:26:48 | Install. `installer_clear_app_data_caller` — **app data wiped**, so prefs, mirror and sign-in went with it |
| 00:26:50 | App started (pid 7758), reconciler armed the 07:00 pair |
| **00:29:34** | **`am_kill: [0,7758,com.timeapp.time_app,905,OneKeyClean,252460]`** |
| 00:30:10 | Both alarms gone, `Reason=pi_cancelled`. `Pending alarms per uid` had no `u0a402` row at all |
| 00:31:41 | App reopened by hand → reconciler re-armed 07:00 |

**OneKeyClean is HyperOS Security's "Boost speed" / one-tap clean.** It took ~20
processes in the same sweep — `com.whatsapp`, `com.android.settings`,
`com.truecaller`, even `com.miui.securitycenter` itself — so this is not
something the app provoked.

**Mechanism: inferred, not observed.** A plain `killBackgroundProcesses` does not
cancel PendingIntents, and **no `am_force_stop` event was logged** for the
package. What is certain is the correlation and the outcome: kill at 00:29:34,
`pi_cancelled` on both alarms 36s later, nothing else touched the app in that
window, and zero pending alarms afterwards. Whether MIUI issued a true
`forceStopPackage` is unproven. It does not change the conclusion.

## The conclusion, which is the point

**Open item 1 ("BACKGROUNDED / killed-app delivery … unproven") now has an
answer on this device: it FAILS, silently.** A HyperOS Boost drops every armed
alarm, raises no error to anyone, and writes nothing the app can see. The
reminder came back **only** because the app was reopened by hand — the
item-stream reconciler did exactly its job, but it needs a process to run in, and
that is precisely what was taken away.

This is the strongest argument yet for the OEM primer, and it also sharpens what
the primer is *for*: not Doze (`flags=0x5` already handles that) but the user's
own cleaner app.

## The arming itself is correct — that was never in doubt

```
RTC_WAKEUP #50: Alarm{ba585bd ... com.timeapp.time_app}
  tag=*walarm*:com.timeapp.time_app/...ScheduledNotificationReceiver
  type=RTC_WAKEUP origWhen=2026-08-22 07:00:00.000 window=0
  exactAllowReason=permission  flags=0x5
```

`window=0` = exact; `flags=0x5` = STANDALONE | ALLOW_WHILE_IDLE, i.e.
`setExactAndAllowWhileIdle` as chosen; `exactAllowReason=permission` is the OS
stating it granted exactness **because** `SCHEDULE_EXACT_ALARM` is held. Two
alarms per reminder (the reminder + its `REMINDER_AUDIT` shadow), exactly the
documented cost.

## Mitigation applied, and how it was verified

Autostart on, battery → No restrictions, app locked in recents:

| | Before | After |
| --- | --- | --- |
| Autostart | `MIUIOP(10008): ignore` | `MIUIOP(10008): allow` |
| Doze whitelist | absent | `user,com.timeapp.time_app,10402` |
| Standby bucket | 10 (ACTIVE) | **5 (EXEMPTED)** |

It now sits in *Exempted bucket packages* beside `com.whatsapp` and
`com.android.deskclock`. `MIUIOP(10008)` was confirmed to be the Autostart op by
comparison, not assumption — WhatsApp/Gmail/Instagram read `allow`, time_app and
another third-party reminders app read `ignore`.

**The settings changes did not disturb the armed alarms**, proven by object
identity rather than by re-reading the time: `Alarm{ba585bd}` /
`PendingIntentRecord{2f91510}` and `Alarm{167b7b2}` / `PendingIntentRecord{d56c3c2}`
are byte-identical across dumps 12 minutes apart, and the newest removal-history
entry stayed the 00:31:41 reconciler churn. A cancel-and-re-arm would have
minted new ones.

## Still NOT proven — do not read this entry as more than it is

- **That the mitigation works.** No second Boost has run since. Untested.
- **Reboot re-arm.** Unchanged from the spike; still not one `REARMED` row.
- **That it fires at 07:00.** Arming is not firing.
- **The recents lock.** No `dumpsys` surface was found for it; unverified.

## Sidebar: why App Info shows only "Notifications" — not a bug

The user reasonably expected to grant an alarm permission in App Info and found
only Notifications. That is correct behaviour, twice over:

- **App Info → Permissions lists only *runtime* ("dangerous") permissions.** Of
  the 12 the app requests, exactly one qualifies — `POST_NOTIFICATIONS`.
  INTERNET, WAKE_LOCK, VIBRATE, RECEIVE_BOOT_COMPLETED, ACCESS_NETWORK_STATE,
  USE_BIOMETRIC and the rest are install-time and never appear there.
- **`SCHEDULE_EXACT_ALARM` is a "special app access,"** deliberately kept out of
  that list. It lives at **Settings → Apps → Special app access → Alarms &
  reminders**, and it was already `allow`.

Recorded because the future OEM primer must deep-link to the *right* screens, and
because "the permission is missing" is the natural wrong conclusion to draw here.
`ReminderPermissions` already sends the user to the correct place; the gap is
that nothing tells them App Info is not it.

---

## In-app calendar — a VIEW over the item stream (2026-08-21)

A month / week / day calendar over the schedule items that already exist.
`lib/features/calendar/`. **It introduces no data.** No collection, no document,
no field, no Firestore rule, no index, no permission, no Worker event. Every
byte it renders comes from `myItemsAsTargetProvider` and
`myItemsAsPlannerProvider`, which were already there.

### What the leading apps do, and which parts we can actually copy

TickTick ships month, week, agenda, multi-day, multi-week and yearly views, and
its real differentiator over Todoist is a *native* calendar that plots tasks in
the same surface as events, with drag-to-timeblock. Todoist treats a calendar as
a sync target and gives tasks due dates rather than time slots. Google
Calendar's mobile conventions are the rest of it: swipe to page, a "jump to
today" control in the top-right, and dot markers per day.

Three of those we take: **the month/week/day toggle**, **markers per day**, and
**tap a date → that day's list**. One we structurally cannot:

> **No time-blocking, and this is a model fact, not a shortcut.**
> `ScheduleItem` has no duration field — it carries an INSTANT, not a span. It
> is already recorded above (and in CLAUDE.md, "Carried into the goals phase")
> that adding `durationMinutes` is an open decision belonging to the goals
> phase. Drawing an item as a sized block would invent a duration the model does
> not have, and drag-to-resize would need somewhere to write it. So the day view
> is an hour **rail** — items pinned beside the hour they fall in — not a
> proportional grid.

The moment `durationMinutes` lands, the day view is the one file that changes.

### Which day an item falls on: its OWN timezone, not the device's

An item carries `timezone`, a snapshot of the target's home zone, and the whole
app already renders it there (`formatInstant`). The calendar grid therefore
places an item on **the date it displays as** — `calendarDayFor()` resolves
`scheduledInstantUtc` in `item.timezone` and truncates.

The alternative — bucketing everything by the *viewer's* device zone — was
rejected because it makes the grid disagree with the card sitting inside it. A
planner in Chicago looking at an 09:00 Kolkata item would see a card that says
"Tue 9:00 AM" filed under Monday. The card is not wrong; the bucket would be.
The cost is accepted and stated: with items in several zones, two cards on one
day can be minutes apart in real time and hours apart on the clock. That is
honest about what a cross-timezone plan IS.

An unparseable zone falls back to the device zone rather than throwing — a
malformed document must not take the whole calendar down with it.

### Both roles, deduped — the Archived precedent

The calendar merges items where the viewer is the TARGET with items they
created as PLANNER, deduped by id (a self-planned item is in both streams, as
`archivedItemsProvider` already had to handle). A calendar showing only half of
your commitments would be a worse answer to "what is my week" than the two tabs
already give.

This is the same shape as the Archived screen — a cross-role view belonging to
neither tab — so it takes the same navigation answer: **top-level route reached
from the account menu**, pushed, covering the nav bar. It is deliberately NOT a
fourth nav tab. The bar's three destinations are the three stances in the
delegation loop, and that reasoning has now held twice, for the chatbot
(2026-08-18) and for Friends (2026-08-21); a calendar is a lens over all three
stances, not a fourth one.

### It reads the VIEW layer, not the RECORD layer

`schedule_providers.dart` warns that stats/summaries must aggregate the RECORD
providers. The calendar is not such a consumer: it is a feed, so it takes the
filtered view and an archived item correctly disappears from the grid. Stated
here so the constraint is not misapplied in the other direction.

### Package: `table_calendar` 3.2.1, for the grid only

Apache-2.0, released 2026-08-09, ~585k downloads/30d, 3.3k likes. Its only
non-Flutter dependencies are `intl` (ours already, 0.20.2) and a gesture helper.
No platform channel, so **no new permission and no native code** — which is the
property that mattered most, given where this app's risk actually lives.

It supplies the month/week grid and its paging. It does **not** supply a day
view, and we would not have used one: see the duration argument above. Every
cell is drawn by our own builder, because `table_calendar`'s defaults render day
numbers with `'${day.day}'` — Latin digits, which would silently break the
standing worldwide requirement in a locale using Arabic-Indic numerals. Ours go
through `formatDayOfMonth()` in the one date/time helper, and the week start
comes from `MaterialLocalizations.firstDayOfWeekIndex` rather than a constant.

### Tap an item → view, never edit. The rules forbid the edit.

The brief asked for view/edit. **Edit is not buildable without a rules change**
and is therefore not built. `firestore.rules` whitelists exactly the target's
approve / reject / done / skip and the planner's withdraw; `title` and
`scheduledInstantUtc` are immutable after create, and the block says so in
terms — *"Planner edit is still deferred."* `ScheduleRepository` has no
`updateItem` to call.

No disabled "Edit" affordance was added either. A stub would imply the feature
is one tap away when it is a rules deploy away.

What a tap does instead: a detail sheet, then **one action that routes to the
canonical screen** — `Routes.outcomeForItem(id)` for an item targeted at you
(which already scrolls to the card and outlines it, carrying the real Done and
Skip controls), or Activity for one you planned. There is deliberately no second
rendering of Done/Skip inside the calendar. That is `OutcomeScreen`'s own stated
reason for not being a detail screen, applied one level out: two renderings of
one item's controls are two things to keep in step.

### Creating from a date — the ONE touch of existing code

`ScheduleBuilderScreen` gains an optional `initialDate`, defaulting to null,
which seeds `_date`. Null behaves exactly as before. This is the whole
integration: the calendar does not get a parallel create flow, it pushes the
real builder with the tapped date already filled.

`/calendar/new` is a sub-route of `/calendar`, mirroring `/friends/search` —
the calendar is a top-level pushed route, so its create flow belongs to its own
stack and Back returns to the grid. It is a second registration of
`ScheduleBuilderScreen`, and that is examined rather than assumed: D2 was three
screens registered as tabs AND as flat top-level paths, where the harm was a
notification `go()` becoming ambiguous. Nothing deep-links to the builder, and
the alternative — pushing a location inside the Activity branch from outside the
shell — is the shape D2 actually punished.

### Markers reuse the ONE status mapping

A day cell's dots take their colour from `statusStyle()` / `outcomeStyle()` —
`style.background` for tinted and solid, `style.border` for the neutral
treatment, which is transparent by design. No new colour, no local switch, and
the §2.7 firewall is untouched: the calendar file never names an `attention*`
role, so the lint's ban holds with no exemption. A dot IS state, and it gets its
fill from the file that owns state.

### New tokens (UI-RULES.md §6.10, added with this entry)

`Sizes.calendarCellHeight` 48, `calendarMarkerDot` 6, `calendarMarkerRow` 16,
`calendarHourGutter` 56, `calendarHourRow` 56. All are layout metrics, not
colours, so no contrast check applies.

**The cell is 48, not 44, and that is the §7 floor deciding it rather than the
layout.** 44 was drawn first and fits a six-week month more comfortably; it is
also 4dp under the minimum touch target, and a calendar cell is a *tap target*
in every view — it is how a date is selected. Six rows at 48 is 288dp plus the
day-of-week header, which a phone holds without scrolling, so the floor cost
nothing here. Had it cost something, the floor would still have won.

---

## "View B's schedule" modal + slot conflicts (2026-08-21)

A planner (A) picking a time for a target (B) can now see B's schedule live, and
cannot pick a slot B has already filled. `lib/features/scheduling/` (the modal and
slot logic) plus one new access mirror under `lib/features/groups/`.

### Two blockers found before any code was written

**A could not read B's schedule at all.** `firestore.rules` had
`allow read: if signedIn() && request.auth.uid == targetUid` on
`scheduleItems/{targetUid}/items/{itemId}`, and the collection-group rule allowed
only `resource.data.createdByUid == request.auth.uid`. So A saw *the items A had
created for B*, never B's schedule. The feature is impossible without a rules
change; it is not a UI problem.

**`callerHasActiveGrant()` could not be reused as-is.** The helper is exactly the
right predicate, but it takes a `groupId`, and a read of `scheduleItems/{B}/items`
carries none. Rules cannot query for "any group in which A holds a grant over B" —
the same wall the social layer hit, and the reason `social_ids.dart` exists.

### The access mirror — `plannerAccess/{plannerUid}_{targetUid}`

Existence *is* the permission. The id is computed from the two uids, so the rules
engine can construct it, which is the entire point:

```
allow read: if request.auth.uid == targetUid
         || exists(/databases/$(db)/documents/plannerAccess/
                   $(request.auth.uid + '_' + targetUid));
```

**It is a denormalization of `plannerGrants`, and that is the cost being paid
knowingly.** Grants are per-group; this mirror answers the different question
"does A hold *at least one* active grant over B, in any group". Nothing else can
answer that inside a rule.

**Only B writes it** — consent stays the target's, exactly as `plannerGrants`
does. A can read it and nothing else.

**It is maintained off the GRANT STREAM, never off the grant transitions.** Same
doctrine as reminders and profile stats, and here the argument is stronger than
in either: a transition-driven mirror that half-fails on revoke leaves A able to
read B's schedule after B revoked, which is a security staleness rather than a
missed notification. `PlannerAccessReconciler` watches B's own incoming grants
and makes the mirror set match — one rule, applied to whatever the stream
currently says, idempotent. **Adding a mirror write inside `setPlannerGrant()` is
a regression**, not a belt-and-braces improvement.

That choice also solves backfill for free: every grant that existed before this
feature gets its mirror the first time B opens the app, with no migration script.

**Stated limitation.** The mirror is client-maintained, so a revoke performed
while B is offline does not reach it until B is next online. B performs revokes
*in the app*, so in practice the write and the stream fire together — but the
window is real and cannot be closed without a Cloud Function.

### Conflicts: 30-minute buckets, and why not real intervals

`ScheduleItem` has **no duration field** — it carries an instant. Real interval
overlap needs `durationMinutes`, which is the goals-phase decision this file
already defers, and which would touch the model, the builder, the create-rules
whitelist and three card screens. So a slot is a **fixed 30-minute bucket**, used
for display, for blocking and for the lock id. The model is unchanged and the
goals decision is not pre-empted.

**Buckets are anchored to UTC, not to B's wall clock.**
`slotIndex = epochMs ~/ 1800000`. A wall-clock anchor is prettier and is wrong
twice a year: on a fall-back date the local 01:30 bucket happens twice and the
key is ambiguous, which is precisely the class of bug `tz_resolver.dart` exists
to prevent. UTC anchoring is total and monotone.

**The cost, stated:** in a zone whose offset is not a whole half-hour (Kathmandu
+05:45, Chatham +12:45), buckets begin at :15 and :45 local rather than :00 and
:30. Unambiguous beat tidy.

### Server-side re-validation — a lock document, because nothing else is available

The requirement is that a slot taken while A's modal is open must be **rejected at
write time**, not merely hidden. Two mechanisms do not exist here:

- **Cloud Functions.** There is no `functions/` directory, no functions block in
  `firebase.json`, and Blaze is unavailable (the same constraint that sent avatars
  to Supabase).
- **A rules-side query.** Rules cannot ask "does an overlapping item exist".

What is left is the pattern this repo already uses twice — `usernames/{handle}`
and `joinCodes/{code}` — a document whose id is computed and whose `create`
therefore fails if it already exists. `scheduleSlots/{targetUid}/slots/{slotIndex}`
is written in the **same `WriteBatch`** as the item, so the pair lands atomically:
if the slot was taken between open and submit, the batch fails and no item is
created. `allow update: if false` is what makes it a lock rather than an upsert —
Firestore treats `set` on an existing doc as an update, so the create branch only
ever sees a genuinely free slot.

**A lock is released when its item dies** — `withdraw()` and `reject()` delete it.
Without that a rejected plan would block B's slot forever. Release is best-effort
and deliberately *not* transactional with the status write: a lock that outlives
its item costs one falsely-blocked slot, while a status write that fails because a
lock delete failed would break the consent loop, which matters more.

**The items stream stays authoritative for what A SEES.** Locks are a race guard
only; the modal computes availability from B's live items. Two sources would
otherwise disagree, and the one the user is looking at should be the real one.

### The modal is not a route

`showTargetScheduleModal()`, a function, matching every other dialog and sheet in
this app (`showModalBottomSheet` in the calendar, `showDialog` in outcome and
activity). It is transient state inside the builder, not a location: a user who
rotated the phone or shared a link should not land in a modal over a form with no
target selected.

Backdrop is `BackdropFilter` at `Blurs.modalBackdrop`, over a scrim — the app had
no blurred surface before this, so both are new tokens (UI-RULES.md §6.11).

---

## Avatar crop/compress — static only (2026-08-23)

The avatar upload used to reject any file over the cap (2MB static / 5MB
animated) with no recourse — a normal camera JPEG blew past 2MB, so "too large"
was a dead end. `image_picker` was deliberately used WITHOUT `imageQuality` /
`maxWidth`, and the pubspec explicitly refused a crop/compress package, because
re-encoding an animated GIF or WebP flattens it to a single frame — the exact
thing the animated-avatar support exists to prevent.

**Decision: keep that rule, but scope it to the case where it actually bites —
animated formats — and crop+compress STATIC images.** The reason for "never
re-encode" is animation loss; a JPEG/PNG has no animation to lose. So:

- **Static (JPEG/PNG):** run `image_cropper` — a square crop-with-zoom UI that
  downscales (1024px cap) and compresses (JPEG q85). That both delivers the
  requested crop UX and brings a large photo under 2MB. Output is declared as
  `image/jpeg` because the crop re-encodes to JPEG.
- **Animated (GIF/WebP):** unchanged — read the bytes directly, never
  re-encode, and reject over 5MB with a message that explains it can't just be
  shrunk without killing the animation.

WebP is treated as animated-capable (the conservative side of
`kAnimatedCapableMimes`) because nothing cheap distinguishes a still WebP from an
animated one, and a wrong guess that re-encodes an animated WebP is the failure
we are avoiding.

Adds the `image_cropper` dependency and its `UCropActivity` in the Android
manifest. The Worker still sniffs bytes and re-checks size, so the client MIME
remains a hint, never a fact.

## Battery-exemption direct dialog — deliberate Play-policy declaration (2026-08-23)

**Decision: declare `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and use the DIRECT
system dialog** (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with a `package:`
URI), not the battery-optimization LIST intent.

The list intent (`ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`) needs no
permission but dumps the user into a screen of every app and asks them to hunt
for ours. The direct dialog is one tap — yes/no, for this app — and holding the
permission is what unlocks it.

**This is a deliberate Play-policy declaration, on record for submission.**
Google restricts `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to an acceptable-use
list, and *"the app schedules user-facing alarms/reminders and must run in the
background to deliver them"* is on it. We are a reminder/alarm app — the
qualifying case — and reliable delivery is the entire product (the OneKeyClean
finding proved a non-exempt process is killed with its alarms). It is the
Doze-exemption analogue of the `SCHEDULE_EXACT_ALARM` decision.

**Fallback if review ever objects:** the native `requestIgnoreBatteryOptimizations`
already falls through to the non-declared list intent when the direct action is
unavailable, so dropping the permission is a copy change in onboarding, not an
architecture change. The manifest carries the full reasoning inline.

## Permissions onboarding — first-run flow (2026-08-23)

**A single first-run flow that asks for every permission a reminder depends on,
explained, most-consequential first.** `lib/features/onboarding/`. Built after the
Part-3 plan was approved with all its open decisions settled. **NOT VERIFIED ON A
DEVICE** — the Redmi pass is the acceptance test.

**The doctrine it must not regress: no raw OS prompt fires before the user has
read why.** The reminder layer moved the POST_NOTIFICATIONS ask off cold launch
precisely because Android spends that prompt once and a launch-time surprise
wastes it. Onboarding keeps that: every step shows its reason ON SCREEN before its
button touches an OS surface, and the flow runs AFTER auth + profile completion,
never at splash. The existing primer card is untouched and stays the repair path
for the three delivery permissions.

**Per-permission mechanics** (the approved Part-3 table):
- **POST_NOTIFICATIONS** — the one runtime dialog. Denied → offer app
  notification settings (Android won't re-ask in-app).
- **SCHEDULE_EXACT_ALARM** / **USE_FULL_SCREEN_INTENT** — settings-only, so
  deep-linked to *this app's* toggle via the plugin's own request intents. On the
  APIs where they are install-granted the state reads granted and the step is
  skipped.
- **Battery/Doze** — the direct dialog (see the entry above).
- **OEM autostart** — no standard permission and no guaranteed public intent, so
  it is **resolve-checked** natively against a dontkillmyapp component map and
  **never blind-launched**; where nothing resolves (or the launch is refused) a
  per-OEM guided card gives the manual path. Autostart grant cannot be read back,
  so the step is offered whenever `Build.MANUFACTURER` is a known-aggressive OEM
  and completion is tracked by a stored flag instead.

**The pieces:**
- `core/platform/oem_profile.dart` — the PURE OEM branch selector
  (`oemProfileFor`), device-free so the "which OEMs need autostart" decision is
  unit-tested rather than only on hardware. Unknown/stock → skip the step.
- `core/platform/oem_info.dart` — `Build.MANUFACTURER` over `device_info_plus`.
- `core/platform/system_permissions.dart` — the battery + autostart channel seam
  (`time_app/battery`, `time_app/autostart`). **No method throws**; each degrades
  to a safe default, because a permission surface that can throw would take down
  the flow that drives it.
- `features/onboarding/application/onboarding_plan.dart` — `remainingSteps` /
  `hasOnboardingWork`, PURE, applied to the LIVE `ReminderPermissionState` so the
  flow is resumable and self-skipping (a granted step drops out on the next
  resume). Same doctrine as the reminder reconciler.
- `OnboardingGate` (inside `HomeGate`) shows the flow once per device; a completed
  device never even reads permission state. Re-runnable from the account menu at
  `/permissions`.

**Two native method channels on `MainActivity`** (thin-channel pattern, no
`permission_handler`): battery check+request, autostart resolve+launch. The
autostart component map lives native because resolving a `ComponentName` needs the
`PackageManager`.

**`ReminderPermissionState`/`ReminderPermissions` extended** with
`batteryUnrestricted` + `autostartLikelyNeeded` and `requestBatteryExemption()` /
`openAutostartSettings()`. **`isFullyReady` deliberately excludes battery/
autostart** — it drives the primer card, whose copy only covers the delivery
trio, so folding them in would show the primer with no branch to render. The two
new state fields default to the safe no-op values so the existing three-arg
constructor sites and the primer are unmoved. The scheduler/firing path was not
touched.

Coverage: `test/onboarding_test.dart` — the step plan (auto-skip granted,
consequence order, autostart-always-for-aggressive-OEM), the OEM branch selection
(families, case-insensitivity, stock/unknown skip), the state-field defaults, and
the never-throws channel seam.

## Cross-device relationship + planning denials (2026-08-24)

Two failures surfaced on the first real multi-device test (Nothing 4a +
Redmi, two accounts, both signed in). Both were diagnosed against the LIVE
backend, not by reasoning alone: the deployed ruleset
(`56e11d6d-6c1c-4dd8-ae16-9141defa7b62`) was re-fetched and diffed byte-for-byte
against `firestore.rules` (identical), the actual Firestore documents were read
with an admin token (rules bypassed), and both mechanisms were reproduced in the
rules emulator (`firestore-tests/repro_bugs.test.mjs`). Neither was an
undeployed-rule or offline-cache artifact — the reads reach the backend and are
genuinely denied there.

### Bug 1 — username search spins forever (fixed CLIENT-side)

**Not a Supabase issue and not the username read.** Username search is served by
Firestore (`usernames/{handle}`, `allow get: if signedIn()`); both live handles
resolve to real uids. The failure is downstream: after the uid resolves,
`profileVisibilityProvider` listens to `watchFriendship`, a single-doc
`.snapshots()` on `friendships/{sortedPairId(me,other)}`. For two strangers that
document does not exist, and the read rule (`request.auth.uid in
resource.data.participants`) dereferences `resource.data` on a **null** resource
→ `permission-denied`, not an empty snapshot. That error becomes an `AsyncError`,
and `_SearchResult` renders a spinner forever while `visibility.value == null`.
`watchRequest` and `watchBlockPair` have the same latent trap.

**Confirmed** on device (spinner) and in the emulator: reading a non-existent
`friendships/{pair}` is DENIED; a party reading an existing one succeeds.

**Fix is on the client, deliberately NOT the rules.** A rules-side `resource ==
null` allowance would let anyone probe whether two *other* users are
friends/blocked (the id is attacker-constructable), reopening exactly the
enumeration hole the social layer closes. Instead, `data/relation_stream.dart`
maps this one `permission-denied` to the benign "absent" value. This is sound
because these ids always name the caller: a document the caller could not read
cannot exist at this id, so a denial here can only mean absence. Any other error
is rethrown. Applied to `watchFriendship`, `watchRequest`
(`relationStreamAbsentOnDenied`) and `watchBlockPair` (`isAbsenceDenial` on each
listener's `onError`). Reactivity caveat: a Firestore listener terminates on
error, so once absent the stream ends after yielding the fallback; a relationship
formed mid-view is picked up on the next provider rebuild. The fuller fix
(derive isFriend/block/request from the caller-scoped `array-contains me` query
streams, which never deny) is deferred — the error-mapping is the minimal
change and the rules stay untouched.

### Bug 2 — planning cross-device is permission-denied (fixed RULES + schema)

The rules were already correctly split (item ↔ `plannerGrants`, mirror ↔
`plannerAccess`). The failure is one layer out: `ScheduleRepository.createItem`
commits ONE atomic `WriteBatch` of the item AND a `scheduleSlots` lock. The item
write passes (`callerHasActiveGrant` — the test group had `granted:true` both
ways), but the lock's create rule required `callerHasPlannerAccess(target)` =
`exists(plannerAccess/{planner}_{target})`, and **`plannerAccess` was empty
project-wide**. The lock was denied and, being atomic, took the item with it.
Backend proof: the mirror collection had zero docs while a live grant existed;
the emulator named the failing statement (`evaluation error at L896 for
'create'`). The mirror is written ONLY by the target's device
(`PlannerAccessReconciler`, off the grant stream), which has never run on the
installed build — so the planner was structurally unable to create the document
its own write depended on. A `plannerAccess` mirror is the right gate for the
READ path (the "view B's schedule" modal, which carries no groupId) but the wrong
one for a WRITE that already travels beside the item.

**Fix: decouple the lock write from the mirror.** The `scheduleSlots` lock now
carries `groupId` (added to `createItem`'s batch — the only place a lock is
created), and its create rule gates on `callerHasActiveGrant(targetUid,
groupId)` — the identical check the item proves in the same batch — instead of
`callerHasPlannerAccess`. This is strictly stronger (a real active grant vs. a
mirror that can outlive a revocation), keeps consent target-controlled (the grant
is), and unblocks planning regardless of whether the target's device has synced
the mirror. The lock READ rule stays on `callerHasPlannerAccess` — a read carries
no groupId, so the mirror remains its gate. `allow update: if false` is
unchanged, so the doc is still a create-once lock.

**Follow-ups, NOT done here:** (a) the `plannerAccess` mirror is still empty, so
the "view B's schedule" modal read remains broken until
`PlannerAccessReconciler` is verified to populate it on the installed build — a
separate device check. (b) `repro_bugs.test.mjs` and the updated
`slots.test.mjs` now assert the fixed contract (grant + no mirror → batch
succeeds; mirror alone → denied); full suite 124/124 green.

**Deploy order — RULES FIRST.** `firestore.rules` changed (the lock create
whitelist gained `groupId` and the gate swapped). An old client (lock without
`groupId`) planning as a planner will now be denied its lock — acceptable, since
the old client is exactly the one that was already failing; the new client always
sends `groupId`. Self-planning is unaffected (the `request.auth.uid == targetUid`
branch short-circuits before `groupId` is read). Deploy, re-fetch the deployed
source and diff, then install the new client.

## Friend-request reactivity + lifecycle (2026-08-24)

Three issues on the friend-request flow, all reproduced against the LIVE rules
(the emulator runs the same `firestore.rules`; the device already showed the
Firestore `permission-denied`, so these are real backend denials, not offline
cache). All found right after the cross-device relationship fix above.

### Issues 1 & 2 — button never leaves "Add friend"; a second tap is denied

Root cause is a side-effect of the Bug 1 fix. The profile button already
switches on `ProfileVisibility.relation`, but the outgoing-request state feeding
it came from `watchRequest`, a single-doc `.snapshots()` listener. Via
`relationStreamAbsentOnDenied` that listener yields "absent" and then TERMINATES
on the initial non-existent-doc denial (a Firestore listener ends on error), so
it never observes the request created afterwards. The button stays "Add friend"
(Issue 1); a second tap re-runs `sendRequest`, whose `.set()` on the now-existing
pending doc is an UPDATE that changes `createdAt`, which the update rule forbids
→ `permission-denied` (Issue 2, emulator-confirmed).

**Fix — derive per-user relationship state from the caller-scoped QUERY
streams**, not per-pair doc listeners. `isFriendProvider`,
`outgoingRequestToProvider` and `incomingRequestFromProvider` now read from
`myFriendUidsProvider` / `outgoingRequestsProvider` / `incomingRequestsProvider`
(the `array-contains me` / `fromUid==me` / `toUid==me` queries). A query never
hits the non-existent-doc denial and stays live, so the button flips to
"Requested" the instant the write lands — which also makes the duplicate write
structurally impossible. Rules unchanged. `blockPairProvider` was left on the
doc-read path (its `iBlocked` half has the same latent staleness, but blocks are
not part of this flow — a follow-up if it ever surfaces).

### Issue 3 — re-add after a decline is denied (lifecycle)

A declined request persisted as `status:'rejected'`, and `sendRequest`'s `.set()`
is an UPDATE on that existing doc, which no update branch permits
(`rejected → pending` is forbidden by design). So the re-add collided with the
stale row → `permission-denied` (emulator-confirmed). The same latent flaw hit
withdraw-then-re-add (`cancelled`) and unfriend-then-re-friend (`accepted`); the
overflow's "either of you can send a new request later" was not actually true.

**Decision (reverses the earlier "a rejected row is never revived"): a settled
request is DELETED, not flagged.** `rejectRequest` (decline) and `cancelRequest`
(withdraw) now delete the doc; `removeFriend` also clears the leftover `accepted`
row in both directions; and `sendRequest` self-heals any pre-existing stale row
(on a `permission-denied`, delete then re-create) so no migration is needed for
rows written before this change. Re-adding is then a clean create. Rule change:
`friendRequests` `allow delete: if signedIn() && isParty()` (was `if false`).

**Why this keeps consent intact:** deleting a request grants nothing and reveals
nothing, so the model is unchanged — only the lifecycle is. A block is still
enforced because the re-created request re-checks `blocked()` on create. The
cost, accepted: the persisted "no" is gone, so re-requests are unlimited;
blocking, not a permanent rejected row, is the throttle (rate-limiting has no
home without Blaze anyway). Declines are now also indistinguishable from
never-sent, which matches the app's block-indistinguishability stance.

### UI — explicit tick/cross for accept/decline

`AppIcons.acceptFriend` → `Icons.check_rounded` (✓) and `declineFriend` →
`Icons.close_rounded` (✗). The old `how_to_reg` / `person_off` glyphs did not
read as actionable accept/decline controls. `declineFriend` is also the withdraw
glyph (clearing a pending request, either direction), for which a cross reads
correctly. This is an icon-vocabulary change (the one place raw `Icons.*` is
allowed); the §2.7 firewall lint stays green.

### Coverage / deploy

`social.test.mjs` now asserts the delete contract (either party may delete; a
third party may not; re-add after delete succeeds); full suite 127/127. Only
`firestore.rules` changed (the `friendRequests` delete rule), so
`firebase deploy --only firestore:rules`; re-fetch the deployed source and diff,
then reinstall the client (all three fixes need the new client). Device: the
re-add is issued by the SENDER, so the decline-then-re-add case reproduces on the
sender's phone (the Nothing).

## Friend-request push + mandatory username (2026-08-24)

Two gaps found testing on a third device (Motorola Edge 70). Both confirmed
against the live backend before any change: the friend-request docs and FCM
tokens were read directly from Firestore (admin token, rules bypassed).

### Friend-request push — was NEVER built (not a delivery failure)

Traced the whole path: no `functions/` dir, the Worker's events were
`{created, decided, outcome, withdrawn}` (schedule items only), and nothing in
`lib/` POSTed to the notifier on a `friendRequests` write. FCM tokens WERE
present for all three active devices (Motorola/Nothing/Redmi), so delivery was
never the problem — there was simply no trigger. This matches the social-layer
"NOT DONE" note ("push for friend events … does not fit one"). Directed to build
it now, both directions.

**Design — two events on the SAME Worker, a separate family from item events.**
`friendRequest` (sender → recipient) and `friendAccept` (accepter → original
sender). Body is `{event, fromUid, toUid}` (no itemId); `FRIEND_EVENTS` is a
distinct set and `notify.js` gains `sendFriendNotification` / `buildFriendMessage`
beside the untouched item policy. The item path in `index.js` is left
byte-identical — friend events are dispatched to a new `handleFriendEvent` right
after JSON parse, before the item body validation.

Things that make it safe rather than an abuse vector:
- **The actor triggers, and only for a relationship that exists.**
  `friendRequest` requires the caller to be `fromUid` AND a `pending`
  `friendRequests/{fromUid}_{toUid}` to exist; `friendAccept` requires the caller
  to be `toUid` AND the `friendships/{sortedPair}` to exist. No request/friendship
  → 403/404, no push. So a caller cannot spray friend pushes at arbitrary users.
- **The actor's display name is read server-side** (`users/{actorUid}.name`),
  never taken from the client, so the push body cannot be spoofed.
- **No dedup slot, deliberately.** The request row is deleted on decline/withdraw
  (the lifecycle fix above), so a re-request is a genuinely new event; a rare
  double-fire from `sendRequest`'s self-heal retry is harmless. (Contrast the item
  events, which carry `notified*` guards because their docs persist.)
- **No rules change.** The Worker reads via its service account; the client only
  POSTs. Client seam mirrors the item notifier exactly: `FriendEventNotifier` +
  `HttpFriendEventNotifier`, best-effort, no retry, ID token identifies the actor.
  Tap routing: `friendRequest` → Friend requests, `friendAccept` → Friends list
  (`notification_routing.dart`).

**Deploy:** the WORKER must be redeployed (`wrangler deploy` in `worker/`); no
Firestore rules changed. Then reinstall the client.

### Mandatory username at onboarding

`UserProfile.isComplete` deliberately required only name + timezone, so an account
could exist with no handle — and a handle-less account is invisible to search, so
it can send requests but can never be added back (a dead end; hit on the
Motorola). Directed to make usernames mandatory.

- `isComplete` now also requires `username`. **Effect (chosen, not incidental):**
  existing handle-less accounts are routed through `CompleteProfileScreen` once to
  set a handle — the intended "no account without a handle", grandfathering
  nobody.
- `CompleteProfileScreen` gains a required username field with **live format
  validation** (`validateUsername` → `describeUsernameProblem`) and the
  constraints stated in plain text (3–20 chars, lowercase letters/numbers/
  underscore, start with a letter, unique). Save does `createProfile` THEN
  `claim`: the claim is a second write that can lose a uniqueness race, and doing
  it after means a taken handle leaves a still-`!isComplete` profile (the gate
  keeps the user on the screen to pick another) rather than a half-account.
  Uniqueness is decided atomically by `claim`, which surfaces "taken" via
  `UsernameUnavailable`.

No Firestore rules change (the `usernames`/`users` rules already enforce claim +
mirror). Full existing suites stay green (Dart analyze clean; flutter social/lint
tests 51/51; the 127 rules tests are unaffected).

## Stats capture foundation — Step 1: `decidedAt` parsed into the item (2026-08-25)

**Context.** Starting the stats-feature *data-capture foundation* while the stats
page/computation, voice layer and UI redesign stay parked. The one piece that is
irreversible if deferred is response-latency history: `decidedAt - createdAt`
cannot be reconstructed for any plan decided before the field is captured.

**Finding: the write side was already live.** `schedule_repository.dart` already
stamps `decidedAt = serverTimestamp()` on `approve()`, on `reject()`, and on a
self-authored `approved` `createItem()`. `firestore.rules` already whitelists it
on item create (the optional key set) and on the target-decision update
(`changedKeys().hasOnly(['status','decidedAt','rejectionReason','outcome','updatedAt'])`).
So the server accepts and persists it — **no offline-lie risk**, verified by
reading the deployed-shape rules, not just the client.

**The only gap, now closed.** `ScheduleItem.fromDoc` never parsed `decidedAt`, so
it was written but invisible to Dart. Added `DateTime? decidedAt` to the domain
object + `fromDoc`. Additive, no migration, no rules change.

**Semantics locked (so future stats read it correctly):**
- `decidedAt` = when the TARGET decided (approve/reject), or when a self-authored
  item was created already-approved (parity, stamped at create).
- It is **null on planner-withdrawn items** — a withdrawal is not a target
  decision. Withdraw carries `withdrawnAt` instead. This matches the locked rate-
  stat rule: rate stats count DECIDED plans only (approved+rejected); pending and
  withdrawn are each their own separate count, never folded into a decision rate.
- Old plans decided before this ship simply have no `decidedAt`; response-latency
  stats must treat missing `decidedAt` as "unknown", never as zero latency.

## Stats capture foundation — Step 2: tracked-time model + rules (2026-08-25)

**Personal manual time-tracking — a genuinely SEPARATE feature.** Its own tree,
its own domain, never coupled to a plan except via one optional soft link. No
existing rule, collection or index changed; purely additive, so rules-then-code
is safe and an old client is unaffected.

**Location.** `users/{uid}/trackedTime/{entryId}` (auto-id), a subcollection with
its own `match` block — the `fcmTokens`/`state` pattern. **Owner-only in BOTH
directions** (`request.auth.uid == uid`): unlike `profileStats`, reads are NOT
opened to friends or the public. Nobody but the owner ever reads or writes their
tracked time.

**Schema (one entry):**
- `taskName` string, free-form, trimmed non-empty, ≤ 200. The task need not
  correspond to any plan/alarm.
- `durationMinutes` **int, 1..1440**. The authoritative unit — always whole
  minutes, never fractional hours; display rolls to `Xh Ym` past 59.
- `logDate` string `YYYY-MM-DD`, a **wall date in the owner's home tz** at
  creation. Lexical order = chronological, so today/this-week/streak reads are
  plain string ranges with **no timezone math at read time**. Every entry belongs
  to exactly ONE day. (No `timezone` field: `logDate` is already the resolved
  answer.)
- `startLocal`/`endLocal` optional `HH:mm`, both-or-neither. **Display metadata
  only** — duration is authoritative and need not agree with the range; the range
  is never used to derive duration.
- `sourceItemId` optional string — the soft link to the plan a Done-hook entry
  came from. **Recorded, never verified** against the plan tree (a `get()` there
  would re-couple the two features; a malformed value only mislabels the owner's
  own row). Its presence/absence is what a future "share of tracked time that came
  from plans" stat reads.
- `createdAt`/`updatedAt` server timestamps.

**The 1440 cap is derived, not arbitrary.** Because every entry is one day, one
entry can never hold more than a day. Enforced on BOTH sides — `firestore.rules`
`trackedTime.validEntry` and `TrackedEntry`'s own assert + `kMaxEntryMinutes`.
This keeps every day-bucketed stat coherent: no query can ever see "more than 24h
in a day".

**Multi-day logging = ONE ENTRY PER DAY, never a spanning row.** A log that
transcends a day is not stored as one oversized entry and introduces no
date-range shape. Instead the client apportions the minutes across the chosen
days and writes N single-day entries in one batch (`logAcrossDays`), each ≤ 1440.
So no stat query ever has to understand spans, and there is nothing to migrate.
- **Implemented now (not stubbed):** the pure `apportionAcrossDays(total, dates)`
  helper (even split, remainder spread one minute at a time, re-sums exactly,
  throws `ApportionmentImpossible` when the total cannot fit the chosen days) and
  the batch writer `TrackedTimeRepository.logAcrossDays`. Both are the data-side
  seam and are unit-tested.
- **Stubbed / deferred:** the actual multi-day PROMPT UI (pick the days, adjust
  the apportionment). It is UI, out of scope this session, and the pure helper is
  the clean seam it will drive. The data model already assumes one-entry-per-day,
  so building the prompt later needs no schema change.

**Rules validation** (mirrors the model): full `keys().hasOnly` set on create AND
update, `taskName` 1..200, `durationMinutes` int 1..1440, `logDate` a 10-char
string, `sourceItemId` any string when present, range both-or-neither. `delete`
owner-only — users have the full right to delete their own entries anytime.

**Files:** `lib/features/time_tracking/domain/tracked_entry.dart`,
`data/tracked_time_repository.dart`, `application/time_tracking_providers.dart`;
rules block in `firestore.rules`; `firestore-tests/tracked_time.test.mjs` (12
tests) and `test/tracked_entry_test.dart` (10 tests).

**Green:** `flutter analyze` clean; the 12 new rules tests pass inside the full
suite (139/139); the 10 Dart unit tests pass. **Rules NOT deployed yet** — deploy
is a separate, user-run step; no tracked entry has hit the real backend.

## Stats capture foundation — Step 3: the Done→track hook (2026-08-25)

**When a user marks a planned item Done, offer to log it to personal time
tracking.** The capture side of the "% of tracked time that came from plans"
stat, and the first bridge between planning and the (otherwise separate) tracker
— a bridge that runs in ONE direction only, via the optional `sourceItemId`.

**Where it fires.** `_OutcomeCard._markDone` (`outcome_screen.dart`), right after
the `markDone` write. Reordered deliberately: the old `if (_isSelfPlanned) return`
short-circuited before the notify — now it guards ONLY the planner push, because
a self-planned item is exactly the kind a user logs their own time against. The
prompt therefore runs for EVERY completed item (self- and other-planned alike),
which is correct: the stat counts any plan you completed, including ones others
made for you.

**The UI is one dialog, not a screen** (`promptLogFromDone` in
`time_tracking/presentation/log_from_done_prompt.dart`): "Log this to time
tracking?" + the task name + a "Minutes spent" field + Not now / Log. Confirm and
duration are combined on purpose — the smaller surface, and the prefillable field
IS the voice seam. A plan has no duration of its own, so the duration must be
asked; typed for now.

**The voice seam.** Duration is a single prefillable field: a future "track time"
voice flow parses the spoken minutes and passes them as `initialMinutes`; the
same dialog then needs only a confirming tap. Nothing on the write path changes.

**Feature separation preserved.** The prompt takes only primitives — `taskName`,
`sourceItemId`, `timezone` — so `time_tracking` never imports the scheduling
domain. `outcome_screen` (scheduling side) imports the prompt, not the reverse.

**One Done → one day → one entry.** The completion is "now", so `logDate` is
today in the user's own zone (`logDateFor`), and a single `TrackedTimeRepository.log`
writes one entry with `sourceItemId` set. The `apportionAcrossDays`/`logAcrossDays`
multi-day path never applies here and is not invoked. Manual/voice entries (later)
leave `sourceItemId` absent.

**Dedup seam exists, not wired.** `TrackedTimeRepository.hasEntryForItem` can
guard a double-log, but marking Done twice is not reachable from this screen (the
Done control disappears once an outcome exists), so it is left for a caller that
needs it.

**Scope:** logic + the single confirm/duration dialog only. No stats page, no
stats computation, no voice, no redesign. `flutter analyze` clean; UI-RULES lint
green. NOT verified on a device.

## Stats capture foundation — rules deploy verified (2026-08-25)

The Step 2 `trackedTime` rules are now DEPLOYED and byte-verified. Live ruleset
`d31d2f84-83bf-4fc6-a85e-e45ec03614bf` (release `cloud.firestore`, updateTime
2026-08-25T09:49:49Z), superseding `33468095-920e-4b5d-a8ae-e1e3b611e4b1` and
every earlier id. Verified the real way: the deployed source was fetched back
from `firebaserules.googleapis.com` and diffed byte-for-byte against
`firestore.rules` — IDENTICAL (53412 bytes each, sha256
`89354ee89b9e9d710e551d9f05e00a326a1e06bf493da5eb0e21118eff7222dd`), with no
trailing-newline drift this round. So tracked-time reads/writes now actually
reach and are enforced by the backend — no offline-lie path. Still nothing
written to the real collection from a device.

## UI redesign — Hearth spine + Candidate A IA (design locked 2026-08-25)

A three-session design pass (IA audit → target IA → visual direction → migration
plan) settled the app's next-phase structure and look. **Design and decisions
only across those sessions; step zero below is the first code.**

### Information architecture — Candidate A (product-pillar bar)

The bar is regrouped from the three delegation stances to the app's **pillars**:

```
[ Plan ]   [ Track ]   ( ⊕ voice )   [ Stats ]   [ You ]
```

- **Plan** — the delegation hub. The three stances (My Schedule / Activity /
  Groups) become a **swipeable, keep-alive inner TabBar**, landing on My
  Schedule. Calendar = a Plan app-bar action; **Archived = Plan overflow** (it is
  settled *plan* content — keeps You as pure identity/account). Approvals inbox
  stays a My Schedule action.
- **Track** — time-tracking's first real home: free-form log + history with
  edit/delete, on the existing `TrackedTimeRepository`. No longer subordinate to
  planning.
- **Stats** — a personal dashboard, distinct from the social-profile stats on
  `/u/:uid`.
- **You** — profile, Friends, Language practice, Reminders & permissions, Sign
  out, Dev(debug). Dissolves the account-popup "junk drawer".
- **Voice FAB** — persistent docked centre mic spanning both features: Track time
  → Track log sheet; Plan time → schedule-builder. Every voice action is also
  doable manually.

**Regressions accepted with eyes open:** Groups 0→1 tap (it is setup/admin, not
the daily return view); the pending badge moves to Plan-aggregate + the My
Schedule sub-tab; stance-switching becomes a swipe. Landing = My Schedule (the
"what do I need to do" view), not Groups.

**Candidates B (keep 3 stance-tabs + a "Me" hub) and C (unified People + role
toggle) were rejected:** B kept tracking/stats a tab-level below planning; C
re-mixed groups with the friend graph, which the data model keeps apart.

### Visual direction — Hearth

Chosen over **Momentum** (energetic/gamified — fights the app's "caring, not
coercive" identity, costliest AA re-verify) and **Graphite** (precise mono tool —
sheds the warm identity; its tabular numerals collide with the localized-digit
rule). **Hearth** is the warm humanist companion: ivory + sage (action) +
terracotta (attention), flat/hairlines, airy, humanist — an *evolution* of the
existing, already-AA-verified system, so the contrast work is not reopened. Stats
and Track may feel celebratory (number-heroes, quick-add chips) **within** the
warm palette. It is the single source of truth in `lib/core/theme/` + UI-RULES.md
that every migrated screen pulls from.

### Migration plan — temporary-door strategy, no big-bang

New pillars are built **behind the existing account popup** as a temporary door;
the old 3-tab bar stays intact and shippable until ONE reviewable cutover.

- **S0 — step zero: Hearth tokens + UI-RULES** (this slice; additive, nothing
  renders differently).
- **S1 — Track screen**, **S2 — Stats shell**, **S3 — You hub** — each a new
  route reachable from the popup; mutually independent; depend only on S0.
- **S4 — Plan inner-TabBar keep-alive shell** — the one structural nav change,
  reviewed **in isolation**.
- **S5 — bottom-bar cutover + voice FAB (manual routing)** — the integration
  gate; needs S1–S4 to exist. **S4 and S5 are two separate reviewable slices,
  released together** (option a) so users never see a transitional bar.
- **S6 — voice STT layer**; **S7 — Hearth polish sweep** (any time after S0).

**S2 caveat:** the actual stat computations (rejection rate, follow-through,
tracking totals) are a separate, **ungreenlit** build. S2 ships the dashboard
shell; tiles render placeholder/empty until fed — honestly, never faked zeros.

### Step zero — what actually landed (2026-08-25)

Additive and centralizing; **nothing renders differently** (the new token is
unused, the rest is doctrine):

- **`lib/core/theme/dataviz_tokens.dart` (NEW)** — `AppDataVizColors`, the one
  source every chart/meter pulls from. **No new hex**: every role maps onto an
  already-verified scheme colour (sage series/fill, terracotta attention as
  **line/marker only**, neutral grid/track). Deliberately **no orange-fill
  getter** — one would spend the §2.7 "waiting on you" signal on decoration AND
  launder the banned `tertiaryContainer` past the §2.7 lint. Used by nothing yet.
- **UI-RULES.md** — new **§2.8 Data-viz colour** (charts are not an exception to
  the two hues; the §2.7 firewall extends onto charts) and **§6.12–§6.14** (the
  product-pillar bar + docked voice FAB; the Track log sheet; the Stats
  dashboard). §6.14 composes the *existing* §6.7 progress and §6.9 stat tiles —
  it invents nothing.
- **`app_text.dart`** — doc-only: `displaySmall` now names the Stats number-hero
  as a **sanctioned third use** (alongside the auth hero and the My Schedule
  band), so UI-RULES §6.14 and the token agree. No value changed.

Per UI-RULES §9 (doctrine → document → code), the reasoning is here first, the
document (UI-RULES) second, and the code conforms. `flutter analyze` clean; the
UI-RULES lint stays green (the new theme file is outside the governed set; no
screen changed).

## UI redesign — S1: the Track pillar (2026-08-25)

The first migration slice, and the first real consumer of the S0 Hearth
foundation. Personal time-tracking gets a real home — no longer a dialog
subordinate to planning.

**What landed**
- **`track_screen.dart`** (`/track`): the history list, entries grouped by
  `logDate` into day sections (SectionHeader), each a flat outlined Card. Tap →
  edit; swipe → delete with an Undo snackbar. Reads `myTrackedEntriesProvider`
  (repo sorts `logDate` desc). Empty state: "log time you spent on anything — it
  need not be a plan."
- **`log_time_sheet.dart`** — the canonical §6.13 sheet (`showLogTimeSheet`),
  create OR edit. Task name + minutes (digits-only, 1..1440), sage quick-add
  chips that SET the field (never submit), optional both-or-neither time-of-day
  range. Manual entries carry **no `sourceItemId`**. Writes via the existing
  `TrackedTimeRepository`; edit preserves `logDate`, `createdAt` and provenance.
- **Temporary door:** an account-popup item "Track time" → `Routes.track`
  (top-level pushed). No bottom-bar change. Removed at the S5 cutover.

**Foundation validation (S1's second job).** Two gaps the first consumer found,
both fixed centrally rather than worked around:
1. **No shared duration formatter.** `log_from_done_prompt` had a private
   Latin-digit `_formatMinutes`, violating the worldwide-digit rule. Added
   `formatDurationMinutes(context, minutes)` to the ONE format helper
   (`datetime_format.dart`, §1) — localized digits, the "Xh Ym past 59" unit
   rule in one place — and refactored the Done prompt onto it. One source now.
2. **No Track icon vocabulary.** Added `track`/`trackSelected` (the filled form
   awaits the S5 bar slot), `logTime`, `duration`, `edit`, `delete`,
   `emptyTrack` to `app_icons.dart` (§6.6). The §6.9/§6.7 recipes already
   existed and needed nothing.

Otherwise the S0 tokens/recipes held: §6.13 (quick-add chips sage, minutes
primary), §6.1 card, SectionHeader, AsyncView all applied with no new token.

**Multi-day apportion untouched** — single manual entries never trigger it; the
`apportionAcrossDays`/`logAcrossDays` helpers are as-is for the future multi-day
prompt.

**Green:** `flutter analyze` clean; UI-RULES lint + tracked-entry tests pass;
**`flutter build apk --debug` succeeds** (device-buildable). Not yet run on a
device. Scope held: no Plan shell, no bar change.

## UI redesign — S3: the You hub (2026-08-25)

Resolves the audit's most overloaded surface: the account popup that jumbled
feature launchers, account settings and device config behind one closed menu.

**What landed**
- **`you_screen.dart`** (`/you`): a profile header card (AvatarImage + name +
  @username → Edit profile), then two SectionHeader groups — **Places** (Friends
  with the pending-count badge · Calendar · Language practice) and **Account &
  device** (Reminders & permissions · Dev menu [debug] · Sign out). Each row is a
  flat outlined `_YouTile` (§6.1) with a leading icon and a chevron.
- **A re-housing, not a rebuild.** Every row pushes exactly the route the popup
  pushes today; no destination screen changed (their Hearth polish is S7). Sign
  out still goes through `signOutWithTokenCleanup(ref)`.
- **Temporary door:** account-popup → "You" → `/you`. The existing popup items
  stay wired (they still route) until the S5 cutover retires the popup.

**Flagged discrepancy (deliberate).** The S3 brief houses **Calendar** in You;
the locked IA has it as a Plan app-bar action. The Plan shell does not exist
until S4, so Calendar lives in You for now and relocates at S4/S5. Recorded so it
is not lost.

**Foundation validation (second consumer).** The S0 recipes held — §6.1 card,
SectionHeader, AvatarImage (§6.8), PendingCountBadge (§2.7) all applied with no
new token. Only additions were icon-vocabulary entries (`languagePractice`,
`editProfile`, `devMenu`) in `app_icons.dart` (§6.6) — the same central-fix
pattern as S1, not a workaround. One API nit: this Riverpod exposes `.value`,
not `.valueOrNull`, on `AsyncValue` (noted for later slices).

**Green:** `flutter analyze` clean; UI-RULES lint passes; `flutter build apk
--debug` succeeds (device-buildable).

## UI redesign — S4: the Plan inner-TabBar keep-alive shell (2026-08-25)

The one **structural** nav change of the migration, isolated in its own slice.
It collapses the three old delegation-stance bottom-bar tabs (My Schedule /
Activity / Groups) into ONE **Plan** branch with a swipeable, keep-alive inner
TabBar, landing on My Schedule. **S4 is NOT the bar cutover (S5):** the old
three-tab bar is untouched and shippable, and the shell is reachable only behind
a temporary account-popup door so it can be reviewed in isolation. S4 and S5
release together (option a) but are built and reviewed separately.

**What landed**
- **`plan_shell.dart` (`PlanShell`)** — a `Scaffold` with one `AppBar(title:
  "Plan")` whose `bottom` is a `TabBar` (My Schedule · Activity · Groups,
  `initialIndex 0`), body a swipeable `TabBarView`. The §6.12 look comes from the
  new central `tabBarTheme` (below), not inline styling.
- **Route `/plan`** (`Routes.plan`), top-level and pushed, with three
  **sub-routes** — `schedule-builder`, `approvals`, `groups/:groupId` — so each
  sub-tab's detail push stacks over the shell and Back returns to it. This is the
  documented `/calendar/new` precedent (a root-pushed screen whose create flow
  must not escape into a shell branch); they are second registrations, and since
  nothing deep-links to them the D2 ambiguity does not apply.
- **Temporary door:** account-popup → "Plan (preview)" → `/plan`. Same strategy
  as S1/S3; removed at S5.

**The keep-alive property — how the old `StatefulShellBranch` behaviour is
reproduced.** The property to preserve is that switching sub-tabs drops neither
live Firestore listeners nor scroll/selection. Two INDEPENDENT mechanisms, which
is what lets a swipeable `TabBarView` replace the old always-built `IndexedStack`
at no cost:
1. **Widget-state survival** — each page is wrapped in a `_KeepAlivePage`
   (`AutomaticKeepAliveClientMixin`, `wantKeepAlive => true`), so the
   `TabBarView`'s `PageView` keeps each page's element subtree mounted once built
   rather than disposing it off-screen. Scroll offsets and local state (e.g.
   `OutcomeScreen`'s highlight timer) survive a swipe.
2. **Listener liveness is independent of mounting** — the three feeds are
   non-`autoDispose` Riverpod providers, so their Firestore subscriptions stay
   live regardless of any widget. A `TabBarView` builds a page lazily on first
   visit; immaterial, because liveness never depended on the mount. The
   keep-alive is purely for widget state.

**Sub-tab reuse without touching the old bar.** Each of the three screens gained
one `embedded` bool (default **false** = byte-identical old-bar behaviour): when
true, its own `appBar` and `floatingActionButton` are `null` and the shell
provides them. The two Groups dialogs were lifted to top-level
`showGroupCreateDialog` / `showGroupJoinDialog` so the shell's app-bar actions
reuse the exact flows. Group-row taps push `/plan/groups/:id` when embedded,
`/groups/:id` otherwise.

**Per-sub-tab app-bar actions** (swapped by `_tabController.index`): My Schedule
→ approvals inbox; Activity → **`＋ Plan`** (the old standalone FAB, now an
app-bar action — the single-FAB rule is reserved for the S5 voice FAB, so no
competing FAB was added); Groups → `＋ New group` + `Join by code`. Constant Plan
actions: **Calendar** (a Plan app-bar action per the locked IA) and an overflow
`⋮` housing **Archived** (the locked "Archived lives in Plan" call).

**Approvals badge migration + the aggregate.** New `planAttentionCountProvider`
is a **documented sum** of the per-sub-tab attention signals. Today only My
Schedule contributes one (items where the user is target and `status ==
pending`); Activity and Groups add 0, so the aggregate currently *equals* the old
My-Schedule count — kept as a sum so a future signal is a one-line add. It rides
the **My Schedule sub-tab** badge now and will ride the **Plan bottom-bar
pillar** at S5, from the SAME provider so the two can never disagree. Per the
accepted regression, the count is no longer a bar-level tab badge.

**Central fix (flag-not-workaround, per S1/S3).** §6.12's Plan TabBar had no
recipe token: added a central **`tabBarTheme`** (`TabBarThemeData`) to
`app_theme.dart` — soft sage (`primary`) underline hugging the label
(`indicatorSize: label`), understated `labelLarge` text tabs, inactive in
`onSurfaceVariant`, `outlineVariant` divider, no fill. Every future TabBar now
inherits Hearth by default, the same discipline as `navigationBarTheme`.

**Deferred to S5 (correctly out of scope):** the bottom-bar rewire, the voice
FAB, and reminder-highlight routing into the new shell (a tapped reminder still
lands on the old `/outcome` branch, so `highlightItemId` is null when embedded).

**Green:** `flutter analyze` clean; UI-RULES lint + tests pass; `flutter build
apk --debug` succeeds (device-buildable). **NOT run on a device** — added to the
pre-S5 ledger below.

## UI redesign — S5: bottom-bar cutover + voice FAB (2026-08-25)

The **one irreversible, user-facing flip**. The three delegation-stance bottom
tabs become five product pillars — `[ Plan · Track · ⊕voice · Stats · You ]` —
with the docked centre voice FAB. Built and reviewed as its own slice but
**released together with S4** (option a), so users never see a transitional bar.
The temporary account-popup doors are retired here.

**Route tree — 3 stance branches → 4 pillar branches.** `StatefulShellRoute
.indexedStack` now has branches Plan / Track / Stats / You (the ⊕ voice FAB is
NOT a branch — a docked FAB on `HomeShell`). The Plan branch hosts the S4
`PlanShell` (its 3 sub-tabs are a `TabController`, not routes) with sub-routes
`schedule-builder`, `approvals`, `groups/:groupId`. `/track`, `/you`, `/plan`
stop being top-level *pushed* routes (S1/S3/S4 temp state) and BECOME branches;
`/stats` is new. `/` redirects to `/plan` (was `/groups`). Everything outside the
shell is unchanged (`/profile /archived /calendar /friends /u/:uid /chatbot /dev
/alarm /permissions`).

**Stranding audit — every old-path reference migrated, all internal (no external
deep links; manifest is MAIN/LAUNCHER only).** The `Routes` constants were
repointed so no caller was left dangling: `approvals`→`/plan/approvals`,
`scheduleBuilder`→`/plan/schedule-builder`; `plannerActivity`/`outcome`/`groups`
removed and replaced with `planActivity` (`/plan?tab=activity`) and
`planForItem(id)` (`/plan?item=`). Call sites updated: `notification_routing`
(created/withdrawn→approvals, decided/outcome→planActivity), `alarm_screen`
Dismiss (→`/plan` or `/plan?item=`), `calendar_item_sheet` (approvals /
planForItem / planActivity), `dev_menu` (5 links → Plan equivalents). A **re-grep
proved zero live references to `/groups|/outcome|/activity`** remain (only two
historical doc comments). A latent strander — the dead non-embedded
`/groups/:id` literal in `GroupsScreen` — was removed (the row tap is now always
the Plan sub-route).

**The headline path — reminder highlight into a KEPT-ALIVE shell.** `/plan?item=
<id>` → the Plan branch builder reads the query param → `PlanShell(highlightItemId,
initialTab)`. On a param change while the shell is already mounted (branch root
rebuilds with fresh params, `initState` does not re-run, sub-tabs kept alive),
`PlanShell.didUpdateWidget` steers the `TabController` to My Schedule and forwards
`highlightItemId` down; the embedded `OutcomeScreen`'s own `didUpdateWidget`
re-scrolls and re-outlines. **This is the top item on the S5 device pass.**

**The five-pillar bar (§6.12).** `HomeShell` replaced its `NavigationBar` with a
`BottomAppBar` (`CircularNotchedRectangle`, flat `Elevations.nav`, surface fill)
holding four custom `_PillarButton`s `[Plan][Track] · notch · [Stats][You]` —
filled-sage/label when active, outline `onSurfaceVariant` when not (§6.6). The
**docked centre voice FAB** (`FloatingActionButtonLocation.centerDocked`, sage,
`Elevations.floating`, mic) opens a two-choice sheet: **Track time** →
`showLogTimeSheet` (S1, empty), **Plan time** → the schedule-builder (its own
first step IS the person-picker). **No STT (S6); the FAB's manual routing works
now behind the same seam.** Single-FAB rule holds — `PlanShell` has no FAB. The
Plan **aggregate badge** (`planAttentionCountProvider`) now rides the Plan pillar
AND the My Schedule sub-tab.

**Stats pillar = honest placeholder (accepted).** S2 was never built; rather than
a dead tab, `StatsScreen` renders the §6.14 shell with flat outlined tiles
showing `—` + "Coming soon" — never faked zeros. **The real dashboard and the
stat computations remain ungreenlit and out of this slice**; the placeholder
labels are the one thing that slice will edit.

**Account popup retired.** `AccountButton` was **deleted** — every item it held
now lives in the **You** pillar (Friends, Calendar, Language practice, Reminders
& permissions, Dev menu, Sign out, Edit profile) or **Plan** (Archived → Plan
overflow). Its usages were removed from the three (now embedded-only) stance
screens and from Calendar (a pushed screen with a Back arrow).

**Central fixes (flag-not-workaround).** `app_icons.dart` gained the pillar pairs
`navPlan/navPlanSelected`, `navStats/navStatsSelected`, `navYou/navYouSelected`,
`navTrack` (reusing `track`), and `voice` — none existed. No new token was
needed for the notch (`BottomAppBar` supplies it).

**Green:** `flutter analyze` clean; UI-RULES lint passes; the alarm test's route
expectation updated (`/outcome`→`/plan`) and green; `flutter build apk --debug`
succeeds (device-buildable). **One pre-existing, date-triggered test flake**
(`calendar_screen_test` "another day": `find.text('27').first` collides with a
leading outside-month cell when today+2's day-number repeats — today is Aug 25 →
Jul 27 shows in the grid). It is **independent of S5** (the calendar test harness
is a plain `MaterialApp` over `CalendarScreen`, never the router; the only S5
calendar change was removing an AppBar action) and is left for a separate
calendar-test fix, not folded into the cutover diff.

### S5 device pass — the headline highlight path, fixed on-device (2026-08-26)

The Redmi pass ran the headline `#1` (reminder/calendar → Plan → My Schedule,
item scrolled-to + outlined) and it was **intermittent, then broken in layers**.
Three distinct bugs were found and fixed; the path now works reliably from every
start state (My Schedule / Activity / Groups sub-tab, and repeats of the same
item). Diagnosed with temporary `PLANHL` logging (since removed).

- **Bug 1 — the sub-tab never switched / no highlight (root cause).** The intent
  was first encoded in the URL (`/plan?item=`, `?tab=`) and PlanShell reacted to
  go_router location notifications. **go_router caches the Plan branch's root
  page**, so a query-only change did not reliably re-run the builder OR fire a
  location notification — the "works 1-in-7, sequence-dependent" behaviour.
  **Fix: a deterministic Riverpod `planIntentProvider`** (`plan_intent.dart`,
  with `PlanTab` moved here). A call site (`calendar_item_sheet`, `alarm_screen`,
  `notification_routing`) sets the intent *immediately before* `go(Routes.plan)`;
  PlanShell listens via `ref.listen` (+ an `initState` `ref.read` for the intent
  set just before a cold build). Riverpod notifies every time. **The query-param
  route helpers (`planForItem`/`planActivity`/`planTabFrom`/`planItemParam`/
  `planTabParam`) were removed** — the URL is just `/plan`.
- **Bug 2 — a repeat of the SAME item did nothing.** OutcomeScreen keyed the
  highlight off `highlightItemId`, whose string is unchanged on a repeat, so its
  `didUpdateWidget` skipped. **Fix: a `highlightToken` (the `PlanIntent.seq`)**
  is passed alongside the id; a changed token re-fires the highlight even for the
  same item.
- **Bug 3 — no scroll (the visible symptom that survived 1+2).** The scroll was
  triggered from the highlighted **card's `build`** — but a lazy `ListView` does
  **not build an off-screen card**, so a far-down target never built, never
  triggered, and `ensureVisible` had no context. Only items already near the top
  highlighted. **Fix: an index-driven scroll** (`_tryScroll` on a `ScrollController`):
  jump to the item's index fraction to force it to build, then `ensureVisible`
  lands it exactly; retried across frames (covers the inner-TabBar slide) with an
  overlap-based visibility test (a near-list-end card clamps at
  `maxScrollExtent` and can't reach a 0.2 alignment, which a strict test looped
  on).

**The doctrine that held:** intent delivery is now a single deterministic signal
(the provider), the highlight re-fires on a token, and the scroll is driven by
index off state — none of it depends on go_router re-running a cached builder.
`flutter analyze` clean; suite 314 pass / the one pre-existing calendar flake;
device-buildable; **verified working on the Redmi.**

## UI redesign — S6: voice STT (2026-08-26)

The final planned slice, and the one that makes the docked voice FAB actually
listen. S5 shipped the FAB + the two-choice sheet with **manual routing only**;
the mic "did nothing on speech" because speech capture was never built. S6 fills
both flows behind that existing seam. **Nothing about the FAB or the sheet
changed** — only what each choice does after the sheet closes.

**Two flows, both prefill-only.**
- **Track time** → speak *"What are we logging?"* → parse `"[task] [duration]"`
  (e.g. "walking 30 mins" → task "walking", 30 min) → open the **existing** log
  sheet PRE-FILLED for confirm/edit.
- **Plan time** → **person-picker FIRST** (self / anyone who granted planning) →
  speak *"Please give alarm details"* → parse `"[Day][Time][Alarm name]"` → push
  the **existing** schedule-builder with the target chosen and the fields filled
  for confirm/edit.

**The non-negotiable: nothing is ever committed by voice.** Both parsers produce
a DRAFT that seeds the same manual sheet/builder the app already had; the user
still taps Log / Send. A misparse is a visible edit, never a bad write. And every
branch — dismissal, a denied mic, an unavailable recognizer, an empty or
unparseable utterance — falls back to the **identical manual flow**, so voice is
strictly additive and never the only way in.

### The engine — platform recognizer, free, behind a seam

- **`speech_to_text` (7.4.0)** wraps the PLATFORM recognizer (Android
  `SpeechRecognizer`, iOS `SFSpeechRecognizer`) — on-device where the OS ships
  offline models, otherwise routed by the OS to its own free service. **No API
  key, no per-call billing, no network code of ours** — the same no-Blaze posture
  as the on-device chatbot. It is the ONLY thing that requests `RECORD_AUDIO`.
- **`flutter_tts` (4.x)** speaks the two prompts aloud ("audio + on-screen text")
  through the platform TTS; needs no permission and degrades silently (the prompt
  is always on screen too).
- **The seam is `voice/data/speech_service.dart`**, same discipline as
  `chatbot_service.dart`: `SpeechService` exposes `ensureReady / speak / listen /
  stop / cancel / dispose` and **no OS vocabulary crosses it** — only
  `String`/`bool`. `PlatformSpeechService` contains every plugin type. An iOS or
  on-device-custom engine is a second implementation at the one
  `speechServiceProvider` line, with no screen change. A denied mic is **not an
  exception** — `ensureReady()` returns `false` and the caller falls back.

### The parsers — pure, English-only, exhaustively tested

`voice/application/voice_parsers.dart` holds the two pure functions
(`parseTrackUtterance`, `parsePlanUtterance`) — no plugins, no clock (the plan
parser takes `now` as an argument), no Firestore. **All the logic that can be
wrong lives here**, which is why `test/voice_parsers_test.dart` (27 cases) pins
it without a device — the `reminder_policy.dart` doctrine.

- **Track** finds the LAST `<number> <unit>` group; everything before it is the
  task. A **unit token is required** — a bare trailing number ("route 66") stays
  part of the task, so a number that is really part of the name is never mistaken
  for a duration. Handles digits, decimals ("1.5 hours"), fused tokens ("20min"),
  spelled numbers ("thirty", "twenty five"), and the article traps: **"half an
  hour" is 30, "an hour" is 60, "an hour and a half" is 90** (a trailing "a/an" is
  the unit's article, dropped only when another number word remains).
- **Plan** is order-tolerant: it finds a **day** (today/tomorrow/weekday →
  nearest occurrence incl. today), a **time** (`7am`, `19:30`, `half past seven`,
  `quarter to eight`, `noon`, `seven thirty`), and the **remainder is the title**
  with edge filler ("set an alarm for") trimmed but interior words ("clean the
  kitchen") kept. Any field may be null; the builder's `_canSave` still requires
  title + date + time, so an incomplete parse cannot submit straight through — the
  same guard the calendar-seed path relies on.
- **English-only for v1, logged as a limitation.** The worldwide requirement
  governs how the prefilled date/time is RENDERED (still through the one format
  helper); it does not require multilingual speech *parsing*.

### The mic-permission UX — rationale before the raw prompt

Mic is **not** a reminder-delivery permission, so it stays out of
`ReminderPermissionState` and the onboarding flow. The doctrine still holds: on
first use the capture sheet shows an on-screen rationale ("Speak and it fills in
the form… this uses the microphone") with **Start listening / Type instead**;
only **Start** calls `ensureReady()`, which fires the OS prompt. A device-local
`shared_preferences` flag (`voice_mic_rationale_accepted`, like the app-lock flag
— never on the Firestore profile) lets later captures skip the intro straight to
listening. Denial → a "type it instead" branch. The listening UI is a pulsing
filled mic, live partial transcript, a **Done** button (`stop()` → final result),
and an ever-present **Type instead**.

### Wiring — minimal, additive, seam-preserving

- New `lib/features/voice/{data,application,presentation}`. `home_shell`'s
  `_showVoiceSheet` now routes each choice into `_voiceTrack` / `_voicePlan`.
- **`showLogTimeSheet` gained `prefillTaskName`/`prefillMinutes`** (a NEW,
  never-editing seed distinct from `existing:`); **`ScheduleBuilderScreen` gained
  `initialTargetUid`/`initialGroupId`/`initialIsSelf`/`initialTitle`/`initialTime`**
  beside the existing `initialDate`. All null-default; behaviour identical when
  null.
- The Plan seeds ride as **query params on the pushed `/plan/schedule-builder`
  URL** (`Routes.scheduleBuilderVoice(...)`), read in the route builder. This is a
  PUSHED sub-route rebuilt each push — not the cached `/plan` branch root — so
  query params are reliable here; the reason `planIntentProvider` exists does not
  apply.
- New icons (`voiceListening`, `voiceStop`, `typeInstead`) and Sizes
  (`voicePulse`, `voicePulseIcon`) added to the vocabularies. `RECORD_AUDIO` +
  the `RecognitionService` `<queries>` entry added to the Android manifest; iOS
  `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` written
  (unverified — no iOS target).

`flutter analyze` clean; the UI-RULES §1/§2.7 lint stays green; 27 parser tests
pass; **debug APK builds** with both new plugins. **NOT VERIFIED ON A DEVICE** —
see the ledger below.

## UI redesign — device-verification ledger (as of 2026-08-25)

Slices are stacking up built-and-green but **NOT run on a device**. The list to
clear before (or at) the S5 cutover, so nothing is lost:

- **Tracked-time capture (Steps 1–3, 2026-08-25):** `decidedAt` parse; the
  `trackedTime` model + rules (rules ARE deployed + byte-verified, but no entry
  has been written from a device); the Done→track hook + confirm dialog. None
  exercised on-device.
- **S0 — Hearth tokens/UI-RULES:** invisible by design (unused token), so nothing
  to see, but the dataviz roles have never rendered.
- **S1 — Track pillar:** the log sheet (create/edit, quick-add chips, optional
  range), the history list, swipe-delete + undo, `formatDurationMinutes` — all
  unrun on-device. First real write to `users/{uid}/trackedTime` will happen
  here.
- **S3 — You hub:** navigation and the profile header unrun on-device.
- **S4 — Plan inner-TabBar shell:** unrun on-device. Specifically to check: the
  swipe between the three sub-tabs; that scroll position and selection survive
  switching (the keep-alive claim); the soft-sage underline and understated text
  tabs render as Hearth in light + dark + RTL; the My Schedule sub-tab pending
  badge appears/clears; each sub-tab's app-bar actions fire (approvals, ＋ Plan,
  ＋ New group / Join, Calendar, Archived overflow) and their detail pushes stack
  over the shell with a working Back; and — the point of the slice — that the OLD
  three-tab bar is unchanged beside it.

**Device pass to schedule before S5:** sign in on the Redmi (debug build), log a
manual entry (confirm it reaches `trackedTime`), edit it, delete + undo; mark a
plan Done and log from the prompt (confirm `sourceItemId` set); open the You hub
and confirm every row routes; open **Plan (preview)** and run the S4 checks
above; check light + dark and an RTL locale.

**This pre-S5 ledger was CLEARED on the Redmi 2026-08-25** (real `trackedTime`
writes commit; derived-end/midnight `(+1d)` holds; log-from-Done sets
`sourceItemId`; You hub routes; Plan shell swipe/keep-alive/Hearth underline pass
in light + dark + RTL). The ground is verified; S5 was then built.

- **S5 — bottom-bar cutover + voice FAB — THE CRITICAL PRE-SHIP FLIP, NOT RUN ON
  DEVICE.** This is the one irreversible user-facing change and **must get its own
  Redmi pass before any real user sees it.** In order:
  1. **HEADLINE — reminder highlight into the kept-alive shell. VERIFIED WORKING
     2026-08-26** after three bugs were found and fixed (see "S5 device pass — the
     headline highlight path" above): lands on **Plan → My Schedule** with the
     right card scrolled-to and outlined, from every start sub-tab and on repeats.
     The mechanism changed from a URL query param to `planIntentProvider`; the
     scroll is index-driven. The **real fired-reminder** variant (killed-app tap →
     alarm → Dismiss → highlight) still to be exercised, but it shares the exact
     same `highlightItem` + provider path as the calendar driver that was verified.
  2. **The bar itself:** four pillars switch and restore branch state; the docked
     voice FAB sits notched centre and does not overlap labels; Plan aggregate
     badge shows/clears; light + dark + RTL.
  3. **Voice FAB sheet:** Track time → the log sheet; Plan time → the
     schedule-builder (target-pick first). Confirm `context.push(/plan/
     schedule-builder)` from the FAB when the current pillar is NOT Plan behaves
     (flagged risk — fallback is goBranch(0) then push).
  4. **Notification routing:** a `created`/`withdrawn` push → `/plan/approvals`; a
     `decided`/`outcome` push → `/plan?tab=activity` (Activity sub-tab). (Needs
     the second device / a live token — folded into the notification retest.)
  5. **Stats pillar:** renders the honest "Coming soon" placeholder, no faked
     zeros.
  6. **Popup retired:** every former account-popup destination is reachable via
     **You** (or Archived via Plan overflow); no dead ends.
  7. **`/` and Back:** cold start lands on Plan; Back from a non-Plan pillar goes
     to Plan; Back on Plan double-press-to-exit still works.

The bar flip must not ship to a real user until THIS S5 pass is clean.

- **S6 — voice STT — BUILT + ANALYZER/LINT/UNIT GREEN, NOT RUN ON A DEVICE
  (2026-08-26).** Everything below the microphone and the recognizer is covered
  by the 27 pure parser tests; everything at/below the plugin boundary is
  device-only and unverified. To exercise on the Redmi (debug build):
  1. **Mic-permission doctrine:** first FAB → Track/Plan shows the rationale
     BEFORE any OS prompt; **Start listening** fires the prompt; grant, then
     confirm the second capture skips the intro (the `shared_preferences` flag).
     Revoke the mic in Settings and confirm the "type it instead" branch appears
     and routes to the manual flow.
  2. **STT accuracy (device-only, unmeasured):** whether the platform recognizer
     transcribes "walking 30 mins" / "Monday 7am gym" well enough that the parser
     lands the right draft. On-device vs cloud routing, latency, and offline
     (airplane-mode) behaviour are all unknown until run.
  3. **TTS (device-only):** whether the two prompts actually speak, and that the
     mic does not hear the TTS (speak completes before listen starts).
  4. **Track prefill:** a good parse pre-fills the log sheet (task + minutes) for
     confirm/edit; a task-only parse leaves minutes empty; Log writes to
     `trackedTime`.
  5. **Plan prefill:** the person-picker lists self + granted targets; picking one
     then speaking pushes the builder with that target selected and the parsed
     day/time/title filled; `_canSave` still gates an incomplete parse; Send works.
  6. **Fallbacks:** dismissing the voice sheet (Track → nothing; Plan → builder
     with target, manual), **Type instead**, and an empty/garbled utterance all
     land in the identical manual flow.
- **S6 — iOS config WRITTEN, UNVERIFIED.** `NSMicrophoneUsageDescription` +
  `NSSpeechRecognitionUsageDescription` are in `Info.plist`, but no iOS target is
  wired up, so nothing has run there.
- **S6 — English-only parsing is a KNOWN v1 limitation, not a bug.** A
  non-English utterance falls back to the manual flow (misparse → editable), never
  a bad write.

## Tracked-time — the range END is derived, not independent (2026-08-25)

**Supersedes** the Step-2 decision that the time-of-day range is "independent
display metadata that need not agree with `durationMinutes`". It now MUST agree:
`startLocal` is user-set and `endLocal` is always `start + durationMinutes`
(`deriveEndLocal`), so the two can never disagree.

**Why:** a range and a duration that could differ was a second, contradictable
source of "how long". Deriving the end from the authoritative duration removes
the contradiction and simplifies the UI (one picker, not two).

**Behaviour**
- **Create:** opting into a range asks ONLY for the start; the end is computed
  from start + the duration already entered. No start set → no range stored.
- **Edit:** if the entry already has a range, changing the duration (or the
  start) recomputes the end — 30→90 min on a `2:00–2:30` entry becomes
  `2:00–3:30`. If the entry has NO range, changing the duration never invents
  one.
- **Both-or-neither is now structural:** a range exists iff a start is set, and
  a start always yields an end — so a half-range can no longer be constructed.
  The stored shape (`startLocal`/`endLocal` strings) is unchanged, so **no rules
  change and no migration** — the rules' both-or-neither check still holds.

**Midnight crossing:** `end = (startMinutes + durationMinutes) mod 1440`. When
`end <= start` the range wrapped to the next day (e.g. `23:00` + 90 → `00:30`);
this is truthful because duration is the source of truth for length. It is
surfaced as a `(+1d)` suffix in the Track list and a live "Ends … (+1d)" preview
in the sheet, so an earlier-looking end never reads as a mistake.

`deriveEndLocal` is a pure helper in `tracked_entry.dart`, unit-tested (same-day,
wrap, full-day-back-to-start, malformed-start). `flutter analyze` clean.

**Device-verify-pending (ledger):** the derived-end edit/create behaviour and the
`(+1d)` display are built and analyzer-green but **not yet run on the device** —
added to the pre-S5 device pass alongside the S1/S3 items already listed.

## First-run orientation walkthrough — coach marks over the five-pillar bar (2026-08-26)

**What.** A first-launch coach-mark tour of the five-pillar bar: a dimmed scrim
with a spotlight cut out around each target, a tooltip card + downward arrow, and
Skip / Next controls. Five steps in **spatial bottom-bar order** — Plan → Track →
⊕voice(FAB) → Stats → You — one short line each. `lib/features/walkthrough/`.
Queued build item 2 of the current feature set; item 3 (the schedule-preview
modal) is NOT started.

**Copy (one line per target):**
- Plan — "Build schedules and set reminders — for you, or people you support."
- Track — "Log time you've spent and see where it goes."
- Speak to create — "Tap and talk to log time or plan a reminder — hands-free."
- Stats — "Your totals and trends, at a glance."
- You — "Profile, friends, calendar and permissions — all in one place."

**Why spatial order.** All five targets live in the always-visible bottom bar, so
nothing is navigated — the arrow just walks left-to-right across the bar, matching
the eye's scan, with the voice FAB as the natural mid-tour centrepiece.

**Custom overlay, no package.** A coach-mark package would fight the UI-RULES §1
lint (raw `Colors`, literal radii/spacing) and the theme. The overlay is a
`CustomPaint` scrim (`context.colors.scrim` at 0.72, a rounded/circular hole via
`Path.combine(difference)`) with a token-built card; it passes the lint. It is a
full-screen sibling stacked OVER `HomeShell`'s `Scaffold` — deliberately, so it
can spotlight the bottom bar and the docked FAB, which a body-level overlay could
not reach.

**Gating — mirrors `OnboardingStore` exactly.** A device-scoped
`shared_preferences` flag `walkthrough_completed_v1` in its own `WalkthroughStore`
(a new device earns its own tour; versioned key so a future bar change can
re-show intentionally). The tour is hosted inside `HomeShell`, which is only
reached past auth → profile → **permissions onboarding**, so it sequences after
permissions and never blocks a gate. First run: `HomeShell` watches
`walkthroughCompletedProvider`; when it resolves `false` a one-shot latch raises
the overlay post-frame. Skip and the final Done both write the flag + invalidate
the provider, so it never auto-shows again.

**Replay is orthogonal to the flag.** "How this app works" in You → Account &
device bumps `walkthroughTriggerProvider` (a `Notifier<int>` nonce — Riverpod 3
dropped the legacy `StateProvider` from default exports) and `go`s to Plan;
`HomeShell` listens and raises the tour. Replay does NOT clear the completed flag,
so the flag means exactly "should the tour appear uninvited on launch". Placed in
You because it is the settings/help hub, beside the permissions-onboarding replay
that already lives there.

**Pieces.** `data/walkthrough_store.dart`, `application/walkthrough_providers.dart`
(store + `walkthroughCompletedProvider` + `markWalkthroughCompleted` +
`walkthroughTriggerProvider`/`replayWalkthrough`),
`presentation/walkthrough_overlay.dart` (`kWalkthroughStepCopy`, `WalkthroughStep`,
`WalkthroughScrim`). `HomeShell` owns the five `GlobalKey`s (the bar is persistent,
so target rects resolve on first build) and the show/finish logic. New icon
`AppIcons.walkthrough` (`explore_outlined`). Pure copy list is unit-tested
(`test/walkthrough_test.dart`): five steps, spatial order, single-line bodies.

**Status: analyzer-green, lint + tour tests pass, debug APK builds. NOT VERIFIED
ON A DEVICE** — see the ledger below.

**Device-verify-pending (ledger):** on the Redmi (debug build, since prefs must be
readable) — (a) fresh install / cleared data: the tour auto-shows once after the
permissions flow, on Plan, and does NOT reappear on the next launch; (b) Skip on
step 1 dismisses and never re-shows; (c) Next walks all five spotlights, the
arrow points at each bar item, the FAB spotlight is circular; (d) tap-on-dim
advances; (e) You → "How this app works" replays it, and replaying does not make
it auto-show on a later launch; (f) dark mode (UI-RULES §8) and a right-to-left
locale, neither of which the overlay has been run in.

## Schedule-preview modal — auto-open on target select (2026-08-26)

**Diagnosis first (the question was "failing to fire, or never wired?").** Neither.
The "view B's schedule" modal was already **wired** — `schedule_builder_screen.dart`
renders a grant-gated button that calls `showTargetScheduleModal` — and already
the requested **centered + dimmed + blurred** dialog: `showGeneralDialog` with a
`BackdropFilter` (`Blurs.modalBackdrop`) PLUS a scrim (`context.colors.scrim` @
0.4) and a centered `ConstrainedBox` card (built 2026-08-21; there has never been
a plain-sheet version in git). No competing sheet exists — the only bottom sheets
in the plan/voice paths are the voice target-picker and voice-capture sheets.

**Why it read as "doesn't appear" on one device.** Two structural gates, both
needing a real second account/device: (1) the button is grant-gated
(`canViewTargetScheduleProvider` reads `plannerGrants` where you are the planner —
no grant from another account ⇒ no button); (2) the read is mirror-gated —
`targetScheduleProvider` needs `plannerAccess/{planner}_{target}`, which
`planner_access_reconciler.dart` writes from the **target's** device off *their*
grant stream, so until the target has been online the read is `permission-denied`.
So single-device there is simply no granted target to preview.

**Change (chosen: auto-open on target select).** The preview now opens
automatically the first time a **granted, non-self** target is selected, so their
commitments are visible before a time is picked — matching "should show before
scheduling." Kept minimal and non-nagging:
- `_maybeAutoShowPreview(targetUid, timezone)` latches per target in a
  `Set<String> _autoShownTargets` (A→B→A does not re-nag) and schedules the open
  **post-frame** (never a dialog during build), re-checking `mounted` / target /
  self before firing. It reuses `_pickSlotFromTargetSchedule`, so the chosen slot
  flows back exactly as the manual path did.
- `canViewTarget` (grant + non-self) is computed once and now gates BOTH the
  auto-open and the existing button; the button stays as the **reopen** path.
- No styling change — the dialog was already the "Settings-in-Claude" treatment.
- No rules/model/provider change; the modal's own read path is untouched.

`flutter analyze` clean, UI-RULES §1/§2.7 lint green, debug APK builds.

**Device-verify-pending (ledger) — TWO-DEVICE, deferred.** The whole point (a
*granted* non-self target) cannot be exercised single-device, as the diagnosis
above shows. On two accounts/devices: A grants B planner rights; on B's device open
the Schedule Builder, select A → the preview **auto-opens once**, centered with the
blurred+dimmed backdrop, showing A's real items in A's timezone; dismiss and the
"See A's schedule & pick a slot" button **reopens** it; picking a slot fills date +
time; selecting a second granted target auto-opens for them too, and returning to
A does not re-nag. Also confirm the `plannerAccess` mirror is present (A online at
least once) so the read is not `permission-denied`. Single-device confirmed here:
analyzer/lint/build only — the self path deliberately shows no preview.

## Voice-session cleanup — Track success feedback + past-date guard (2026-08-26)

Two fixes closing out the voice/track session before the #4/#5 friendship-grant
build. The Track blank-screen intermittent (the third thread) did **not**
reproduce and the hunt is dropped until it resurfaces with a log.

**Fix 1 — Track had no success feedback.** Logging a time entry (voice *or*
manual) popped the sheet with no confirmation. The Plan path already snackbars
("Item sent for approval" / "Added to your schedule"); Track did not. The
confirmation now lives in **one place** — `_LogTimeSheet._save()` — so the
voice-track and manual paths are consistent by construction (both commit through
this one sheet). Create → `Logged "<task>" · <duration>`; edit → `Entry updated.`.
Duration renders through `formatDurationMinutes` (locale-aware, worldwide
requirement), never a hand-built `'$m min'`. The `ScaffoldMessenger` is captured
**before** the await/pop because the sheet's own context is gone once it closes;
it resolves to the app-root messenger, so the snackbar shows on the screen
underneath after dismissal.

**Fix 2 — voice bypassed the past-date guard.** Saying a day/time already gone
created a plan in the past. Root cause was **two** things, fixed at two layers:

1. *The guard lived only in the date picker* (`_pickDate`'s `firstDate`), so it
   ran only when the user opened the picker. A voice-parsed draft (and a
   calendar seed) pre-fills the date/time fields directly and never touches the
   picker — so the guard was silently skipped. **Fix:** a hard past-instant check
   at the real chokepoint, `ScheduleBuilderScreen._save()`, before any write:
   `if (!instantUtc.isAfter(now)) { snackbar; return; }`. Checked on the resolved
   **instant in the target's timezone**, so it is correct across zones, and it
   covers self / planner / manual / voice alike — not just the pre-filled paths.
   Message: "That time has already passed. Pick a later time."
2. *Weekday resolution could land on today with a past time.* `parsePlanUtterance`
   resolves a bare weekday to its nearest occurrence **including today**
   (delta 0), so "Wednesday 10am" said on a Wednesday afternoon resolved to this
   morning — a past instant. **Fix:** after resolving day+time, a
   weekday-sourced date whose day+time is not in the future rolls +7 to next
   week. **Only weekday names roll** — "today"/"tomorrow"/an explicit calendar
   date are taken as said (a past "today 9am" is the speaker's error, caught by
   the builder guard, not silently moved a week). The parser's `now` is the
   device clock; the builder re-checks the instant in the *target's* zone, so the
   parser is the sensible-default layer and the builder is the guarantee. Two new
   pure tests in `voice_parsers_test.dart` (rolls when past, stays when future).

analyzer-green, `ui_rules_lint` + all 34 voice-parser tests pass, debug APK
builds. **NOT device-verified** (the reproduce-on-device pass was for the blank
screen only). Not committed.

**Device-pass follow-ups (2026-08-26, same session).** Two defects surfaced
during the single-device pass and fixed before commit:

- **STT "a.m." leaked into the title.** Android speech returns "8 a.m." with
  periods; the time scan matched only bare `am`/`pm`, so "a.m." was neither read
  as a meridian nor kept out of the title — "Wednesday 8 a.m. gym" produced title
  "a.m. gym". Fix in `voice_parsers.dart`: `_normalizeMeridian` folds
  `a.m./a.m/am.` → `am` (and the p.m. variants → `pm`) when building the token
  list, and the title assembly drops any stray unconsumed `am`/`pm` token as
  speech residue. Two new pure tests. (Time + roll-forward were already correct
  on device; only the title was wrong.)
- **Light-mode quick-add chips invisible.** The global `chipTheme` set no
  `backgroundColor`, so an unselected `ChoiceChip` was transparent with only a
  hairline `outlineVariant` border — invisible on a sheet's white `surface`.
  `AppText.labelSmall` also carries no colour. Fix in `app_theme.dart`: explicit
  `backgroundColor: surfaceContainerHighest`, `selectedColor: primaryContainer`
  (the selection tint used elsewhere — clears the §2.7 firewall),
  `showCheckmark: false`, and label/secondaryLabel colours. Centralized: the
  quick-add chips are the only chips in the app. Theme file, so §1's raw-value
  lint does not apply.

analyzer-green, lint + 36 voice-parser tests pass, debug APK rebuilt and
reinstalled on the Redmi for retest.

## Live-checked planner schedule access (2026-08-26)

**The problem.** Reading A's schedule was gated by "does `plannerAccess/{B}_{A}`
exist", and that row was written ONLY by A's device (`PlannerAccessReconciler`
off A's grant stream). So B could not view A's schedule until A had been online
to provision it — the "ask them to open the app once so it can sync" dead end.
There is often no way to make A open the app.

**The fix — the row is a groupId HINT, authorization is the LIVE grant.** A read
of `scheduleItems/{A}/items` carries no groupId and rules cannot query, which is
the only reason the mirror ever existed. Now the planner leaves a row naming a
group they were granted in, and `callerHasPlannerAccess` re-verifies
`callerHasActiveGrant(A, row.groupId)` on every read. Consequences:

- **The PLANNER writes their own row** (planner-side reconciler off the grants
  THEY hold — `myPlanningTargetsProvider`), so access needs no action from A.
  Safe because the planner cannot fabricate a grant: the create rule requires
  `callerHasActiveGrant(target, groupId)`, so a self-written row with no matching
  live grant is refused, and a row naming a group they lack a grant in is refused.
- **Revocation denies the read immediately** — a row that outlives a revoked
  grant fails the live check. No stale-access window, in either direction. (Old
  design erred toward "missing access"; this errs toward nothing — the grant is
  the single source of truth on every read.) Writes were already live-gated, so
  the item-create/slot-lock paths are unchanged.
- **A's self-plans reflect live in B's preview** with no extra work: the preview
  is already a `.snapshots()` stream (`targetScheduleProvider`), so once the read
  is authorized, an item A creates for themselves greys the slot under B in real
  time.
- The empty-groupId legacy row (old target-written mirror) no longer authorizes a
  read; the planner-side reconciler re-provisions a groupId-carrying row on next
  app open. **Migration is automatic and graceful** — no error to the user, no
  data loss; the "ask them to open the app" message survives only as the genuine
  no-grant fallback (and a brief pre-provision window on first open).

**Friendship grants (#4/#5) need no row.** They carry a computed pair id the
rules can construct, so `callerHasFriendGrant` / `callerHasEmergencyGrant` will
authorize reads DIRECTLY — which SUPERSEDES Option 1's separate `emergencyAccess`
mirror (dropped). The both-way emergency create invariant is untouched: those
checks are about item CREATE, not read.

**Rules changes.** `callerHasPlannerAccess` now does exists+groupId+live-grant;
`plannerAccess` create/update allows the planner (with a live grant, carrying
groupId) as well as the target; `list` is scoped to the two parties (the
planner-side reconciler needs the `plannerUid == me` query — it was `if false`
before, which had also been silently breaking the old target-side reconciler's
diff query); delete allowed for either party (planner cleanup). `scheduleItems`
and `scheduleSlots` read rules are unchanged in wording — they call the upgraded
helper.

**Tests.** Planner-side `desiredAccess` rule covered pure
(`planner_access_reconciler_test.dart`); the old target-side `desiredPlanners`
block removed from `slot_availability_test.dart`. Emulator: `slots.test.mjs`
rewritten for the new behavior — planner self-provision (with/without grant,
wrong group), read authorized only with hint+live grant, revoke-grant and
delete-row both cut off, legacy groupId-less row reads nothing, scoped
list, either-party delete. All 145 emulator + Dart unit tests green.

**Deploy order — RULES FIRST, then the new app build.** Unusually, an OLD client
is NOT fully fine against these rules: its target-written groupId-less rows stop
authorizing reads, and it has no planner-side provisioner — so its schedule
preview breaks until the new build (which self-provisions) is installed. On a
single device with the preview not in active cross-device use this is moot; the
new build is installed as part of this change. **Two-device proof deferred** to a
two-device pass like the rest.

## Friendship-scoped planning grants — #4 (2026-08-26)

**Doctrine addition:** planning permission may now originate from a FRIENDSHIP,
not only a group. **The friendship still grants nothing by itself** — permission
is a separate, per-direction, target-controlled grant, exactly like the group
grant, just anchored to the friendship. Groups are NOT retired; the friendship
grant is additive (they share the `plannerGrants` collection id, so the planner's
collection-group target picker and the grants-over-me query pick up both with no
change).

**The grant.** `friendships/{sortedPair}/plannerGrants/{plannerUid}_{targetUid}`,
same shape as the group grant, `groupId` pinned to `''`. Consent is the target's:
only they write `granted: true`; a planner may only relinquish their own to
`false`. Reads/creates authorize DIRECTLY via `callerHasFriendGrant` — a computed
pair id — so **no `plannerAccess` hint row is needed for the friend path** (the
planner-side reconciler skips empty-group grants). `callerHasFriendGrant` also
requires `areFriends`, so **a grant is void the instant the friendship ends**
(unfriend/block) — no stale-power hole. The item-create friend branch is
**pending only** (no `tier` yet; that is #5); the group `callerHasActiveGrant`
branch is untouched.

**Two opt-in paths, consent always from the target.**
- *Proactive toggle* — "Let [name] plan for me" on the friend's profile, default
  OFF; writing/removing the friendship grant.
- *Requested* — `planningRequests/{fromUid}_{toUid}_{kind}` (kind `normal`/
  `emergency`, in the id so both can be pending). A distinct collection: not a
  friendRequest (that is the friendship), not the per-item pending queue (that is
  approving one plan). Friends-only create; recipient decides once; either party
  deletes. **Approval never mints a grant from the request row** — the target
  authors the grant doc separately (grant first, then delete the ask), so consent
  still originates from the target. Settled requests are deleted, so only pending
  rows persist and the inbox query is a single-field `toUid == me` (no composite
  index).

**Client.** `PlanningPermissionRepository` (grant + request flow);
`planning_request.dart` domain; providers derive the per-friend state from LIVE
caller-scoped collection-group queries (`grantsOverMeProvider`,
`myPlanningTargetsProvider`, outgoing `fromUid == me`) — NOT per-doc listeners,
which terminate on the absence-denial (same trap the friend-graph providers
avoid). Toggle + ask control on `user_profile_screen` (friends only); a
"Permission to plan" section on the renamed **Requests** screen; the requests
badge now counts both kinds. The builder/preview already worked for friend
targets (the grant flows through the collection-group picker; items carry
`groupId ''`).

**Push is the fast-follow** (inbox now): the two `FriendNotifier` events
`planningRequest`/`planningApprove` + their Worker branches are not wired yet.

**Rules DEPLOYED + byte-for-byte verified — ruleset
`53eaf388-3fad-4ed5-bd2e-644863f17d57`** (supersedes the access-fix
`889accb5-…`). 163/163 emulator tests (new `friend_grants.test.mjs`) +
analyzer/lint/debug build green. **NOT device-verified — two-device deferred**
like the rest (the grant's effect needs A and B on two accounts).

## Emergency item tier — #5 (2026-08-26)

**A new item tier.** Every pre-#5 item is a NORMAL item (requires the target's
per-item approval before it fires). An EMERGENCY item is created **already
`approved`** by a planner holding a SEPARATE emergency grant, so it skips the
queue and fires directly. `tier` (`normal`/`emergency`) on the item; **absent
defaults to `normal`**, so old clients and every normal item are unchanged and
the field is only stamped when emergency.

**The reminder engine did not change.** Emergency = born `approved`, and
`desiredReminders` already arms every approved future item off the item stream.
So the emergency item arms itself through the existing reconciler with zero new
code — the whole point of "skip the queue by being born approved".

**The separate grant + the both-way invariant (rules-enforced, proven by
tests).** `friendships/{pair}/emergencyGrants/{planner}_{target}`, a DISTINCT
document from the normal `plannerGrants`. `callerHasEmergencyGrant` checks it
(and `areFriends`, so it is void on unfriend). Item-create has three branches:
self (any tier), normal planner (group OR friend grant → **tier normal +
pending only**), emergency planner (**emergency grant → tier emergency +
approved only**). Therefore:
- a NORMAL grant can never create an emergency item (only the emergency branch
  admits tier=='emergency' or non-self 'approved', and it needs the emergency
  grant); and
- an EMERGENCY grant can never create or queue a NORMAL item (the normal branch
  needs a group/friend grant it lacks, and forces tier normal + pending).
Neither implies the other — two distinct documents. Emulator tests assert both
directions, plus: emergency can't be born pending, unfriend voids it,
creator-only recall, a normal approved item can't be recalled.

**Read access (Option 1, direct).** An emergency grant authorizes reading the
target's schedule directly via `callerHasEmergencyGrant` on the item/slot read
rules — NO mirror (superseding the earlier `emergencyAccess` mirror idea; a
friendship-scoped grant is a computable pair id, so it needs none). Seeing the
schedule is strictly less invasive than setting an auto-firing alarm on it.

**Recall.** The planner-withdraw update branch now also allows
`approved→withdrawn` for an emergency item the CALLER created — "recall the
emergency I placed" (directed).

**Two opt-in paths, its OWN grant.** Same shape as #4 but the emergency
subtree/kind: a separate "Let [name] set emergency alarms for me" toggle
(default OFF, independent of the normal toggle) and a `kind: 'emergency'`
planning request. Approval writes the emergencyGrants doc (the target authors
it). New `emergencyGrants` collection-group indexes (granted+plannerUid,
targetUid). New builder control: an **Emergency** switch, shown only when I hold
the emergency grant over the selected target, re-checked against the live grant
at save.

**Client.** `ScheduleItem.tier`; `createItem(tier:)`; `PlanningPermissionRepository`
extended (grant kind, emergency collection-group queries, approve-by-kind);
emergency providers; profile emergency toggle + ask; inbox differentiates the
emergency request; builder Emergency switch. New `AppIcons.emergency`.

**Push is still the fast-follow** for BOTH #4 and #5 (the `planningRequest`/
`planningApprove` Worker events); inbox works now.

**Rules + indexes DEPLOYED + byte-for-byte verified — ruleset
`a10d6b4f-c1ae-4b39-b69f-89eff91866da`** (supersedes `53eaf388-…`). 176/176
emulator tests, analyzer/lint/debug build green. **NOT device-verified —
two-device deferred.** (One unrelated pre-existing calendar test flakes on
today's date: it taps a day-number that August 2026's grid also shows as a July
outside-day; not a #5 regression.)

## Group features — planning, accountability, leaderboard (2026-08-26)

Groups repurposed with three real jobs; the group data model and grants are
untouched (the friendship grant stays additive). Build order: planning (no
rules) → accountability + leaderboard (one new published collection).

**1 — Group planning (fan-out).** "Plan for the group" creates the SAME item for
every member the planner holds an active grant over (plus themselves), each
resolved in THAT member's own home timezone — so "9am" is 9am locally for each
person, not one absolute instant. It is a plain loop of `createItem`
(`ScheduleRepository.planForGroup`), best-effort per member (a taken slot,
missing grant or past time skips only that one), so **no rules change and no
batch** — every write is already authorized by the group-grant branch, and items
already carry `groupId`. Self → `approved`; everyone else → `pending`. Reached
from a card on the group detail screen (shown only when ≥1 other grantee exists);
a per-member `created` push fires like single planning.

**2 + 3 — Accountability + leaderboard (shared `memberStats`).** Two views of one
new published collection `groups/{groupId}/memberStats/{uid}`. A group member
cannot read another member's items nor their friend-gated `profileStats`, so —
**published, not derived**, same doctrine as `ProfileStatsRepository` — each
member's device publishes a small summary and fellow members read it.
- **Stats are the OVERALL profileStats numbers**, reused from
  `myComputedStatsProvider` (no per-group recomputation) and republished into
  each group I belong to. Fields: `name, tasksCompleted, currentStreak,
  followThrough, updatedAt`.
- **Driven off the item stream, never transitions** — `GroupStatsPublisher`
  alongside `ProfileStatsPublisher` in the same `app.dart` wire, idempotent via a
  signature; plus a `myGroupsProvider` listener so joining a group seeds it. Reset
  on sign-out.
- **Shared streak = the smallest current streak among members** — the run
  EVERYONE currently has going, so the group only holds it while everyone shows
  up (its "everyone must show" property is the point). This refines the proposed
  "consecutive days all completed" to something computable from the published
  summary — no per-day history to publish.
- **Leaderboard** ranks by follow-through %, then tasks done, then name — same
  data, a second view. One screen, `GroupProgressScreen` (`.../groups/:id/
  progress`), reached from a group-detail card.
- **Rules:** `memberStats/{uid}` — read if `callerInGroup`, create/update if
  `uid == caller` and a member (self-write only, so no one forges another's
  numbers), field-whitelisted; self-delete. Values are unverifiable by rules (a
  member could inflate their OWN board position) but describe only the writer's
  own record — the ceiling is self-inflation, never reading anyone else's data.
  No index (a plain subcollection read).

analyzer/lint/debug build green; 183/183 emulator tests (7 new for memberStats).
**Rules NOT yet deployed / NOT device-verified** — two-device proof deferred.

**Device-pass fixes (group planning, 2026-08-26).** Three issues surfaced on the
Redmi while testing the fan-out, all fixed:
- **Infinite spinner — the real cause.** Resolving each member's timezone via
  `ref.read(profileByUidProvider(uid).future)` never returned: a bare read of a
  `StreamProvider.family` instance nothing else keeps alive stalls its `.future`
  (it hung on the very FIRST candidate, self). Fixed by resolving timezones in
  PARALLEL via a one-shot `repo.watchProfile(uid).first.timeout(8s)`, skipping
  any member that can't be resolved. (Connectivity was fine — Firestore pinged
  at ~30ms; the DNS errors in logcat were an unrelated Xiaomi service.)
- **Pushes must not block the UI.** The fan-out awaited a `created` push per
  member, and `notify()` calls `getIdToken()` which has no timeout — a latent
  freeze. Now fire-and-forget (`unawaited`), in both the group sheet and the
  single-plan builder. The Firestore writes are the durable work; the pushes are
  best-effort.
- **"No one could be planned for" was opaque.** All-skipped is usually a PAST
  time; `planForGroup` now returns `skippedPast`/`skippedOther` split, and the
  sheet says "That time has already passed. Pick a later time." when that's why.

**Single-device device pass: PASSED** — group progress screen renders (shared
streak + follow-through + leaderboard, own row), and the group-plan fan-out
sends cleanly for a future time (self item appears approved). Two-device proof
(seeing another member on the board / another member receiving a pending item)
stays deferred.

---

## Title sanitizing, end-of-day lapse + late-delay stats, record-again, create FABs, bottom safe-area (2026-08-27)

Six changes, all directed this session. Analyzer + UI-RULES lint green, 369 tests
pass (new `test/item_lapse_test.dart`). Installed debug on the Redmi — **not yet
device-verified**; the earlier on-device build was *release-signed*, so every
debug reinstall was silently rejected (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) until
the old package was uninstalled. Lesson: do not mix release- and debug-signed
builds on the test phone; uninstall to switch.

**1. Title residue sanitizer.** "a.m. cycling" in the hero was legacy title data
(the voice parser already strips meridians). `sanitizeScheduleTitle()` (in
`schedule_item.dart`) is applied on every READ (`fromDoc` — fixes existing data
with no migration, on every screen) AND every WRITE (`createItem` — clean bytes
for voice + manual). Conservative: drops dotted `a.m./p.m.` anywhere, bare
`am/pm` only at the title's edges, so "I am tired" / "spam folder" survive; never
empties a title.

**2. End-of-day auto-lapse — the FIFTH stream-driven reconciler.** An unaddressed
item cannot sit in "next" forever. At MIDNIGHT IN THE ITEM'S OWN LOCAL DAY (tz-
aware, `endOfScheduledLocalDayUtc` via `TZDateTime` so DST is exact) a still-
`pending` item is `reject`ed ("Not approved in time") and an `approved` item with
no outcome is `markSkipped` ("Did not respond"). Pure classifier `lapsedItems()`
in `item_lapse_policy.dart`; `ItemLapseReconciler` + `itemLapseSyncProvider` wired
one line in `app.dart`, off `allItemsAsTargetProvider`, runs on the target's own
device. Same doctrine as the other four reconcilers: off the stream, never off a
transition; idempotent (settled items untouched); client-driven (lapses on next
emission/app-open past local midnight — no Cloud Functions here). Nothing is
deleted; the settled item stays visible to the partner, and its reason feeds
stats. **Grace = the whole local day** (chosen over 1–2h/immediate), so the user
has until midnight to act — and to complete LATE.

**3. Late-completion delay — derived, not stored.** `markDone` already writes
`outcome.completedAt`; delay = `completedAt − scheduledInstantUtc`. New
`ScheduleItem.completionDelay` / `wasCompletedLate` getters (null/​false unless
done AND after the scheduled instant; a done item lacking `completedAt` counts
on-time, never a guessed late). No new field, no migration — a stored
`delayMinutes` would only be a copy to drift. Surfaced: per-item `· Xh Ym late` on
the outcome card and planner activity; two new `kProfileStatDefinitions` tiles —
**On-time rate** (percent of completions at/before their time) and **Avg late by**
(mean lateness over the late ones only). `StatItem` gained `completedAt`.

**4. Record-again.** The voice sheet no longer auto-commits the transcript: a new
`review` phase shows "Heard: …" with **Use this / Record again / Type instead**.
Nothing saves until "Use this"; "Record again" re-listens. The form still confirms
afterwards.

**5. Per-page create FABs — "one FAB" retired.** A single centre mic left MANUAL
create hidden behind an app-bar `＋`, confusing users who stayed on My Schedule.
Now two FABs, each with a distinct job (UI-RULES §6.12 rewritten): the centre
**voice** mic (`HomeShell`, all pillars) and a bottom-right **`＋` manual-create**
FAB owned by the creating pillar's own inner scaffold — **Plan** ("Plan an item",
shown on all three sub-tabs → schedule builder) and **Track** ("Log item" → log
sheet). Distinct `heroTag`s; the pillar FAB sits above the system nav bar and
clears the shell bar. The now-redundant Activity/Track app-bar `＋` actions were
removed. This is a deliberate doctrine change, recorded here and in UI-RULES.md
before the code, per the standing rule.

**6. Bottom system-nav overlap — swept.** Full-screen PUSHED routes were padding
content with bare `Space.screenList/screenForm`, so the last row / footer button
slid under the phone's back/home/recents bar (reported on How-it-works "Replay"
and profile "This device"). Added `Space.screenListSafe/screenFormSafe(context)`
+ `systemBottomInset(context)` (bottom inset from `MediaQuery.viewPaddingOf`, so
it survives the keyboard) and applied to every top-level pushed screen (How-it-
works, Profile edit, Complete profile, Auth, Calendar agenda, Friends, Friend
requests, User search, User profile, Blocked users, Chatbot settings, Reminder
diagnostics, Onboarding/permissions, Archived, Schedule builder). In-shell tab
bodies were deliberately left alone (the `BottomAppBar` reserves that space);
centered content (lock screen) and already-`SafeArea` bodies (chat, model setup,
alarm) needed nothing.

**Discoverability.** Friends "buried" and the plan-button confusion are answered
by (5) plus expanded orientation: the first-run walkthrough copy now names where
each feature lives and points at the `＋` FABs, and "How this app works" is
restructured around the real bar (Plan/Track/⊕/Stats/You) with "in the You tab"
tags on Friends, Calendar, Language practice and permissions. Walkthrough test's
single-line-body contract kept.

---

## Durable six-hour inactivity prompts (2026-09-23)

Inactivity is account state, not device-local alarm state. Real use means a
signed-in launch/resume or pointer interaction; those signals are coalesced to
one Firestore write per five minutes. Background FCM work does not count. State
lives at private `inactivityStates/{uid}`, outside the broadly readable profile.

The Worker cron runs every five minutes, conditionally leases due documents,
re-checks activity after claiming, and sends one of 50 short messages in fixed
sequence. The cursor advances only after a real FCM delivery and wraps only
after message 50. No-token/transient runs retain the cursor. Continued
inactivity schedules another prompt six hours later; any genuine app use resets
that timer. Conditional claims prevent overlapping cron sends, while a final
activity re-check prevents an app-open racing delivery from shortening the new
six-hour window.

---

## Long histories use month-year buckets (2026-09-23)

The existing day grouping remains the source of ordering and row construction.
Once a surface reaches 12 distinct day groups, the shared history widget wraps
consecutive days in localized month-year buckets without re-sorting them. This
is a navigation layer, not a datastore or archive rule: My Schedule, Activity,
Track, and Archived still receive their existing filtered lists and item order.

Twelve days is the deliberate crossover: below it, another tap and heading add
more friction than scanning; at and above it, month landmarks materially reduce
a long wall of dates. A bucket containing an initially open day or a forced
deep-link day opens automatically. The forced day opens too, preserving the
existing keyed-card scroll. Headers expose button, heading, expanded/collapsed,
label, hint, and tap semantics. Archived adopts the same grouping but keeps
short archives fully visible; long archives collapse while Unarchive continues
to write through the unchanged owner-scoped repository.

---

## Planner item timeline uses observed facts (2026-09-23)

The planner's Activity card opens a detail sheet with Scheduled, Rang,
Dismissed, and the final Done/Skipped event. Reached events carry their actual
timestamps. Until the target explicitly marks Done or Skip, the final row stays
visibly “Outcome pending”; dismissing an alarm is never treated as an outcome.

Native Android `AUDIO_FIRED` audit rows are the authoritative ring observation
and are reconciled into `scheduleItems/{targetUid}/items/{itemId}.alarm.rangAt`
when the target app runs. The full-screen alarm records a current-time fallback
so the planner can see a live ring even before reconciliation, and records
`dismissedAt` when Dismiss is pressed. First/earliest writes win, allowing the
exact native time to replace a later fallback without resume-time duplicates.
Reconciliation passes are serialized, while event writes are best-effort and do
not hold up reminder playback, dismissal, or navigation if Firestore is offline.

The shared map is target-written, approved-item-only, and field-scoped by
Firestore rules. Existing planner read access already exposes the item. Legacy
outcomes with no timestamp are shown as reached with “Time unavailable”; the UI
never substitutes `updatedAt` or the scheduled time.

---

## Testmates “Plan for the group” was fixed by permission unification (2026-09-23)

The missing action was caused by the group detail screen looking only at
`grantsProvider(groupId)`. After friend planning permission moved permanently
to profiles, a friend’s live grant sits below the friendship with `groupId == ''`,
so the group-local query correctly returned no row and the action disappeared.

Commit `b7adf45` already fixed the production path: group planning now consumes
`effectivePlanningTargetsProvider`, which selects friendship grants for friends
and group grants for non-friend members. No further permission or datastore
change is needed. The regression is pinned at the real Testmates group screen:
an empty group-grant stream plus an effective friendship grant must render the
group-planning action and open a sheet containing both the caller and friend.

---

## One-minute alarm cap and durable missed handling (2026-09-23)

Native alarm playback now has a hard 60-second cap (down from the old ten-minute
safety valve). The foreground service records every active item into a
device-protected lifecycle queue before releasing audio and its wake lock, so a
dead Flutter process, locked device, or lost network cannot erase the miss. It
also cancels the owning reminder notifications at timeout or hardware silence;
otherwise a stale notification could be tapped after the cap and start a second
ringing session.

When authenticated Dart is available, the stream-driven reconciler writes
Skipped with reason `User unavailable` through a transaction that succeeds only
while the item is still approved and has no outcome. A concurrent human Done or
Skip therefore wins. The ordinary end-of-day lapse pass uses the same
write-if-unsettled rule; if that generic `Did not respond` fallback won just
before the native timeout was reconciled, only that exact automatic outcome may
be replaced by the more specific `User unavailable` fact and its real timeout
timestamp. Planner outcome notification is retried from the durable row until
delivered (or the Worker confirms it was already sent). Review and notification
delivery are separate flags: acknowledging the next-open review cannot discard
an undelivered planner notification.

Volume Down is consumed only when Android delivers it to the foreground
`MainActivity` while alarm playback is active. It stops native playback
immediately, drives the same Dart dismissal/navigation path when Flutter is
present, and durably backfills `dismissedAt` otherwise. It never records Skip.
There is deliberately no accessibility service, global key capture, or promise
that an OEM will deliver Volume Down while the activity is absent; Android's
standard behavior is to adjust the active audio stream in that case.

The next unlocked foreground shows one app-wide review card containing every
unreviewed missed task. Items remain in their normal date groups because the
existing outcome map—not archive or a separate missed collection—represents the
skip. The native local queue is the delivery/review cursor only.

---

## Android alarm wake is early native state, with an actionable fallback (2026-09-23)

`setTurnScreenOn` and `setShowWhenLocked` were already present, but Flutter only
invoked them after `AlarmScreen` mounted and claimed audio. That is too late for
the launch decision: the Activity must request those window behaviors before it
is resumed and visible. `MainActivity` now classifies the plugin's explicit
`SELECT_NOTIFICATION` plus non-empty item payload on both cold `onCreate` and
warm `onNewIntent`, applies the modern Activity APIs (legacy flags below API 27),
and clears all three show/turn/keep-screen behaviors on dismiss, timeout,
ordinary intents, and destruction. It never requests keyguard dismissal.

The native delivery service now posts its own silent high-priority alarm
notification with the same full-screen Activity intent. This is intentionally a
second delivery path: it originates at the native due-time receiver and does not
wait for Flutter or the scheduled-notification plugin to present correctly. The
notification always exposes a native Dismiss action, which stops sound, cancels
the owning reminder notification, and durably records `dismissedAt` even when no
Flutter UI appeared.

This remains best effort, not an “all Android devices” guarantee. Android 14+
lets users revoke full-screen-intent access, notification/channel visibility is
user-controlled, and OEM background policy may still refuse Activity launch.
The supported fallback is therefore an actionable lock-screen notification, not
a deprecated screen wake lock or any attempt to bypass user settings.

---

## Splash ting fades inside—not beyond—the 1.5-second reveal (2026-09-23)

The visual timing is unchanged: 1,150ms intro plus 350ms outro. Native
`SplashSound` now ramps its `SoundPool` stream to zero over the final 750ms and
stops at the original 1,500ms deadline. The deadline is measured from the Dart
play request, not from asynchronous sample-load completion; a late preload gets
only the remaining window and an expired request never starts a stale sound.
Replay cancels the previous fade callback, while the existing ringer-normal
gate and one-shot playback remain unchanged.

---

## Device regression hardening: one alarm owner and alarm-clock delivery (2026-09-23)

On-device testing exposed two gaps that unit-only policy checks did not cover.
With Checkmate visible, the scheduled notification and native foreground
service could both own audio, while `AlarmScreen` cancelled the notification
before its asynchronous UI ownership claim reached the service. That produced a
stop/restart cadence of roughly two seconds. The scheduled notification is now
silent and non-full-screen; the due-time receiver and `AlarmSoundService` are
the only audio/full-screen owners. `AlarmScreen` awaits its ownership claim
before cancelling the redundant notification, preserving uninterrupted
whole-tone looping on locked and unlocked paths.

Another device run showed no alarm while Instagram was foreground; opening
Checkmate near the end of the minute started the UI fallback. Code-path audit
found the direct cause: `AlarmDeliveryChannel` existed but was never registered
in `MainActivity`, so every native arm returned unavailable and no due-time
receiver existed. The channel is now registered. Exact native audio delivery
also uses `AlarmManager.setAlarmClock`, while the plugin retains a quiet visible
schedule record. This intentionally accepts Android's system next-alarm
affordance in exchange for the strongest public due-time primitive. It is still
not a promise against revoked exact-alarm/full-screen permissions or hostile OEM
policy; `AUDIO_ARM_FAILED` and `AUDIO_START_FAILED` remain explicit diagnostics.

Volume Down remains scoped to the foreground `MainActivity`, but its dispatch
gate and native stop request are now both checked: the key is consumed only for
the first down event while playback is actually active and the stop request was
accepted.

## Completion and outcome regressions: silent, once, immutable (2026-09-23)

The completion celebration has no audio. Its overlay covers the complete host,
uses event-specific identity, pauses across lifecycle/lock interruptions, and
advances the local queue before waiting for Firestore acknowledgement. Repeated
snapshots therefore do not replay an event, a slow network acknowledgement does
not block the next task, and subsequent completed tasks still celebrate.

Done and Skip are now transactional first-write-wins operations. The UI disables
both controls while a write is pending, and Firestore rules reject replacing an
existing human outcome. The only allowed replacement remains the established
automatic lapse refinement from `Did not respond` to `User unavailable`.

---

## Completion confetti uses measured ballistic motion (2026-09-23)

The supplied WhatsApp reference was inspected frame by frame at 30 fps. Its
first complete effect remains visible for 42 frames and is absent on the next:
the visual contract is therefore 1,400ms, replacing the previous guessed
1,500ms duration. The reference is an instantaneous compact burst followed by
drag, gravity, rotation and fade—not a bottom-origin sine arc.

The old painter is replaced by a deterministic per-event ballistic simulation.
It precomputes 132 paper, ribbon and sparkle particles once per event, then one
`CustomPaint` samples their positions while the controller runs. Density and
dispersion intentionally exceed the reference, reaching the horizontal edges
and both vertical halves without extending the measured duration. The overlay
remains `IgnorePointer`, isolated by `RepaintBoundary`, and is removed by the
animation controller's completion signal rather than a second timer.

---

## My Schedule owns Upcoming; History owns elapsed and completed plans (2026-09-24)

My Schedule is now a forward-looking surface. An approved plan appears there
only while it has no outcome and its scheduled UTC instant has not passed.
Equality stays Upcoming; immediately after that instant, or as soon as an
outcome exists, it belongs to History. Comparing absolute instants instead of
local dates makes the partition disjoint across midnight, timezone changes, and
DST folds or gaps.

History is a Plan sub-route, not another bottom-navigation pillar. It preserves
the existing outcome cards and collapsible days, orders days and plans newest
first, and introduces localized month buckets exactly when two calendar months
are represented. A Calendar selection follows ownership first: pending target
items go to Approvals, elapsed/completed target items go to History, other
target items go to My Schedule, and planner-side items remain in Activity.
History intents force the relevant month and day open before the existing lazy
scroll/highlight behavior runs.

The visible entry points are now the bold rounded `CALENDAR` and `HISTORY`
controls beside `Upcoming Plans`. The superseded Plan app-bar calendar glyph
and You-hub Calendar row were removed so there is one discoverable path.

---

## Missed-alarm review separates availability from completion (2026-09-24)

A one-minute alarm timeout now records two deliberately independent facts. The
default outcome remains `Skipped: User unavailable`, but the same transaction
also writes immutable `alarm.unavailableAt`. The former is the task's current
completion result; the latter is permanent device-observed evidence that the
target did not respond while the alarm was active. Firestore rules permit only
the exact automatic unavailable Skip to become Done and never permit the
unavailability timestamp to be moved or erased.

The next-unlocked-foreground review shows one missed task at a time with exactly
two actions: Mark as Skipped retains the automatic default, while Mark as Done
performs that narrow transaction. A corrected completion is still stored as the
ordinary `done` enum and rendered as `Done (Late)` from item context; it is not a
third outcome. Both parties continue to see `User unavailable at alarm time` in
the task history.

Review choice and follow-up delivery are retained in the device-protected native
lifecycle row. This makes a process death between the tap, Firestore write, and
planner notification retryable. The Worker's existing subtype guard treats
`notifiedOutcome: skipped` followed by `done` as a new event, sends an explicit
late-completion follow-up, and deduplicates repeated Done retries.

Planner notification delivery is no longer on the popup's critical path. Once
the automatic outcome is durable, the local review becomes visible immediately;
the potentially slow token/HTTP path proceeds independently and remains backed
by the durable native row. The app lock and cold-start reveal still remain above
the review surface.

---

## Request a plan uses requests as workflow, never authority (2026-09-25)

Item 23 adds `planRequests`, deliberately separate from the existing
`planningRequests` permission ask. A plan request is addressed from the schedule
target to a friend who already holds the target-authored normal friendship
grant. Both friendship and grant are checked on request creation and again in
the atomic fulfillment transaction. The schedule-item create rule still uses
the ordinary normal-grant branch and still forces `pending`; possession of a
request can therefore never create an emergency or auto-approved item.

One-plan requests require exactly one item of the requested duration. Flexible
requests may append several items and are explicitly closed by the planner.
Every request carries the requester's timezone snapshot and absolute UTC window
bounds. Fulfilled spans are half-open `[start,end)`, so adjacent plans are
allowed. They append chronologically; this is both a simple planner interaction
and the bounded invariant that lets Firestore rules prove non-overlap without a
query or loop. The item and request advance in one transaction and cross-check
each other through `planRequestId`, `lastFulfilledItemId`, start, and duration.
Settled requests reject replay.

A multi-friend ask is a batch of independently actionable documents with stable
`batchId_plannerUid` ids. The UI caps one atomic send at ten recipients because
each write's rules re-read one friendship and one grant, fitting Firestore's
20-access-call batch limit. One friend's response cannot settle another's row.

Only request-created items gain `durationMinutes`; an absent value decodes to
zero so all legacy and ordinary point alarms retain their existing behavior.
Request pushes carry the request id, route to the plan-request inbox, and stamp
`notifiedRequested` only after a successful delivery so client replay is
idempotent. Fulfilled items reuse the existing `created` notification and
approval routing instead of adding a duplicate target alert.

---

## Conditional conflict disclosure replaces schedule browsing (2026-09-25)

The Schedule Builder no longer opens or offers a full target timetable. That
surface disclosed titles, notes, statuses and empty portions of another
person's day even when the planner only needed one narrow fact: whether the
selected target already had a live commitment on the chosen date. Item 27
replaces it with an informational warning that appears only when the authorized
live stream contains an outcome-less `pending` or `approved` item on that
target-local day.

The privacy boundary is structural. `conflictInstantsForLocalDay` consumes the
authorized item stream and returns sorted, unique UTC instants. Presentation
receives `ConflictDisclosureGroup` values containing only uid, display name,
timezone and those instants—never a `ScheduleItem`, title, note, creator, status
or outcome. Times and dates render through the global localized formatter. Two
items at one instant disclose that time once, avoiding unnecessary count
metadata.

The warning is advisory. Its only action is `Got it`; dismissal leaves the form
and save button unchanged. The normal create transaction and grant checks stay
authoritative. Read failures are never treated as an empty schedule: the same
dialog names each person whose schedule could not be checked and explicitly
says saving remains possible.

Single-person planning watches the selected target, selected date and existing
live schedule provider. Group planning watches every candidate and waits until
all profile/schedule reads settle, then shows one consolidated popup grouped by
name. Each member's shared wall date is evaluated in that member's own timezone,
so mixed-zone and DST-short/long days use absolute day bounds correctly.

A stable fingerprint contains the wall date, sorted uids, timezones, conflict
instants and read-error identities; display names are excluded. Identical
information is shown once per form session, while target/date/feed/error changes
produce a new fingerprint and re-evaluate. A queued dialog also verifies that
its fingerprint is still current before opening, preventing stale popups after
a rapid target or date change.

The old `showTargetScheduleModal`, its builder button/auto-open path, and the
blur-only design token were removed. Existing slot-domain helpers remain because
legacy lock reconciliation and its DST/property coverage still use them; they
are no longer a schedule-browsing UI.

---

## Ringing alarms identify the planner (2026-09-25)

The ringing alarm screen resolves the schedule item's `createdByUid` through the
existing profile stream and places that display name directly above the task
title. Both lines are centered and explicitly bold so planner attribution is
visible in the alarm's primary hierarchy rather than hidden in secondary
metadata.

The schedule item remains keyed to the immutable planner uid; the display name
is not duplicated into alarm or schedule storage. This keeps profile renames
consistent across the product and avoids a new stale-name migration. While a
cold profile read is settling, the screen uses the neutral `Planner` label and
continues ringing instead of blocking the alarm UI.

---

## Device-pass corrections: only a decision moves a plan to History (2026-09-25)

Directed by the user after installing the post-Item-35 debug build on the Redmi.
Five fixes; the first two **supersede parts of the 2026-09-24 entries above**.

**1. History holds decided plans only.** The 2026-09-24 partition moved an
approved plan to History as soon as its instant passed. An alarm dismissed with
the power button therefore landed in Past Plans with no outcome and no Done/Skip
controls anywhere. The partition is now `outcome != null → History`, otherwise
My Schedule, whatever the clock says. An undecided plan cannot linger forever:
the existing end-of-day lapse settles it (`Skipped: Did not respond`) at its own
local midnight. Calendar routing follows the same rule.

**2. A one-minute timeout records the fact, not an outcome.** This reverses the
Item 20 default kept by "Missed-alarm review separates availability from
completion". The timeout now writes only the immutable `alarm.unavailableAt`;
the task stays undecided in My Schedule, where the card shows `User unavailable
at alarm time` above Done/Skip. The review popup is unchanged in shape (two
actions) but now makes the first outcome write itself — Done is an ordinary
first-write Done (still rendered `Done (Late)` from the fact), Skip records
`Skipped: User unavailable`. The planner is told when the person decides (or at
the lapse), no longer at the one-minute mark — the user accepted that cost. A
Done/Skip on the card or on another device closes the review. No rules change:
recording the fact alone was already permitted, and the rules-level
Skip(User unavailable) → Done correction stays for legacy rows written by
earlier builds, which are still offered for review. The now-unused
`replaceAutomaticSkipIfMatches` (Did not respond → User unavailable refinement)
was removed from the client; its rules branch is left in place, harmlessly.
`markSkippedIfUnsettled` stamps `alarm.unavailableAt` only when absent, so it
can never trip the rules' immutability check.

**3. The plan builder collapses its person list after a pick** to one row with a
Change button, and jumps to the top, so the planning fields need no scrolling.
A pre-selected target (voice flow) opens collapsed.

**4. The Log Time pop-up after Done is removed**, with its now-dead
`log_from_done_prompt.dart`. Time is still logged from Track; existing entries
that carry `sourceItemId` are untouched.

**5. The celebration starts on save.** The burst used to wait for the Done
transaction AND for Firestore to echo the celebration document back. The device
that committed the Done now enqueues the event locally the moment its
transaction succeeds (`committedCelebrationProvider`); the echo shares the id
and is de-duplicated, and acknowledgement is unchanged. The user chose "on save"
over "on tap" so a Done that loses a race never celebrates. The host also
requests a frame when an event arrives, because a post-frame callback on an idle
screen otherwise waits for an unrelated repaint.

---

## Second device pass: stale rules, alarm sentence, ting→ring order (2026-09-25)

**Root cause of the still-missing "User unavailable" tag: the live Firestore
rules were three days stale.** Fetched read-only from the Rules API, the live
ruleset (`fe6c9239-…`, released 2026-09-23 11:42Z) is byte-identical to commit
`01ff2b5` and contains no `unavailableAt`, so every write of it was rejected.
The same staleness denies the Item 27 planner schedule read (the conflict check
then queues an error dialog right after the date pick), Item 23 plan requests
and Item 22 pictures. No test can observe a deploy, so
`scripts/check-deployed-rules.sh` now compares live vs local and names the
commit the live rules match. Run it before any rules-dependent device test.
The "defer all deploys to the release gate" plan is what let device testing run
against code the server did not accept; deploy rules before device passes.

**Not regressions, recorded so they are not re-diagnosed:** the Activity card
still opens its timeline (covered by `planner_activity_name_test`); My
Schedule/History cards never had one — they now open the same sheet. Calendar's
"Open in Activity" only ever switched tabs (since at least 38929e5); it now
reveals and outlines the item like My Schedule.

**Alarm copy is one sentence** — `alarmHeadline()`: "{planner} planned {task} for
you", "You planned Walk" for a self-plan, "Someone …" while a name is unknown,
never a uid. It is the reminder request's title, so it rides the existing
fingerprint (a name arriving re-arms once) and is passed to the native alarm
with the arm call (and kept through reboot re-arming). The native side uses it
for (a) the unlocked heads-up — Android shows a full-screen intent only when
locked, and the user chose a rich heads-up over the "display over other apps"
permission — (b) the new missed-alarm notification posted at the one-minute
auto-stop (works with the app dead; tap opens the app, whose review offers
Done/Skip), and (c) AlarmScreen's first frames, which show that delivered
sentence or nothing — never a "Reminder"/"Planner" placeholder.

**Ting then ring, always.** The "ting" was the app-start splash strike, played
only when the alarm happened to cold-start the activity, racing the ringtone
the native service had already started. The service now owns both: it plays the
strike on the alarm stream and starts the ringtone exactly
`TING_LEAD_MS` (1.5 s, the strike's faded length) later. The splash strike is
suppressed while an alarm rings, and an alarm cold start opens Flutter directly
on `/alarm?item=` via `getInitialRoute` (read as `defaultRouteName`), skipping
the reveal so nothing flashes before the alarm screen.

**Also:** PLAN moved bottom-left (it covered the last card's Done); person rows
show "Loading…" instead of a uid, and planning-target profiles are prefetched
from sign-in so Plan opens with names. Remaining planning-flow lag is judged on
a **profile** build (debug is JIT and janky by design); a profile APK shares the
debug signature, so `adb install -r` keeps app data.

---

## Third device pass: "Updating {planner}…", instant popup, one notification (2026-09-25)

- **Missed-alarm popup no longer waits on Firestore.** The review is published
  first; the `alarm.unavailableAt` transaction runs in the background (it is a
  server round trip and impossible offline, and waiting on it was the reported
  multi-second delay). A Done/Skip chosen before it lands persists it first, so
  "Done (Late)" still holds. Paths that drop the native row still await it. The
  only remaining wait is the ~1.5 s cold-start reveal, which deliberately sits
  above the popup. **Preserved on request:** an unanswered popup re-appears on
  every launch until Done/Skip (durable native row; pinned by a test).
- **"Updating {planner}…" for 1.5 s** after Done or Skip (card and popup),
  then the celebration (Done only). It is a non-dismissible dialog on the card
  path because the card leaves My Schedule the moment the outcome lands. The
  planner push runs inside that window, fire-and-forget. Self-plans read
  "Updating your schedule…"; an unloaded name "Updating your planner…".
- **The "permanently recorded" line is removed** from the popup.
- **One notification per ringing alarm.** When the native service starts it
  cancels the scheduled reminder notification (same id) directly on the
  NotificationManager — at once and at 0.5/2/5 s, since the two OS alarms land
  in either order. If native delivery never runs, the scheduled one remains as
  the fallback.
- **No personal names in the codebase.** Examples use `{planner}`/`{task}`;
  test fixtures use role names (`Test Planner`, `TARGET`/`PLANNER`/`OUTSIDER`).

## Planner notifications: named, timed, group-labelled, shown in foreground (2026-09-26)

In-person device check found planners mostly receiving nothing. Causes, in order:

- **The live Worker was a week stale** (`1a4d5663`, 2026-09-19). Its item-event
  guard rejected `groupId: ''`, so **every friendship-plan push was dropped** as
  `item-missing-fields`. Redeployed as `8229568f` (2026-09-26). Lesson, same as
  the rules one: code-complete ≠ deployed; check `wrangler deployments list`
  before a device pass that depends on the Worker.
- **The app hid foreground pushes.** A Done was dropped in favour of the
  celebration; everything else was a 6 s snackbar. Now every foreground push is
  a real system notification on a new `planner_activity` channel ("Activity from
  your people"), which the Worker also names for background delivery. It is
  NOT a reminder channel, so muting activity never mutes alarms. The Done
  celebration still plays alongside (separate host, de-duplicated by id). If the
  notification cannot be shown (disabled), non-Done events fall back to the
  snackbar; Done keeps only the celebration.
- **Taps share the plugin's single callback.** Foreground-push payloads are
  `push:` + JSON and are routed through `openForPushEvent`; a bare payload is
  still a reminder item id and opens the alarm route. Cold-start taps decode the
  same way.

Copy (Worker, `buildMessage`), all names read from Firestore, never the request:
- Done: "{name} completed the task: {task}"; Skip: "{name} skipped task: {task}".
- Early (outcome timestamp < scheduled instant): "{name} completed Task: {task}
  before time" / "{name} skipped Task: {task} before time". Late (missed alarm
  answered Done) wins over early.
- `{name}` is the ACTOR: the target for decided/outcome, the planner for
  created/withdrawn. Missing profile → "Someone".
- Group plans: titles say "Group plan"/"Group task" and bodies end "in {group}"
  for every event, normal and emergency; a group with no name is still labelled.
- Item and friend pushes are sent at FCM `priority: high` (user-visible; normal
  priority is batched under Doze).

"Skipped shown for a completed task" was not reproducible from code — both old
and new copy branch on the Firestore `outcome.result`. A test now pins that done
copy never mentions skipping and vice versa. Re-check on device after deploy.

## Dismiss and group-join pushes — no rules change needed (2026-09-26)

Batch B was expected to need a rules deploy; it does not.

- **Dismiss → planner.** `alarm.dismissedAt` was already written by both
  dismiss paths (AlarmScreen, and the native lifecycle row the missed-alarm
  service replays) and already allowed by the rules. New item event
  `dismissed` (target-triggered, notifies the planner): the Worker requires
  `item.alarm.dismissedAt`, dedups on its own `notifiedDismissed` flag (never
  shared with the outcome flag), and skips self-plans. Copy: "{name} dismissed
  the alarm for {task}", "Group alarm dismissed" for group plans.
  **One hook:** `DismissNotifyingTimelineRepository` wraps
  `AlarmTimelineRepository.recordDismissed` at the provider, so both paths are
  covered and the push only follows a durable write. Do not add a second
  notify in AlarmScreen or the missed-alarm service.
- **Group join approved → candidate.** New friend-family event
  `groupJoinApproved` (`fromUid` = approving member, `toUid` = candidate,
  `groupId`). `decideJoinRequest`/`inviteFriend` now return whether THIS call
  admitted the candidate; only that caller fires it. The Worker requires the
  caller on the roster, the request `approved`, the candidate on the roster,
  and stamps `notifiedApproved` on the join request (client key whitelists
  exclude it, and a decided request accepts no client update). Copy: code
  request "Your request to join {group} was approved"; friend invitation
  "Added to a group / You're now a member of {group}". Tap opens the group.
- The approver's snackbar now says "{name} joined the group." when their
  approval (or a one-member-group invite) admitted the candidate.

## Pending-approvals badge moves to its icon, which glows (2026-09-26)

Device report: a plan needing approval put "1" on the **My Schedule tab
label**, where there was nothing to act on. The embedded Plan shell badged the
tab with `planAttentionCountProvider`; the Pending approvals app-bar icon (the
one that opens the queue) had no badge. (The un-embedded OutcomeScreen app bar
did badge the icon, which is why it looked right in code.)

- **The count lives on the Pending approvals icon**, with the real number, via
  the one `PendingCountBadge`. The tab label carries no badge. The Plan
  bottom-bar pillar keeps its badge — same provider, so the two cannot differ.
- **New token/recipe: the attention glow** (UI-RULES §6.2a). A soft halo in
  the `attention` line role behind the icon while ≥1 plan is pending; gone when
  the last is decided. Light `#B4400C` at 45% alpha, dark `#F0A56E` at 60% (the
  dark ground needs more to read), blur `Sizes.attentionGlowBlur` 14, spread
  `Sizes.attentionGlowSpread` 1. **Static, not pulsing** — a repeating
  animation spends calm (§4 Motion) and never settles in widget tests; a
  static halo needs no reduced-motion branch.
- **Contrast:** the glow is supplementary, never the only signal — the count
  badge (`onAttentionContainer` on `attentionContainerStrong`, 7.08:1 light /
  4.55:1 dark, §7) and the tooltip ("Pending approvals, N waiting") carry the
  meaning. The icon's own contrast is unchanged because the halo sits behind
  it.
- **Firewall (§2.7):** the halo is the `attention` role (line/text), not an
  `attention*Container` fill, and lives in `status_style.dart` beside the badge
  — attention state is owned there. It is a shadow, so §5 lists it as an
  explicit exception to "flat by default".

## Approval reminders — server-side Worker cron (2026-09-26, user chose option A)

While a plan someone made for you stays `pending`, the Worker reminds you:
"Task: {task} planned by {planner} is waiting for your approval." (group:
"Group task: {task} planned by {planner} in {group} is waiting…"). The final
slot's title is "Due soon: waiting for your approval". Tap → Pending approvals.

**Timing** (`approvalReminderTimes`, W = due − `createdAt`, falling back to the
document create time): W < 10 min → one at W/2; 10 min ≤ W < 2 h → W/2 and a
final at due − clamp(W/10, 3, 10 min); W ≥ 2 h → W/2, due − 1 h, due − 10 min.
At most 3; the final is always kept; others closer than 2 min to the next are
dropped (so exactly 2 h gives two). Absolute UTC instants — DST cannot shift
them. If the Worker misses several slots it sends only the latest, never a
burst.

**Why server-side:** the user's rule is "stop immediately once decided". Each
reminder is claimed with a conditional write (`approvalRemindersSent`,
`approvalRemindedAt`) against the item's `updateTime` from the query, so any
approve/reject/withdraw — on any device — makes the claim fail and nothing is
sent. No phone-side scheduling or cancel path exists to go stale. Residual: a
decision landing in the sub-second between claim and FCM send can still let
that one reminder out.

**Mechanics:** a second cron, `* * * * *` (wrangler.toml; `cronJobFor` routes by
cron string; `*/5` stays inactivity-only). Collection-group query on `items`
(`status == pending`, `scheduledInstantUtc > now`, soonest first, limit 50) —
**needs the new composite index in `firestore.indexes.json`; deploy indexes
before the Worker.** Revoked grant → no reminder (shared `itemGrantPath`).
Self-plans never remind. At most 6 reminders per run (≈6 subrequests each;
Cloudflare free plan allows 50/invocation); the rest go next minute.

**Rules:** no change. `approvalRemindersSent`/`approvalRemindedAt`/
`notifiedDismissed` are in no client whitelist, so only the service account
writes them; item updates compare `changedKeys()`, so their presence never
blocks approve/reject/withdraw/outcome — both pinned in
`adversarial_schedule_matrix.test.mjs`. Scale limit to revisit: >50 pending
future items across all users means later ones wait until earlier ones clear.

## Batch C: startup sound, tab gutter, push taps keep the startup screen (2026-09-26)

- **Push taps now show the startup screen (supersedes "a notification launch
  bypasses the reveal").** Device report: tapping the six-hour inactivity push
  played the startup ting but showed no startup screen. Cause: a push launch is
  only known when `getInitialMessage()` resolves — after the reveal mounted
  and its ting fired — and the old code then tore the reveal down. Now only an
  ALARM launch (full-screen alarm route, or a tapped local reminder whose
  payload is a bare item id) skips it (`launchSkipsReveal`); every push tap
  plays the full 1.5 s reveal and lands on its destination beneath. Applies to
  all pushes, not just inactivity, since every push cold start had the same
  ting-without-screen defect.
- **Startup sound toggle.** You → Edit profile → This device → "Startup
  sound". Device-local `shared_preferences` (`startup_sound_enabled`, default
  ON), read in `main()` before `runApp` like the app lock, because the strike
  plays on the first frame. Off = the reveal plays silently. It is read ONLY
  by the splash; alarm audio (`AlarmSoundService`) never consults it (pinned by
  a test that lists every reader). New icon `AppIcons.startupSound`.
- **Tab gutter token `Space.tabBodyInset`** = symmetric horizontal `Space.sm`
  (8), applied once by `TabBodyInset` around the four main-tab bodies (Plan's
  sub-tab view, Track, Stats, You). Symmetric so cards stay centred; app bars
  and the bottom bar are outside it. Small by request ("not drastic").
- **Inactivity delivery audit.** Findings: (1) the cron was never deployed
  until Worker `8229568f` (2026-09-26), so nobody had received it before
  today; (2) one user's failure threw out of the whole run, starving everyone
  after them — now isolated per user; (3) no per-run cap against Cloudflare's
  50-subrequest free-plan limit (~7-8 per user) — now 5 users per 5-minute
  run, soonest-due first, the rest next run; (4) sent at normal FCM priority,
  which Doze can hold for hours — now `priority: high`; (5) it had no channel
  — now its own `app_nudges` channel ("Reminders to plan"), separate from
  planner activity so nudges can be muted alone. Not changed: nudges still
  fire at night (quiet-hours enforcement is parked), and a user who never
  granted notifications cannot receive it (the primer is the repair path).

## Batch D decisions — four explorations settled (2026-09-26)

All four took the recommended option; they are build Batch E (handoff.md
items 14–17).

- **Emergency notification → distinct channel + labels.** An "Emergency
  plans" channel (max importance, its own sound/vibration) for the immediate
  alert, and "Emergency" in the copy of every push about an emergency item.
  Not chosen: DND bypass (needs notification-policy access, another
  onboarding step); labels only.
- **Group emergency plan → per-person grants only.** No new consent type:
  fan out only to members whose FRIENDSHIP emergency grant the planner holds,
  and say who was skipped. Found while exploring: the emergency create rule
  does not constrain `groupId`, and the Worker's `itemGrantPath` checks the
  group's `plannerGrants` whenever `groupId` is set — so a group-tagged
  emergency item's pushes would be refused today. Both are fixed as part of
  item 15. Not chosen: a group-level emergency grant; mixing emergency and
  normal in one fan-out.
- **Pending-approvals notification → tell the planner too.** B2 covers the
  target. Add one planner heads-up when the final reminder goes out and the
  plan is still pending. Not chosen: also notifying at the end-of-day lapse.
- **WhatsApp invite → real tap-to-open link**, served by the Worker (landing
  page + `assetlinks.json`) with Android App Links, carrying the existing
  username or join code — no new collection. Not chosen: share text only;
  single-use tokens (new collection, rules, cleanup).

## Planner in-app outcome pop-up (2026-09-26, item 18)

While the planner is in the app, a Done shows confetti PLUS a pop-up —
"Your planning skills are amazing!" / "{name} completed task: {task}" — and a
Skip shows the same pop-up shape without confetti: "Plan skipped" / "{name}
skipped task: {task}". Only the planner of someone else's item sees it; the
target keeps "Updating {planner}…" and their own confetti.

- **Driven by the durable Firestore record, not the push.** The existing
  `completionCelebrations` queue (seen-once per participant, survives offline)
  now carries `result`. Done keeps its id `{t}_{i}` and both parties; a Skip
  writes `{t}_{i}_skipped` with the planner as the only participant, in the
  same transaction as the person's own Skip (card or missed-alarm review).
  Separate ids because the missed-alarm "Skip → Done" correction must still
  be able to CREATE the Done record (an existing doc only accepts
  `seenByUids` updates). Automatic lapses write no record — the Worker
  announces those (item 20).
- **Rules** (deploy before install): create now allows `result`; a skip record
  requires the `_skipped` id, planner-only audience, planner ≠ target, a
  first-write Skip in the same write. Old clients' Done records (no
  `result`) still validate.
- **One announcement, not two:** in the foreground, Done/Skipped pushes are no
  longer posted as system notifications (`isAnnouncedInApp`); the pop-up is
  the announcement. Every other push is still posted. Outside the app the
  Batch A push is unchanged.
- The host finishes (and acknowledges) an event only when the confetti has
  ended AND the pop-up was dismissed (button or tap outside). Events queue
  one at a time.
- Known gap: a target on a pre-2026-09-26 build writes no skip record, so an
  in-app planner sees no pop-up for that Skip (and no system notification).

## Two-hour minimum response window (2026-09-26, item 19)

The lapse deadline is now `responseDeadlineUtc` = the LATER of the end of the
item's own local day (unchanged) and scheduled time + `kMinResponseWindow`
(2 h). Only items scheduled after 22:00 local are affected: a 23:50 task now
lapses at 01:50, not after ten minutes. It is absolute time (two real hours
across DST nights) and applies to BOTH lapses — pending → Rejected "Not
approved in time" and approved → Skipped "Did not respond" — so there is one
deadline. `endOfScheduledLocalDayUtc` is unchanged and still the midnight part.
The Worker lapse (item 20) must implement the same rule.

## Server-side lapse + auto-skip notifications (2026-09-26, item 20)

The Worker now settles unanswered items at their response deadline, so a
target who never opens the app is still settled — and both people are told.
The client `ItemLapseReconciler` stays as an idempotent fallback.

- **Cron `*/2 * * * *`** (`settleLapsedItems`, `worker/src/lapse.js`), its own
  invocation and subrequest budget. Two collection-group queries on the
  existing `status + scheduledInstantUtc` index: pending and approved items
  scheduled between 50 h and 2 h ago; each item's exact deadline is then
  computed in JS.
- **Deadline parity is tested, not assumed.** `lapse.js` reimplements
  `responseDeadlineUtc` with `Intl` time zones; both it and the Dart rule must
  reproduce every case in `test/fixtures/response_deadlines.json` (DST
  spring/fall days and nights, a quarter-hour zone, UTC+12, an unknown zone,
  month/year ends).
- **Claim = the write.** The outcome (`skipped`, "Did not respond",
  `skippedAt`) plus `lapsedByServerAt` is written only if the item's
  `updateTime` is unchanged since the query — a Done/Skip or the client's own
  lapse in between wins and nothing is sent. Pending items are rejected "Not
  approved in time" the same way, silently (as before).
- **Notifications (skip only):** the person — "{task}, planned by {planner},
  was marked Skipped because you didn't respond in time." (self-plan: no
  planner); the planner — "{name} didn't respond to {task}, so it was marked
  Skipped." Titles "Task / Group task / Emergency task skipped automatically";
  groups add "in {group}". No clock time (decided: overkill). A revoked grant
  still settles the item and tells the person, but not the planner. Taps: the
  person → History, the planner → Plan activity. Posted as a normal
  notification in the foreground (no pop-up record for lapses).
- Budget: at most 3 skips and 10 rejects per run; the rest wait 2 minutes.
  Known gap: sends are not retried if every device send fails — the lapse
  itself is not repeated, so the notification is lost.
- `lapsedByServerAt` is Worker-only (no client whitelist); pinned in the
  adversarial rules matrix.

## Group emergency plans — per-person grants only (2026-09-26, item 15)

"Plan for the group" gains an **Emergency** switch whenever the planner holds
at least one other member's FRIENDSHIP emergency grant. There is still no
group-level emergency permission.

- **Who it reaches** (`groupPlanRecipients`, pure + unit-tested): the planner
  (own copy) plus every member who gave the planner emergency permission —
  including members with no normal grant. Members the planner can normally
  plan for but who gave no emergency permission are listed on the sheet
  ("Won't reach {names} — no emergency permission.") and counted as skipped.
  Never silently downgraded to a normal plan.
- **Each copy** is born `approved`, `tier: emergency`, `groupId` = the group
  (self copy: no group, as before), so it rings without approval exactly like
  a friendship emergency.
- **Rules fix (deploy first):** the emergency create branch now requires the
  group tag to be honest — `groupId == ''` or a group BOTH parties belong to.
  Before, any `groupId` string was accepted.
- **Worker fix:** `itemGrantPath` sends every `tier: emergency` item to the
  friendship `emergencyGrants`, even with a `groupId`. Before, a group-tagged
  emergency was checked against the group's normal `plannerGrants`, so its
  pushes (including the data push that arms the alarm on a killed app) would
  be refused — or wrongly allowed by a normal grant. The lapse and reminder
  crons inherit the fix.

## Emergency notification — its own channel + "Emergency" labels (2026-09-26, item 14)

- **"Emergency plans" channel** (`time_app_emergency_plans`): max importance,
  the system alarm tone as its sound, a distinct urgent vibration. Used ONLY
  for the immediate alert when someone places an emergency plan for you — from
  the killed-app handler (`showEmergencyPlanAlert`) and the foreground
  presenter, which share one channel definition. No DND bypass (decided). The
  alarm itself still rings at the due time on the reminder channel, unchanged.
- Replaces `time_app_received_plans` ("Plans from friends"), which only ever
  carried this alert; it is deleted on start (channel settings are frozen, so
  a new id was required).
- The alert is now tappable and opens My Schedule on that item (an emergency
  is born approved, so the approval queue — where a normal "new plan" push
  goes — would show nothing).
- **Labels:** every Worker push about an emergency item leads with
  "Emergency", then "group" for group plans — "New emergency group plan for
  you", "Emergency plan withdrawn", "Emergency task completed early",
  "Emergency alarm dismissed". Normal items never say it (tested).

## Planner heads-up for a still-pending plan (2026-09-26, item 16)

When the FINAL approval reminder goes out (B2 cron) and the plan is still
pending, the planner gets one push: "Still waiting for approval" / "{name}
hasn't approved {task} yet. It's due soon." (group: "Group plan still waiting
for approval", "… {task} in {group} yet …"). No clock time (same decision as
item 20). Tap → Plan activity.

- It rides the final slot's conditional claim, so it can never repeat, and a
  decision racing that claim stops it along with the reminder. A revoked grant
  stops both. For a one-reminder window (under 10 minutes) the only reminder
  is the final one, so the heads-up comes at the halfway point.
- Lapse at the deadline stays silent to the planner for pending plans (item
  16's original decision); only an approved item that lapses notifies them
  (item 20).
- Budget: `MAX_REMINDERS_PER_RUN` lowered 6 → 5, since a final reminder now
  costs ~9 subrequests.

## Tap-to-open invite links (2026-09-26, item 17)

- **Links:** `https://time-app-notify.timeapp.workers.dev/i/u/{username}` (add
  a friend) and `/i/g/{joinCode}` (ask to join a group). They carry only an
  existing username or join code — no new collection, nothing secret (a code
  still admits nobody without every member's approval).
- **Worker** (`invite.js`): serves `/.well-known/assetlinks.json` (package
  `com.timeapp.time_app`, fingerprints from the public `APP_CERT_SHA256` var —
  debug key now; the RELEASE key must be appended before release builds verify)
  and a tiny fallback page for anyone without the app: strict CSP, no script,
  values validated then escaped, an `intent://` "Open in Checkmate" button,
  and a "Get Checkmate" button only if `APP_DOWNLOAD_URL` is set (empty today:
  the page says to ask the sender). Malformed or hostile paths get a plain 404.
  Invite GETs are routed before every other route; the push root stays
  POST-only.
- **App:** a verified `autoVerify` intent filter for that host and `/i/` only,
  plus `flutter_deeplinking_enabled`. go_router never shows an `/i/` screen:
  the redirect PARKS the invite (`pendingInviteProvider`) and continues to
  home or sign-in; `PendingInviteListener` inside HomeShell (past sign-in,
  profile setup and permissions) acts once — a friend invite opens that
  person's profile (Add friend is there), a group invite opens the join dialog
  with the code prefilled. A link never sends anything by itself; your own
  link and an unknown username say so.
- **Share:** group Share now sends the link plus the typeable code; Friends
  gains an "Invite a friend" share action with your username link.
- **Parser parity is tested:** `test/fixtures/invite_paths.json` is parsed by
  both the Dart and the Worker parser, which must agree (case folding, length
  bounds, code alphabet, encoded/hostile input). One known difference: the app
  also rejects reserved usernames; the Worker page shows them, harmlessly (no
  one can hold one).
