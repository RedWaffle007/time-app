# CLAUDE.md

## What this is

**time-app** — a cross-platform (Android + iOS) Flutter accountability app: trusted people build your timetable and set alarms on your device **with your consent**.

## Source of truth

- **`mvp-spec.md` is the source of truth for what to build.** Read it before implementing anything.
- **`feature-ideas.md` is the parked backlog and is NOT part of this build.** Do not implement from it.
  - **One exception, explicitly directed by the user on 2026-07-25: goal / effort
    tracking is UNPARKED** and is queued build item 3 below. Its "Decided (not open
    questions)" block in feature-ideas.md is binding. Nothing else in that file is
    unparked by this — the rule still holds for every other entry.

## The core loop (everything in v1 serves this)

> A creates a group → invites B → B builds A's timetable (in A's local timezone) → A approves each item → alarms fire → A completes/skips → B is notified.

If a feature doesn't serve this loop, it's parked.

**Completion/skip → notify planner is non-negotiable** — it's what closes the accountability loop; it ships, it does not get cut.

## Status — where we actually are (as of 2026-07-25)

**The non-alarm core loop is CODE-COMPLETE.** Every screen in the loop above is
built: groups + invites, planner-grant consent, schedule builder (in the target's
tz), per-item pending queue + approve/reject, done/skip outcomes, and the
completion→planner push (client-triggered Cloudflare Worker transport — see
DECISIONS.md "Completion→planner push"). Surrounding correctness work is done too:
Firestore security rules v1, DST gap/overlap resolution, locale-aware date/time
formatting, quiet-hours *warnings*, and self-planning. **There is no missing
non-alarm feature.** Next session is **real-pair validation**, not more building.

**Code-complete ≠ verified.** Several things are built/deployed but never exercised
end-to-end, and some are parked. The single durable list is **"Parked & unverified"
below** — treat nothing there as done until its run is recorded.

**Standing worldwide requirement (do not regress):** this app is worldwide. All
user-facing date/time rendering goes through the ONE helper
(`core/format/datetime_format.dart`), honoring the device locale and its 12h/24h
setting; `supportedLocales` accepts every Material-supported locale. Any new
time/date UI must use that helper — never hardcode a format, English month/day
names, or 24h. (Details: DECISIONS.md "Locale-aware date/time display.")

**Standing UI requirement (do not regress):** all UI conforms to
[UI-RULES.md](UI-RULES.md) — the design system's source of truth (palette, type,
spacing, radius, elevation, component recipes, accessibility floor). **Read it
before writing any screen code.** Every visual value comes from
`lib/core/theme/`; raw `Colors.*`, inline `fontSize`, and literal
spacing/radius/elevation are banned in screens and mechanically blocked by
`test/ui_rules_lint_test.dart`. Changing a token requires a DECISIONS.md entry
first, then UI-RULES.md, then the code — never the reverse.

## Parked & unverified — the durable checklist (nothing gets lost between sessions)

Keep this current. Do not mark an item done until its run/decision is recorded here
or in DECISIONS.md.

**VERIFIED 2026-07-24 — do not re-open these** (DECISIONS.md, 2026-07-24 entries):
- **Rules Test 2 — on-device happy path. PASSED.** Run with a real second person on
  a real device: group → join → grant → planner creates item → target approves →
  marks Done → planner receives the outcome.
- **Worker transport + `kNotifyEndpoint`. LIVE AND CORRECT.** A real outcome write
  triggered a real push (`sent:1`). The Worker was never the problem.
- **Firestore rules deployed**, replacing a ruleset that had been six days stale
  — which is the lesson worth keeping, not the id. Both the `fcmTokens` block and
  the item-create `status` constraint were confirmed present in the *deployed*
  source. Ids in DECISIONS.md (2026-07-24).
- **Token registration.** `users/{uid}/fcmTokens` now populated for both accounts —
  the first tokens ever written in this project.
- **FOREGROUND push delivery.** Worker → FCM → device → in-app banner, rendered with
  the View action while the recipient was foregrounded. The `c3b921e` banner fix
  works. The "unverified delivery path" caveat is retired.

**ALSO SHIPPED 2026-07-24 (later) — do not re-open as "queued"**
(DECISIONS.md 2026-07-24 "Group A SHIPPED" + "status stamp"):
- **`_registeredUid` latch fix. SHIPPED** (`41f7182`). All four parts landed: the
  latch is set only after a successful token write, `requestPermission` moved
  inside the `try`, a 15s timeout on both FCM calls, and retry on
  resume/auth-change with a 30s cooldown plus a user-visible `failed` status. The
  write-once schema is confirmed live on-device (`createdAt` frozen,
  `lastRegisteredAt` advancing).
- **Group A — event-discriminated push endpoint. SHIPPED + DEPLOYED**
  (`8f103e6`, `95fe62c`). Four events (created / withdrawn / decided / outcome),
  authz **branched by event**, recipient computed structurally, per-event dedup in
  FLAT fields. Worker deployed on the `{event}` contract; a negative probe with an
  old-shape `{outcome}` body returns 400, proving the new contract is live.
- **Group C — planner withdraw. SHIPPED + DEPLOYED** (same commits). The withdraw
  branch was confirmed in the *deployed* source, and the earlier fcmTokens +
  item-create `status` blocks did not regress. **Two later deploys have replaced
  that ruleset; the live id is stated in ONE place in this file — under "Leave /
  remove / stop-planning" below.** The superseded ids and the §6/§6.1 hardening
  are in DECISIONS.md ("Security hardening DEPLOYED (2026-08-10)").
- **Design system + UI-RULES.md. SHIPPED** (`c43a4a3` → `c87012b`). Tokens, the
  one status mapping, the lint, the structure/state/temperature doctrine and the
  filled-vs-line firewall. Colour is **committed and closed** — see the standing UI
  requirement above.

