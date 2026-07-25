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
- **We do NOT need `USE_EXACT_ALARM`** and do not have to qualify under Google Play's
  alarm-clock/calendar exemption. (That restriction was the thing that looked like it
  might make an *alarm* premise unshippable — see the 2026-07-23 notifications
  diagnosis. As a *reminder* app the question is moot.)
- **We do NOT need `SCHEDULE_EXACT_ALARM`** either (the user-granted exact-alarm
  flow). Inexact scheduling is sufficient — see the reminder-layer write-up below.
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
