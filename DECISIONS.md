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

# Alarm persistence across reboot — HARD REQUIREMENT (not an optimisation)

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