**VERIFIED 2026-08-15 — Session 3 routing refactor (D2 + D11). Do not re-open the
routing itself.** The three tabs are branches of a `StatefulShellRoute` and each
tab's detail screens are sub-routes of their branch. The device pass on the Redmi
(HyperOS, Android 16, debug) cleared sections **A, B and D** of the "Session 3
manual device checklist" — tabs, tab-state persistence, pushed detail routes with
working back arrows, nested routes, and all six dev-menu destinations. The
notification dead end is closed as far as navigation goes. (DECISIONS.md "Session
3 device pass (2026-08-15)".)

**Still open from that pass, and NOT to be counted as done:**
- **Section C — the four notification events — NOT RUN.** Needs a second device
  holding a live FCM token; folded into the notification retest below. The
  `wrangler tail` no-delivery is the expected no-tokens state after the
  stale-token cleanup, not a Worker or key fault.
- **Section E — only E1/E2 run** (sign out; sign in as a different account).
  E3–E5 not run.
- **Routing still has zero automated coverage.** The pass was by hand; the next
  refactor gets no warning from the suite.
- **Five defects surfaced by the pass**, all pre-existing, none a regression from
  the refactor: tab-root Back exiting the app silently; the archive-undo snackbar
  outliving sign-out *and* an account switch (a stale `Undo` closure writes to the
  previous account); Edit Profile discarding silently on Back with no server-side
  name validation; over-long archive copy; and a cancelled sign-in rendering a raw
  exception in red **in release, not just debug**. Diagnosis and decisions are in
  DECISIONS.md "Session 3 device pass (2026-08-15)".

**Group A/C four-event foreground retest — BLOCKED on the friend.** All four events
require creator != target, so none can be tested on one account (self-planned items
are skipped by the self-planned guard). Expect `sent:1` per event with
`wrangler tail` running: created / decided / outcome / withdrawn. Foreground only —
passing it does NOT close item 1.

1. **BACKGROUNDED / killed-app delivery. PARTLY ANSWERED 2026-08-22 — and the
   answer is that it FAILS.** (DECISIONS.md → "Killed-app alarm delivery —
   OneKeyClean answers open item 1".) On the Redmi, HyperOS Security's
   **"Boost speed" (`OneKeyClean`) killed the app and every armed alarm went with
   it** — `am_kill` at 00:29:34, both alarms `pi_cancelled` 36s later, zero
   pending alarms afterwards, no error surfaced anywhere. The 07:00 reminder came
   back **only** because the app was reopened by hand. The item-stream reconciler
   worked exactly as designed; it just needs a process to run in.
   **Mitigation applied and verified in `dumpsys`** (Autostart `allow`, Doze
   whitelist, standby bucket 10 → **5 EXEMPTED**) — but **whether the mitigation
   actually holds is UNTESTED**: no second Boost has run since. This still says
   nothing about FCM system-tray delivery to a killed app, which remains
   unproven. The primer's real target is now known to be **the user's own cleaner
   app**, not Doze — `flags=0x5` already handles Doze.
2. **Rules Test 3 — grant-off negative test.** With the planner grant revoked,
   confirm B's item-create is rejected `PERMISSION_DENIED`. Never run.
3. **Real two-timezone loop (build step 5g).** A genuine two-people/two-devices run
   across a **DST-observing** timezone pair (the early Chicago↔Kolkata check was
   neither a real pair nor DST-observing, so the gap/overlap rule is unverified live).
4. **iOS locale check.** Whether `CFBundleLocalizations` actually makes iOS report
   the user's language and render local digits — **blocked: no iOS target is wired
   up yet.** (DECISIONS.md, 2026-07-22.)

**Leave / remove / stop-planning — BUILT + RULES DEPLOYED AND VERIFIED
2026-08-20.** **THE live ruleset is `33468095-920e-4b5d-a8ae-e1e3b611e4b1`**
(deployed 2026-08-24, superseding `56e11d6d` and every earlier id; verified the
same way — deployed source re-fetched and diffed byte-for-byte). It is the only
ruleset id in this file, and every earlier one is superseded. This live ruleset
carries the slot-lock + planner-access rules (see "View B's schedule modal"
below) AND the 2026-08-24 cross-device fixes: the slot-lock create now gates on
`callerHasActiveGrant` (not the plannerAccess mirror), and `friendRequests`
`allow delete: if isParty()` (decline/withdraw now delete). See DECISIONS.md
"Cross-device relationship + planning denials" and "Friend-request reactivity +
lifecycle". Verification was the real one, not a
ruleset id alone: the *deployed source* was fetched back from
`firebaserules.googleapis.com` and diffed byte-for-byte against `firestore.rules`
— identical (bar a trailing EOF newline the API round-trip adds). **Still
UNVERIFIED ON A DEVICE:** no leave, remove or stop-planning has actually been run
against the live rules, and the installed build predates the feature.

These are the first relationship-*ending* controls in the app (DECISIONS.md →
"Ending a relationship"). Three narrow rules changes — member removal on `/groups`,
`members` delete, and a planner-may-relinquish branch on `plannerGrants` — plus
`removeMember()` / `revokeMyPlannerGrant()` and the group-detail overflow menus.
Two facts not to rediscover: **the owner cannot leave their own group** (an ownerless group
would be uncleanable under `delete: if false`), and ejecting a member leaves that
member's grants with *third parties* stale-but-inert.

**Queued build work (agreed order, 2026-07-25 feature-planning pass — not started).**
One feature at a time, plan → sign-off → build. Most strictly for goals.
1. **Icon system (ii)+(iii).** (ii) Codify icon usage the way `status_style.dart`
   codified colour — one `app_icons.dart` vocabulary, a UI-RULES section, a
   mechanical lint. Icons are currently ad hoc across screens and
   outlined-vs-filled is inconsistent outside the nav bar. (iii) Launcher +
   **notification small icon** — the white-on-transparent tray icon is missing, so
   Android falls back to the launcher icon and renders a blob. This is a real
   defect in already-shipped push. **First** because archive introduces new icons
   and the vocabulary should be settled before they land.
2. **Archive + app lock — one feature, the privacy story.** Archive = Group D's
   per-user, UI-only soft-archive of **settled** items (design already fully
   decided, DECISIONS.md "Group D — CHOSEN"; this is pure implementation). App lock
   = biometric/PIN on open + `FLAG_SECURE`/hide-in-recents, which DECISIONS.md
   named as **the recommended v1 answer** to the delete-for-me worry. Archive
   declutters; app lock answers "someone picks up my unlocked phone." The user's
   concern was privacy, not just decluttering — **they ship together.**
   Decided: **one shared Archived screen** from the account menu, not per-tab.
   Needs a rules change (`users/{uid}/state/{doc}`, owner-only) → **coordinated
   deploy**: rules first, verify the *deployed source*, then install.
3. **Goal / effort tracking.** The big one. Needs its own doctrine pass BEFORE any
   code (see the carried constraints below). Unparks the feature-ideas.md
   entry — see the note under "Source of truth".

**Carried into the goals phase (agreed 2026-07-25 — do not lose):**
- **`ScheduleItem` has NO duration field.** It carries an instant, not a span, so
  feature-ideas.md's "log its planned duration" presumes a field that does not
  exist. Decide first: (a) add `durationMinutes` to `ScheduleItem` — model, builder
  UI, create-rules, three card screens — or (b) effort is logged separately.
- **Icon-system (i) — per-item category icons — is DEFERRED and co-designed with
  goals**, so `ScheduleItem` migrates ONCE, not twice. Use a stable string key,
  never a raw codepoint.
- **Answer "who can see my goal stats" TOGETHER with the deferred share-a-group
  profile-scoping question (item 7 below).** Same question; do not solve it twice.
- **If goals includes charts, write the UI-RULES progress/chart sections FIRST** —
  doctrine then code, same order as the theme. UI-RULES.md today has no data-viz
  section and no progress recipe, and `app_theme.dart` themes no progress
  indicator.
- Already decided in feature-ideas.md, not open: effort unit is **minutes**;
  visibility is **owner-controlled, private by default, its own share list — NOT a
  reuse of `plannerGrants`**; items count only via an explicit `goalId` set at
  creation, never retroactively.

**Explicitly DEFERRED, not dropped (2026-07-25) — logged so it isn't lost again:**
- **Group B — "seen" status.** Fully designed 2026-07-23 (DECISIONS.md "Group B"),
  never built: item-level not app-level, pending-only, three states including the
  high-value *absent* one (`Sent 3d ago · not seen yet`), no push. **Deferred to
  keep this pass from ballooning — it is a separate feature, not a cut.** Note its
  dependency: it needs locale-aware **relative-time** formatting added to
  `core/format/datetime_format.dart`, which does not exist yet (goals will likely
  want it too).

**Open product decisions — deferred until AFTER the first real loop test:**
6. **Consent model: toggle vs. request-driven.** Current = target flips a
   "can plan for me" switch; a planner-requests→target-approves model may fit the
   "friend takes initiative" vision better. Decide from how the loop *feels*; may
   rebuild the grant flow. (DECISIONS.md "Open questions.")
7. **"Share-a-group" profile-read scoping.** Profile reads are currently
   any-signed-in; tighten to users who share a group with the owner. Deferred rules
   hardening. (DECISIONS.md "Deferred hardening.")

**Parked to LATER PARTS of the reminder layer (do NOT build until explicitly
directed):** voice-mode reminders, quiet-hours *enforcement*, recurring
reminders, snooze, a lead-time offset ("remind me 10 minutes before" — it wants
`ScheduleItem.durationMinutes`, so decide it WITH goals, not before), OEM
autostart/battery onboarding, iOS, and the tz-snapshot **detect-and-re-approve**
upgrade (option 3; v1 stays pure snapshot — DECISIONS.md 2026-07-22). Card-day
items (Cloud-Function push swap, CF-mediated join) are parked to Blaze, not to
now. Reminder *firing* and boot re-registration are no longer parked — see the
section below.

**Read this before planning any of it (corrects a stale framing — D25):** the
2026-07-23 product decision (DECISIONS.md "reminder / accountability app, NOT an
alarm app") settled that we are not trying to wake anyone up, and that stands.
It is **not** a decision that reminders are peripheral, and it is **not** a
finding that exact alarms are unavailable to us. On 2026-08-19 the user restated
that reminders/notifications are **the core of the product**, and the Play policy
was re-checked against that: the acceptable use cases for `USE_EXACT_ALARM` are
literally *"the app is an alarm or timer app"* and *"a calendar app that shows
event notifications."* Separately, `SCHEDULE_EXACT_ALARM` — the user-granted
prompt — reaches **the identical AlarmManager code path with no Play review at
all.** So "inexact scheduling is sufficient" was a *choice*, not a constraint,
and it is now reopened. Nothing is decided until the spike's numbers land.

**The spike ran; the gate is satisfied for Part 1.** `run_2026-08-20_G2.csv`,
recorded in DECISIONS.md → "Alarm spike — the numbers (2026-08-20)". At G2
(exact granted, battery unrestricted, autostart off), armed 04:51 → fired 09:30
after a 4h39m screen-off window: `setAlarmClock` **+0.55s**,
`setExactAndAllowWhileIdle` **+0.62s**, inexact **+110s**. With the permission
*not* granted, both exact calls threw `SecurityException` and scheduled
**nothing** — there is no silent downgrade. Chosen:
`setExactAndAllowWhileIdle` + `SCHEDULE_EXACT_ALARM`.

**Still unmeasured, and NOT to be quoted as proven:** reboot durability (Run E
never completed — there is not one `REARMED` row in the CSV, and the only `BOOT`
rows are the install-time artifact the README warns about), force-stop (Run C),
and the G0/G1/G3 sweep. Autostart's contribution is therefore unknown, which is
exactly the bit that decides whether an OEM primer is needed.

**Partly overtaken 2026-08-22 — the primer question is now settled even though
the sweep is not.** Run C's *scenario* was observed in the wild: HyperOS
Security's Boost killed the app and all its armed alarms vanished
(`pi_cancelled`), silently. So **a primer IS needed**, and its target is the
user's cleaner/Autostart settings rather than Doze. The measurements above are
still unmeasured — this was one uncontrolled observation, not Run C — so quote
it for *whether a primer is needed*, never for latency or durability numbers.
(DECISIONS.md → "Killed-app alarm delivery — OneKeyClean answers open item 1".)

## Reminder layer — Part 1, the core scheduling engine (SHIPPED 2026-08-20)

**The first reminder code in `lib/`.** `lib/features/reminders/`. Full reasoning
in DECISIONS.md → "Reminder layer, Part 1". **NOT VERIFIED ON A DEVICE** — see
the bottom of this section.

**The engine is `setExactAndAllowWhileIdle` via flutter_local_notifications**
(`AndroidScheduleMode.exactAllowWhileIdle`), behind `SCHEDULE_EXACT_ALARM` —
never `USE_EXACT_ALARM`, which is Play-reviewed against a list we are not on.
Channel `time_app_reminders`, created in code and deliberately NOT the
`high_importance_channel` FCM uses: a user must be able to silence
someone-else's-activity pushes without silencing their own reminders, and a
channel's importance is frozen at creation forever.

**The one design rule, and do not undo it: reminders are driven off the ITEM
STREAM, never off transitions.** There is no hook in `approve()`, `reject()`,
`withdraw()`, `markDone()`, `markSkipped()` or the builder. One rule —
`desiredReminders()`: I am the target, `approved`, no outcome, still future —
is applied to whatever the stream currently says, so withdraw / reject / outcome
/ edit are not special cases at all; each simply stops producing a desired
entry. **Adding a per-transition `cancelReminder()` call anywhere is a
regression**, not a belt-and-braces improvement: it creates a second place that
decides, and the two will disagree.

The pieces, and which of them can be wrong:

- `application/reminder_policy.dart` + `reminder_reconciler.dart` — **two pure
  functions**, no plugins, no clock, no Firestore. All the logic that can be
  wrong lives here, which is why `test/reminder_scheduling_test.dart` covers it
  without a device. `reconcileReminders` is **idempotent** — that is what makes
  it safe to run on every stream emission, every app start and every resume.
- `data/reminder_scheduler.dart` — **the seam**, same discipline as
  `chatbot_service.dart`: no OS vocabulary crosses it. iOS lands as a second
  implementation at one provider line.
- `data/reminder_mirror_store.dart` — the durable local mirror, because Android
  **cannot be reliably queried** for what it holds. It is a *belief*, told to
  the OS and never read back. A refused schedule is kept OUT of it so the next
  reconcile retries; recording it would lose that reminder permanently and
  silently.
- Notification ids: deterministic FNV-1a → positive 31-bit, with a real
  collision story (linear probe, incumbent keeps its id, mirror is the
  authority). Not a counter — cancelling requires reproducing the id from a
  cold start.

**The POST_NOTIFICATIONS ask moved and must not move back.**
`MessagingService` no longer calls `requestPermission()` — that fired the system
prompt during token registration on first sign-in, before the user had seen a
screen, and Android grants that prompt roughly once. The ask now belongs to
`ReminderPrimerCard` on My Schedule, shown only when there is an approved future
item AND the OS will not deliver it. Token registration is unaffected:
`getToken()` never needed the permission.

**Tap routing goes through `routing/notification_routing.dart`** — the one place
that decides a destination, now that FCM and local reminders both produce taps.
A reminder's payload is **only the item id**; it opens `/outcome?item=<id>`,
which scrolls to that card and outlines it for six seconds.

**The spike's CSV came with us.** `android/.../reminders/ReminderAudit*.kt` +
`data/reminder_audit_log.dart` arm a **silent shadow alarm** at the same instant
as each reminder; its receiver writes delay + Doze/power-save/battery-opt/screen
state to a CSV in device-protected storage. Read it at **dev menu → Reminder
audit**. It exists because flutter_local_notifications posts natively without
starting Dart, so there is no Dart callback at fire time. **Cost: two exact
alarms per reminder.** It is an instrument — deleting the two receivers, the
Kotlin and `reminder_audit_log.dart` removes it with no effect on firing.

**NOT VERIFIED — nothing has fired on a device.** The device pass is: grant both
permissions, self-plan an item a few minutes out, background the app, confirm
the notification, tap it, and read the audit CSV. Then the ones that matter —
**killed-app delivery** and **reboot re-arm**, neither of which the spike
proved.

**ARMING is verified, firing is not (2026-08-22).** A 07:00 reminder was observed
in `dumpsys alarm` exactly as designed: `window=0` (exact), `flags=0x5`
(STANDALONE | ALLOW_WHILE_IDLE, i.e. `setExactAndAllowWhileIdle`),
`exactAllowReason=permission` — the OS stating it granted exactness *because*
`SCHEDULE_EXACT_ALARM` is held — and two alarms per reminder (the reminder plus
its `REMINDER_AUDIT` shadow), the documented cost. **Arming is not firing:**
nothing has been observed to fire, and the same session proved a HyperOS Boost
silently discards armed alarms (checklist item 1 above).

**Two traps for the next device pass, both hit on 2026-08-22.** (a) A release
build refuses `run-as` (`package not debuggable`), so the mirror and the audit
CSV are unreadable and the dev menu is stripped — **use a debug build** if you
need either, and `dumpsys alarm` is the only witness otherwise. (b) An install
can fire `installer_clear_app_data_caller`, **wiping prefs, the mirror and the
sign-in**; a post-install run starts from an empty mirror and a signed-out app,
which is not a bug but will mislead you if unnoticed.

**FIRING VERIFIED 2026-08-23 — and then a foreground-silence bug found and
fixed.** A self-item reminder fired on the Redmi and rang LOUD on the alarm
stream **after a recent-apps clear** — the first observed fire, killed-app
included. BUT it was **silent while another app held the foreground**, loud only
when the screen was idle. Root cause: the reminder was a *heads-up notification*,
which HyperOS suppresses (sound included) while another app is foreground. The
USAGE_ALARM channel had fixed the ringer-mask silence; it did nothing for
foreground suppression. **Fix (directed, SHIPPED 2026-08-23, NOT YET VERIFIED ON
DEVICE): full-screen-intent alarm.** The reminder now posts with
`fullScreenIntent: true`, `category: alarm`, and `FLAG_INSISTENT` (looping tone),
behind a new `USE_FULL_SCREEN_INTENT` permission. A full-screen intent is treated
as a genuine alarm interruption, not a suppressible notification, so it rings over
any foreground app and launches full-screen when locked. New pieces:
`presentation/alarm_screen.dart` (the full-screen surface, reached via the ONE
tap route `NotificationRouter.openItem` → `Routes.alarm`; its Dismiss calls
`ReminderService.dismiss()` which cancels the notification to stop the insistent
loop), a `canUseFullScreenIntent()` native check on `MainActivity`'s
`time_app/full_screen_intent` channel (the plugin wraps the request but not the
query), `fullScreenIntentAllowed` folded into `ReminderPermissionState.isFullyReady`,
and a third primer branch that requests it. **Alarm stream volume was 3/15 on the
Redmi — a contributing factor, not the cause; bump it for testing.**

**FOLLOW-UP BUG + FIX 2026-08-23 — the sound tracked the screen, not the alarm.**
On the Redmi the full-screen alarm lit the screen and rang, but the tone **cut
out the moment the screen went dark** — useless for waking anyone. Cause:
`FLAG_INSISTENT` loops the notification tone but holds NOTHING awake, so once the
FSI's screen timed out the OS stopped servicing it. Fix (SHIPPED 2026-08-23, NOT
YET VERIFIED ON DEVICE): **playback moved into a wake-lock-backed foreground
service**, exactly how AOSP DeskClock does it. `AlarmSoundService.kt`
(`.reminders`) holds a `PARTIAL_WAKE_LOCK` and loops a `MediaPlayer` on
`USAGE_ALARM`, `startForeground` with `foregroundServiceType=mediaPlayback`, a
**10-minute safety auto-stop** so a missed dismiss can't ring/hold the lock
forever. Driven from Dart over `MainActivity`'s `time_app/alarm_sound` channel
(`data/alarm_sound.dart` → `AlarmSound`): `AlarmScreen` on mount **starts the
service AND cancels the fired notification** (so the two tones never double up),
and on Dismiss stops it. `MainActivity.showOverLockAndWake()` sets
`setShowWhenLocked`/`setTurnScreenOn` + `FLAG_KEEP_SCREEN_ON` (UI visibility only
— the wake lock, not the screen, is what sustains the sound). New manifest perms:
`WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` + the
`<service>`. **The two audio paths split and never overlap:** foreground-app case
= the notification's own insistent tone (this screen never opens); locked/off case
= FSI opens `AlarmScreen` → service takes over on a wake lock. **Do not add a
per-transition sound hook or move playback back into the notification** — the
service owns it. `mediaPlayback` is the FGS type; `specialUse` is the fallback if
Play ever objects.

**Deferred to later parts (do not build until directed):** OEM
autostart/battery onboarding, iOS, quiet-hours enforcement, recurring reminders,
snooze, and a lead-time offset (it wants `ScheduleItem.durationMinutes` — decide
it WITH goals).

## Permissions onboarding — SHIPPED 2026-08-23 (first-run, deep-linked, OEM-aware)

`lib/features/onboarding/` + `lib/core/platform/`. One first-run flow that asks
for every permission a reminder needs, explained, most-consequential first, shown
once per device after profile completion and re-runnable from the account menu
(`/permissions`). Full reasoning in DECISIONS.md → "Permissions onboarding" and
"Battery-exemption direct dialog". **NOT VERIFIED ON A DEVICE — the Redmi pass is
the acceptance test** (grant each, revoke and re-run, and check an aggressive-OEM
autostart card).

- **The doctrine held, do not regress it:** no raw OS prompt fires before an
  on-screen explanation, and the flow runs after auth+profile, never at splash.
  The existing primer card is untouched and stays the repair path for the three
  delivery permissions.
- **Runtime dialog:** POST_NOTIFICATIONS. **Deep-linked to this app's toggle:**
  SCHEDULE_EXACT_ALARM, USE_FULL_SCREEN_INTENT. **Direct dialog:** battery/Doze
  (new `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — a deliberate Play-policy
  declaration). **OEM-guided:** autostart — resolve-checked native component map,
  **never blind-launched**, per-OEM guided card where nothing resolves.
- **Two new `MainActivity` channels** (`time_app/battery`, `time_app/autostart`),
  thin-channel pattern, no `permission_handler`. `device_info_plus` reads
  `Build.MANUFACTURER` for the OEM branch.
- **`ReminderPermissionState`/`ReminderPermissions` extended** with
  `batteryUnrestricted` + `autostartLikelyNeeded` and two new asks.
  **`isFullyReady` deliberately still the delivery trio only** — adding
  battery/autostart would show the primer with no branch. Scheduler/firing path
  NOT touched.
- **Pure, testable core:** `oem_profile.dart` (OEM branch selection) and
  `onboarding_plan.dart` (auto-skip granted / skip-on-unsupported-API /
  unknown-OEM-skips-autostart). Covered by `test/onboarding_test.dart`.

## Slot-lock reconciler — SHIPPED 2026-08-23 (self-healing lock release)

`lib/features/scheduling/application/slot_lock_reconciler.dart` +
`data/slot_lock_repository.dart` + `releasableSlotLocks()` in
`slot_availability.dart`. **The fourth stream-driven reconciler**, same doctrine
as reminders/stats/planner-access: one rule — *a `scheduleSlots` lock should
exist iff a LIVE item (`blocksSlot`) sits in its slot* — applied to the item
stream, wired at one line in `app.dart` (`slotLockSyncProvider`). It closes the
gap that `markDone`/`markSkipped` never released a lock (nor did an offline-failed
withdraw/reject release), so a completed item's stale lock permanently blocked its
half-hour — the "slot taken no matter what time I pick" bug. It DELETES only
(creation stays in `createItem`'s batch); it is collision-safe (verifies the
stored `itemId` matches a dead item and excludes any slot with a live occupant);
and it self-heals locks that already leaked. **There is deliberately NO
`releaseSlot()` in `markDone()`/`markSkipped()`** — adding one is a regression, a
second place that decides. NOT YET VERIFIED ON DEVICE (needs the install that also
carries the reconciler — the earlier build predated it, which is why the first
on-device test showed no release).

## Social profile layer — SHIPPED 2026-08-21

`lib/features/social/`. Usernames, friend requests, friendships, blocking, a
public/private toggle, an extensible stats section, and profile-picture uploads.
Full reasoning in DECISIONS.md → "Social profile layer — SHIPPED 2026-08-21";
schema in data-model.md → "The social layer". **NOT VERIFIED ON A DEVICE.**

**The premise correction, so it is not re-made:** the "USP" of other people
planning your schedule and triggering your alarms was already built — groups +
`plannerGrants` + the `pending → approved` machine + FCM + the reminder layer.
The social layer does NOT replace or extend it.

**Friends sit ALONGSIDE groups, and grant NOTHING.** Being someone's friend does
not let them plan your day; planning permission remains
`groups/{id}/plannerGrants`, target-granted and revocable. Do not collapse the
two. If a friendship should ever carry planning permission, the escape hatch is
`friendships/{pairId}/plannerGrants/{id}` — `watchTargetsFor()` is a
**collection-group** query, so it would pick those up with **no client change**.

**The one design rule, and do not undo it: every social document id is COMPUTED
from the two uids.** Rules can `exists()` a path they can construct and cannot
run a query, so a friendship under an auto-id is invisible to the rules engine
and the privacy toggle becomes unenforceable. `social_ids.dart` and the
`sortedPairId()` helper in `firestore.rules` compute the same ids and must stay
in step. Friendships are **sorted** (symmetric); requests and blocks are **not**
(directed).

Things not to rediscover:

- **Stats are PUBLISHED, not derived.** A visitor cannot read your items, so
  your device writes `users/{uid}/profileStats/summary` and theirs reads it
  through the gate. **Driven off the item stream, never off transitions** — same
  doctrine as reminders. Adding a `publishStats()` call to any transition is a
  regression. It reads the RECORD providers (`allItemsAs*`), which is what the
  constraint comment in `schedule_providers.dart` was written for.
- **Adding a statistic is ONE entry in `kProfileStatDefinitions`.** No `compute`
  function = a placeholder tile. Giving it one turns the tile live, and that is
  the only edit. Placeholders are omitted from the published map, never written
  as zero.
- **Search is exact-match only, deliberately.** `usernames/{handle}` denies
  `list` because allowing it would rebuild the user-enumeration hole that
  `users`' `list: if false` closed. Prefix/fuzzy search reopens it.
- **`UsernameRepository.claim` is TWO writes and cannot be one.** Rules see
  committed state only, so a mirror write inside the reservation transaction
  would be evaluated against a world where the reservation does not exist yet.
- **Nothing the privacy toggle governs may go on `users/{uid}`.** That document
  is `allow get: if signedIn()` by design and does not consult `isPublic`.
- **A block and a missing account must render identically**, in the profile
  screen and in search. The `blocking`/`blockedBy` distinction is internal only.
- **Blocking cascades** (block doc → grants → friendship → requests, in that
  order) and deliberately does NOT touch existing schedule items. Unblocking
  restores nothing.
- **Firebase Storage is unavailable** (needs Blaze; no card). Avatars go through
  the existing Cloudflare Worker into **Supabase Storage**. Format is decided by
  **sniffing bytes**, not `Content-Type`. Two caps: 2MB static / 5MB animated.
  **Never add cropping, compression, `imageQuality` or a transform** — all
  re-encode, and re-encoding an animated GIF/WebP flattens it to one frame.

**This resolves two deferred questions** — open item 7 ("share-a-group
profile-read scoping") and "who can see my goal stats", which had to be answered
together. Goal stats will be entries in `kProfileStatDefinitions` and inherit
this gate; they need no second visibility model.

**NOT DONE, and each is a decision rather than a gap:** another user's friend
count (the rules scope friendship reads to the caller by design), rate limiting
on requests (nowhere to put it without Blaze), push for friend events (the
Worker's `{event, targetUid, itemId}` contract does not fit one), and Friends as
a fourth nav tab (the bar names the three delegation stances).

**Deploy order — rules FIRST.** `firestore.rules` and `firestore.indexes.json`
both changed; the app fails closed until they are deployed. Verify the deployed
source, then install. 100 emulator rules tests cover it
(`firestore-tests/social.test.mjs`).

## "View B's schedule" modal + slot conflicts — SHIPPED 2026-08-21

A planner picking a time for a target sees that target's schedule live, and
cannot pick a half-hour that is already taken. Reasoning in DECISIONS.md →
"View B's schedule modal + slot conflicts"; recipes in UI-RULES.md §6.11.
**NOT VERIFIED ON A DEVICE. RULES + INDEXES DEPLOYED 2026-08-23** (live ruleset
`56e11d6d-6c1c-4dd8-ae16-9141defa7b62`; `scheduleSlots` + `plannerAccess` +
`callerHasPlannerAccess` confirmed present in the deployed source, and it diffs
byte-for-byte against `firestore.rules`). This deploy was forced by a real
failure: the installed debug build batches a `scheduleSlots` lock write with
every `createItem`, so with the slot rules undeployed EVERY item-create —
self-items included — failed atomically with "Missing or insufficient
permissions." Cause was the undeployed rules, not auth.

**DEPLOY ORDER — RULES FIRST (now done).**
`firestore.rules` and `firestore.indexes.json` both changed. Until deployed the
modal's read is denied and the access mirror cannot be written. An old client
against the new rules is fine (everything added is additive), so rules-then-app
is safe in that order and only that order.

```
firebase deploy --only firestore:rules,firestore:indexes
```

Things not to rediscover:

- **A planner could not read a target's schedule at all** before this. The item
  rule was target-only and the collection-group rule only exposed items the
  caller *created*. This was never a UI gap; it needed rules.
- **`callerHasActiveGrant()` cannot gate it.** That helper needs a `groupId`, and
  a read of `scheduleItems/{B}/items` carries none — rules construct paths, they
  do not query. Hence the mirror below. Do not try to "just reuse the helper".
- **`plannerAccess/{plannerUid}_{targetUid}` — existence IS the permission.**
  Only the TARGET may write a row (the rules pin `targetUid` to the caller); a
  planner minting their own would invert the entire model. **The rules cannot
  verify the mirror against `plannerGrants`** — that check needs the very query
  that forced the mirror to exist, so it is circular. It is not a hole: only the
  target can write, and the only power granted is reading the target's own data.
  Agreement with the grants is a CLIENT invariant.
- **The mirror is driven off the GRANT STREAM, never off grant transitions**
  (`PlannerAccessReconciler`, wired at the one line in `app.dart` beside the
  reminder and stats wires). Same doctrine, sharper argument: a stale mirror is
  access outliving its revocation, not a missed notification. **Adding a mirror
  write inside `setPlannerGrant()` is a regression.** It also backfills
  pre-existing grants on next app open, with no migration.
  **Known window:** a revoke performed while the target is offline does not reach
  the mirror until they are next online. Closing it needs a Cloud Function.
- **A "slot" is a fixed 30-minute bucket, NOT a duration on the item.**
  `ScheduleItem` still has no duration field and this does not add one — the
  goals-phase decision is untouched. Buckets are **anchored to the UTC epoch**,
  because a wall-clock anchor is ambiguous on fall-back dates (local 01:30 twice
  = one key, two half-hours). Cost: in +05:45 zones buckets start at :15/:45
  local. `kSlotMinutes` is the one place; **changing it invalidates every
  existing lock.**
- **The server-side re-check is a LOCK DOCUMENT, because nothing else exists.**
  No Cloud Functions in this project (no `functions/`, no Blaze) and rules cannot
  query. `scheduleSlots/{targetUid}/slots/{slotIndex}` is written in the **same
  `WriteBatch`** as the item; `allow update: if false` is what makes a colliding
  `set` fail instead of overwrite — the `usernames/{handle}` device. An emulator
  test asserts the race directly.
- **Locks are released on `withdraw()` and `reject()`** via an optional `item:`
  argument, best-effort and deliberately not batched with the status write. A
  stale lock costs one falsely-blocked half-hour; a status write that failed
  because a lock delete failed would break the consent loop.
- **Items pre-dating this feature have no lock.** They still block in the UI (the
  items stream is authoritative for what is *shown*), but their half-hour has no
  atomic guard until something rewrites it.
- **The modal is a function, not a route** — `showTargetScheduleModal()`, like
  every other dialog and sheet here.

**Flagged, not built:** freeing a lock when an item is archived or its outcome is
recorded; any UI for a target to see who holds planner access over them; and a
"next free slot" hint that looks beyond the day in view.

## In-app calendar — SHIPPED 2026-08-21

`lib/features/calendar/`. Month / week / day views over the schedule items that
already exist. Full reasoning in DECISIONS.md → "In-app calendar"; recipes in
UI-RULES.md §6.10. **NOT VERIFIED ON A DEVICE.**

**It stores NOTHING, and that is the property to protect.** No collection, no
document, no field, no `firestore.rules` change, no index, no permission, no
Worker event. Every item comes from `myItemsAsTargetProvider` and
`myItemsAsPlannerProvider`, untouched. If the calendar ever needs to write
something, that is a decision to record before it is a line of code.

**Reached from the account menu at `/calendar`, top-level and pushed** — the
Archived precedent, because it merges both roles and so belongs to no tab. It is
deliberately **not a fourth nav tab**; the bar's three destinations are the three
delegation stances, and that reasoning has now held three times (chatbot,
Friends, this).

Things not to rediscover:

- **An item's day is its OWN timezone's date, never the viewer's.** The app
  already renders every item in `item.timezone`, so bucketing by the device zone
  would file a card reading "Tue 9:00 AM" under Monday. `calendarDayFor()` in
  `application/calendar_grouping.dart`. An unknown zone falls back rather than
  throwing.
- **No time-blocking, and it is not an omission.** `ScheduleItem` carries an
  instant, not a span — there is no duration field. The day view is an hour
  **rail**, not a proportional grid; a sized block would assert a duration
  nothing in the app knows. **If `durationMinutes` lands with goals,
  `calendar_day_view.dart` is the first file that changes.**
- **`table_calendar` supplies the GRID only, and draws none of its own cells.**
  Its builders interpolate `'${day.day}'` — Latin digits — which would silently
  break the standing worldwide requirement. Every cell goes through
  `formatDayOfMonth()`, and the week start comes from
  `MaterialLocalizations.firstDayOfWeekIndex`. `calendar_screen_test.dart` pins
  this with a Bengali-locale render (**not** Arabic: intl's `ar` data uses Latin
  digits, so that test would have passed vacuously).
- **Tap opens a VIEW sheet that ROUTES; it never edits and never acts.** Edit is
  not buildable — `firestore.rules` makes `title` and `scheduledInstantUtc`
  immutable after create ("Planner edit is still deferred") and
  `ScheduleRepository` has no `updateItem`. **No disabled Edit control was added
  either**, and a test asserts its absence. Done/Skip stay on My Schedule; the
  sheet's one action `go()`s there, where `Routes.outcomeForItem` already
  scrolls to the card and outlines it.
- **Markers reuse the ONE status mapping** (`style.background`, or
  `style.border` for the transparent neutral treatment). The calendar names no
  `attention*` role, so the §2.7 firewall lint needs no exemption for it.
- **The calendar's whole integration with existing code is ONE optional
  parameter**: `ScheduleBuilderScreen.initialDate`, null by default and
  identical to before when null. It seeds the **date only**, never a time — the
  user tapped a day, not an hour. `_pickDate`'s window was widened to contain an
  already-selected date, because `showDatePicker` *asserts* `initialDate` is in
  range and the grid pages years either way.

**The device pass, when it happens:** open the calendar with items in more than
one timezone; check the month grid, the dots and the `+n` overflow; select a
date; swipe between months and confirm the header title follows; Today; Week;
Day and its hour rail; long-press a date and confirm the builder opens with that
date filled; tap an item and confirm the sheet routes into My Schedule with the
card outlined. Then the same in dark mode (UI-RULES §8) and in a right-to-left
locale, which nothing here has been run in.

## Language practice chatbot — a SEPARATE feature (added 2026-08-18)

**Not part of the core loop and deliberately not woven into it.** `lib/features/chatbot/`
shares the theme, the icon vocabulary and the router with the delegation app and
**nothing else**: no group, no schedule item, no approval, no outcome, no Firestore
document, no FCM, no Worker. Keep it that way — if it ever needs to touch a
delegation feature, that is a decision to record here first.

**Entry point = the account menu** (`AccountButton` → "Language practice"), above a
divider that separates it from the account block. `Routes.chatbot` stays **top-level
and pushed**, so it covers the nav bar and Back returns to the tab you left. The dev
menu still links to it, but is no longer the only way in — that mattered because the
dev menu is stripped from release builds, so the feature had no door in release.
**Do not make it a fourth nav tab** without re-reading DECISIONS.md 2026-08-18: it
would dilute the three-stance meaning of the bar, force the dev-menu link from `push`
to `go`, and break the chat's session boundary (a shell branch stays mounted forever,
so the transcript and `session_id` would outlive the sitting).

**What it talks to.** Since Part 2 (below), **the engine on this phone** — nothing
at all. What follows describes `HttpChatbotService`, which is kept as the
reference implementation to compare against, and the service it speaks to:

```
POST {base}/chat   {"session_id": "...", "message": "..."}
  -> {"reply_german": "...", "reply_english": "...", "source_file": "...",
      "matched": true|false, "score": 0.0}
GET  {base}/health -> {"status":"ok","lines_indexed":...}   # not called by the app
```

`matched:false` is a **normal reply**, not an error — the service returns a graceful
"say that another way" and the UI marks it quietly (line work + muted text, never the
orange fill, §2.7). Only a turn that produced no usable reply throws.

**The seam — the one thing that must not be eroded.** `data/chatbot_service.dart`
declares `ChatbotService` with **one** method (`send` → `ChatReply`) and one throwable
(`ChatbotFailure`, carrying a message already written for the user). **No HTTP
vocabulary may cross it** — no URL, no status code, no JSON, and no `/health`, which is
an HTTP-only diagnostic. This exists because the long-term direction is the chatbot
running **ON-DEVICE with no server**, for other people's phones: that lands as a second
implementation behind the same interface, swapped at the single line in
`chatbotServiceProvider`, with the chat UI untouched.

**Everything address-related is HTTP-implementation-scoped and dies with it:**
`http_chatbot_service.dart`, `chatbot_endpoint_store.dart` (the `shared_preferences`
base URL, defaulting to `http://100.116.97.26:5000` — a Tailscale address that WILL
move, hence editable and never hardcoded in the UI) and `chatbot_settings_screen.dart`.
On-device has no address; delete the three together.

**Android cleartext.** Plain `http://` is blocked from targetSdk 28, so
`android:usesCleartextTraffic="true"` is set in `android/app/src/debug/AndroidManifest.xml`
— **debug only, on purpose.** Release stays cleartext-blocked (all other traffic is
HTTPS). Running the chatbot in a release build over plain HTTP needs a recorded
decision first.

**Untested, and it stays that way:** `normalizeBaseUrl` and the `/chat` response
parsing have no coverage, and this must never be run against the live service on
a device. (That it is no longer the running engine is said once, above.)

### On-device engine — Part 2 (it answers) SHIPPED 2026-08-19

**`chatbotServiceProvider` now returns `OnDeviceChatbotService`.** A reply needs
no laptop, no Tailscale and no internet — the phone can be in airplane mode. The
chat screen did not change; one provider line did. (DECISIONS.md → "On-device
chatbot engine — Part 2".)

- **The pipeline is a PORT of `backend/search.py` + `app.py`, not an
  approximation.** Normalize (SentencePiece Precompiled charsmap) → WhitespaceSplit
  + Metaspace → Unigram Viterbi at 128 incl. specials → ONNX MiniLM int8 (mean
  pooling is INSIDE the graph) → L2 normalize → cosine over the 5,275-row index →
  top 10 → **below 0.55, decline**; otherwise serve, skipping a repeat of the
  session's last line. Query and index vectors are only comparable if both sides
  tokenize identically, and a *nearly* right tokenizer raises no error — it just
  retrieves worse lines. Do not "simplify" any stage.
- **Threshold is 0.55** — `MATCH_THRESHOLD` in `app.py`. The 0.545 named in the
  Part 2 prompt exists nowhere in the chatbot repo; both sit inside the measured
  void (0.4552 … 0.6893) so nothing measured behaves differently. One source of
  truth, in `RetrievalPolicy`.
- **Tokenizer verified against the real 250,002-piece HuggingFace tokenizer on
  5,302/5,302 texts** — whole corpus plus adversarial Unicode. Not one id differs.
  `test/fixtures/tokenizer_fixture.json` carries the **real** charsmap with a cut-down
  vocab; the goldens come from HF, so "correct" here means "what built the index".
- **English glosses are PRECOMPUTED** (`subs_en.json`, 210KB, the 5th release
  asset), produced by the same Argos de→en model the server calls. Retrieval can
  only ever return one of the 5,275 corpus lines, so the runtime translator was a
  function over a finite domain. **Do not add an on-device translator** — it is
  +159MB for an advantage that cannot occur. The gloss file is optional to
  `EmbeddingIndex` (German-only degrade) and required in `kModelFiles`.
- **The download is a choice.** `build()` only *checks* now (→ `ModelReady` or
  `ModelNeeded`); only a tap starts 143MB. `ChatGate` is what `/chatbot` builds and
  it sits OUTSIDE `ChatScreen`, handing over whole, so the `session_id` is minted
  when practice begins and not when someone glanced at a prompt.
- **Loading runs in `Isolate.run`** (17MB JSON + 8MB vectors would freeze the
  frame that opened the chat). The ORT session is created on the main isolate — it
  is a platform handle and cannot be sent.
- **"Service address" left the chat menu**, dev-menu only now: it edits an address
  nothing reads. `HttpChatbotService` is KEPT as the reference implementation to
  compare against — restoring it is one provider line.

**NOT VERIFIED — nothing has run on a device.** The ONNX session, the 118MB model
load, inference latency and memory on the Redmi are the device pass. Everything
either side of the ORT call is covered by tests.

### On-device model — Part 1 (download + storage) SHIPPED 2026-08-19

The second implementation's **acquisition layer**, recorded as built.
(DECISIONS.md → "On-device chatbot model — download + storage".)

~143.5MB of model files are **downloaded from a GitHub Release, never bundled**.
`kModelReleaseBaseUrl` in `data/model_manifest.dart` is the one line to swap. It
is **live** (`RedWaffle007/German-Subtitle-Chatbot`, tag `model-v1`) and all five
assets carry real sha256 digests, so strict verification is on.

- `data/model_manifest.dart` — the URL constant + the **five** files (the fifth,
  `subs_en.json`, arrived with Part 2). Each carries a **nullable**
  `sha256`/`sizeBytes`: null means "verify what is knowable" (received bytes vs
  `Content-Length`), and filling the real digests in turned strict verification on
  with no code change. All five are filled.
- `data/model_store.dart` — app-private *support* dir (not documents: machine
  artifacts, and iOS excludes it from iCloud backup). **The `.part` discipline is
  the safety story** — a download writes `<name>.part` and is renamed only after
  it verifies, so a file bearing the real name is by construction a file that
  passed. Do not add a "which downloads finished" side-table; that is the
  bookkeeping this design exists to avoid.
- `data/model_downloader.dart` — resumable via `Range`. **The response code
  decides, never the request:** 206 appends, 200 truncates and restarts, 416
  discards. A server that ignores `Range` answers 200 with the whole body, and
  appending that to a partial file makes a corrupt file of plausible size.
  Per-chunk idle timeout, not a whole-download one.
- Entry point = **the chat AppBar overflow menu** → "Offline model"
  (`/chatbot/model`), plus the dev menu. Deliberately *not* the settings screen,
  which dies with the HTTP implementation and would take the door with it.
- **It now gates the chat** — see Part 2 above.

**Not verified on a device: nothing has downloaded a real byte.** Also
unaddressed: Android `allowBackup` is on by default, so 143MB in the support dir
is nominally in scope for auto-backup (it exceeds the 25MB quota and would simply
fail) — decide whether to exclude the directory before release.

## Committed stack

- **Frontend:** Flutter (single codebase).
- **Backend:** Firebase — Auth + Firestore + Cloud Functions + FCM (not Supabase).
- **Push:** FCM (completion/skip notifications, invites).

## Build-order rules (enforce these)

1. **Reliable-mode alarms before voice-mode alarms.** Get one mode firing reliably and the core loop tested with real pairs *before* layering voice mode on top.
2. **Do not build any parked feature, and do not add any alarm/voice logic, until the user explicitly directs it.** This is a hard rule: no code for a parked feature or for alarm/voice behavior may be added — **not even as a stub, placeholder, TODO comment, empty function, config flag, or "while I'm here" convenience.** If something seems useful, **propose it and wait** — do not build it. Parked = streaks, gentle stakes, templates, panic mode, Cheerleader/Buddy roles, public template sharing, reactions beyond the voice note. Alarm code, voice notes, and roles come after the core loop is proven and are directed separately.
3. Suggested build order: auth+profile(tz) → groups+invites+planner-permission → schedule items + pending queue + approve/reject → reliable-mode alarms → completion/skip + planner push (test with real pairs HERE) → voice-mode alarms → quiet hours + tz warnings.

## Alarm work — reminder firing is DIRECTED and Part 1 is built

The blanket "not yet" is retired for the *scheduling engine* only (see "Reminder
layer — Part 1" above). Everything else in the reminder layer — voice mode, OEM
onboarding, iOS, quiet-hours enforcement, recurring, snooze — is still parked and
still needs explicit direction. The rules below apply with full force to
verifying what was just built.

- **Verify alarm/notification behavior on a real Android device, never an emulator.** OEM battery-optimization process-killing (Xiaomi/Samsung/Oppo) does not reproduce on emulators — a passing emulator run proves nothing about whether alarms fire.
- **Primary test device: the Redmi (Xiaomi HyperOS, Android 16, arm64).** Don't trust an alarm as "reliable" until it survives on this device.
- Platform mechanics (native-clock-vs-custom-sound tradeoff, entitlements) live in `mvp-spec.md` and `feature-ideas.md` — read them when that work begins.

## Redmi install quirk

`adb install` / `flutter run` fails with `INSTALL_FAILED_USER_RESTRICTED` until, in **Developer options**, both **"Install via USB"** and **"USB debugging (Security settings)"** are enabled — and those toggles only stick while the phone is **signed into a Mi account with active internet**. If installs start failing, re-check these first.

## Git — HARD RULE

**Never run `git commit`, `git push`, or `git remote` operations. Never stage
(`git add`) or otherwise create/mutate commits, branches, or remotes.** The user
performs ALL Git commits, pushes, staging, and remote setup manually, always —
no exceptions, no "just this once." Read-only git (`status`, `diff`, `log`,
`show`, `check-ignore`, `ls-files`) is fine. When Git write work is needed,
**provide the exact commands for the user to run** and stop.

## Working agreement

- Before writing code in a step, state the plan briefly and wait for confirmation.
- Ask when a decision has real trade-offs rather than guessing.
- Stop for review after each numbered step; do not run ahead.

## Decisions (terse; full reasoning in [DECISIONS.md](DECISIONS.md))

- **State = Riverpod**, kept plain (no families/autoDispose/code-gen until needed).
- **Routing = go_router.**
- **Feature-first layout** — `lib/features/<feature>/{presentation,data,application}`.
- **Auth = Google Sign-In only** for v1.
- **Firebase config via `flutterfire configure`**; re-run after adding a SHA-1.
