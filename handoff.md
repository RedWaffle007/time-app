# Checkmate handoff — 2026-09-26 (end of day)

## Operating rules

- Do not run tests, commit, push, deploy, or publish. The user does those after
  receiving exact commands.
- Before any device test that depends on rules, run
  `scripts/check-deployed-rules.sh` (read-only). Device passes against stale
  rules produced false "regressions" on 2026-09-25.
- Edit with `apply_patch`; preserve unrelated worktree changes.
- **Never run `dart format` on a directory.** Several files are not
  formatter-clean; formatting them reflows unrelated code. Format only files you
  created, or check a file is already clean first.
- **No personal names anywhere** (code, comments, tests, docs). Use `{planner}` /
  `{task}` in prose and role names in fixtures (`Test Planner`,
  `TARGET`/`PLANNER`/`OUTSIDER`). Rules-test uids keep the `uid_a_…`, `uid_b_…`,
  `uid_m_…` prefixes: friendship ids are the sorted pair, and some tests spell
  them out.
- Every feature/fix needs proportional regression coverage.
- Full verification:

  ```bash
  flutter analyze && flutter test && (cd firestore-tests && npm test) && node --test worker/test/*.test.mjs && (cd android && ./gradlew :app:testDebugUnitTest)
  ```

- After a green run, give one exact `git add ... && git commit -m "..."` line.
  A push does not deploy Firestore rules or the Cloudflare Worker.
- Device builds: **profile** to judge smoothness/lag (debug is JIT-janky);
  **debug** for alarm diagnostics (dev menu, reminder audit CSV). Both share the
  debug signature, so `adb install -r` keeps data. Never release on the Redmi —
  except to check the exact APK being shared with an external tester (see
  "International test build"); switching signatures needs an uninstall, which
  wipes the app's data and sign-in.
- **Release APK for testers (arm64 only, lean):**
  `flutter build apk --release --target-platform android-arm64` →
  `build/app/outputs/flutter-apk/app-release.apk`. The release SHA-1
  (`89:73:22:BE:…:06:60`) is registered in Firebase (verified 2026-09-26 via
  `./gradlew :app:signingReport`, which prints fingerprints only), so Google
  sign-in works on other phones. Never read `android/key.properties`.

## Current state

- Branch `main`, clean after `dc9d7f3`. Today's commits, each green on the full
  suite: `b1db021` (F1+F6), `4e9489a` (F2), `29feacb` (F3+F5), `f1a0950` (F4),
  `dc9d7f3` (32d).
- Completed: Items **1–23, 25–32 (32-0 … 32d), 34, 35**, Batches **A–F**.
- **Deployed 2026-09-26 (user-confirmed):** Firestore rules (latest adds
  `users/{uid}/voiceLibrary`; run `scripts/check-deployed-rules.sh` before any
  rules-dependent device pass) and the Cloudflare Worker (32d library routes +
  save hooks). `wrangler deploy` makes the new version live immediately.
- Test counts at `dc9d7f3`: Flutter 737, Worker 147 (`node --test
  worker/test/*.test.mjs` from the repo root — there is no worker/package.json),
  rules 262, Kotlin unit tests green.
- **International test build (2026-09-26):** the user is building an arm64
  release APK to share with a tester abroad, and may install it on the Redmi
  to check it first. Their results are the next device evidence.
- Next implementation order: **… F ✓ → 32d ✓ → Batch G → 24 → 33**. Every phone check
  since Batch A is deferred to the device pass (see "Deferred device checks").
- Detailed rationale/history belongs in `DECISIONS.md`; do not duplicate it here.

## Product model now (2026-09-26 — read before touching planning or alarms)

- **No approval step (F2, user-directed change to the core loop).** Consent is
  ONE revocable permission per person ("Let {name} set alarms for me"; the old
  planning + emergency grants are merged — turning it off revokes both). Every
  alarm a permitted person sets is saved `approved` and rings directly; the
  planner can **Cancel alarm** until it rings. Legacy `pending` items become
  alarms on the target's device (past ones → skipped "did not respond"). No
  Pending approvals screen, badge, glow, approval reminders or "Emergency"
  label anywhere. CLAUDE.md's core-loop line still says "A approves each item" —
  DECISIONS.md "Approval removed" supersedes it.
- **Two alarm kinds (F4):** Default Alarm (mandatory task name; rings the
  ringtone) and Voice Note (no name — stored as "Voice alarm"; lock screen,
  missed notice and push read "{planner} sent you a voice alarm"). Self-plans
  are Default Alarm only.
- **Tones (F3):** only alarms ring; every other notification uses the phone's
  normal tone on the `planner_activity` / `app_nudges` channels.
- **Voice replays (F5):** 15–20 s → 3 plays, 10–15 s → 4, 5–10 s → 5,
  under 5 s → 6 (boundaries take the longer band); notes are 1–20 s.
- **Voice library (32d):** every SENT voice note is saved automatically
  (Worker, send time + hourly sweep fallback), newest 20 FIFO; You → Voice
  notes (play / rename / delete); "Choose from library" in the builder via a
  server-side copy.

## Behaviour that must not regress (all test-pinned)

- **History = decided plans only.** An approved plan leaves My Schedule only when
  it has an outcome; elapsed time never moves it. The end-of-day lapse
  (`Did not respond`) still settles undecided plans.
- **Missed alarm = fact, not outcome.** The one-minute auto-stop records only
  immutable `alarm.unavailableAt` (in the background — the popup never waits on
  Firestore). The card shows the "User unavailable at alarm time" tag above
  Done/Skip. The popup (two actions only) writes the first outcome itself;
  Done renders as `Done (Late)`. **An unanswered popup re-appears on every
  launch until Done/Skip — user-directed, keep it.** Legacy auto-skip rows are
  still offered for review.
- **Done/Skip show "Updating {planner}…" for 1.5 s** (card: non-dismissible
  dialog; popup: in place), then the celebration (Done only). The celebration
  fires from the committed save (`committedCelebrationProvider`), de-duplicated
  with the Firestore echo by id. No Log Time pop-up after Done.
- **Alarm copy is one sentence** from `alarmHeadline()`: "{planner} planned
  {task} for you" / "You planned {task}" / (voice) "{planner} sent you a voice
  alarm". It is carried natively with the armed
  alarm (survives reboot) and used for the lock-screen AlarmScreen (no
  placeholder flash), the unlocked heads-up (Android shows full-screen only when
  locked; user chose a rich heads-up over "display over other apps"), and the
  native missed-alarm notification.
- **No ting on alarms (2026-09-26, user-directed):** `AlarmSoundService` starts
  the ringtone at once; the ting is app-start only. (Was "ting then ring".) The splash ting is suppressed while ringing; an
  alarm cold start opens directly on `/alarm?item=` (`getInitialRoute`).
- **One notification per ringing alarm**: the service cancels the scheduled
  reminder notification (same id) directly on NotificationManager, at once and
  at 0.5/2/5 s. Never via Dart's cancel path (it releases the owner and stops
  the ring).
- Plan builder: person list collapses to one row + Change after a pick; rows
  show `Loading…`, never a uid; planning-target profiles are prefetched from
  sign-in. PLAN button is bottom-left. Send validates on tap (red "Please write
  task name. It is mandatory." / "Please record a voice note."); the field
  glow is UI-RULES §6.2b.
- The phone's 12/24-hour setting wins over the language default everywhere
  (F1, `DeviceClockScope`).
- Library entries are created/deleted ONLY by the Worker (entry + audio stay
  together); a deleted note is never re-added (`librarySavedAt`).
- My Schedule and History cards open the status timeline; Calendar → "Open in
  Activity" reveals and outlines the exact item.

## Deferred device checks (everything since Batch A — run in one pass)

- Nothing built on 2026-09-26 has been checked on a phone. Priorities for the
  pass: an alarm rings with no approval step (friend → target); Cancel alarm;
  voice alarm plays 3–6× by length and reads "{planner} sent you a voice
  alarm" locked and unlocked; ringtone fallback when the note is missing; new
  alarm / other notifications use the normal tone and the old "Emergency
  plans" channel is gone from Settings; Plan screen in light + dark (glow,
  red validation, possessive zone line); You → Voice notes (auto-save after a
  send, play, rename, delete, 21st evicts the oldest); Choose from library →
  send; 12/24-hour on the Nothing 4a.
- International tester: sign-in, timezone of alarms planned across zones,
  permissions onboarding on their OEM, delivery while their app is killed.

## Deferred final release gate

- Item 22: deploy `worker/`; verify profile/group GIF/WebP upload, animation,
  replacement, deletion, and non-owner denial.
- Re-run the full suite, build/install a release APK, and test the alarm
  lifecycle on supported devices. Do not call Item 22 production-complete
  before this gate.
- Still unproven on device: reboot re-arm, and killed-app delivery after an OEM
  cleaner (see CLAUDE.md "Parked & unverified").

## Device-check backlog (2026-09-26) — before Item 32

> **Historical.** Everything below was resolved in Batches A–E (the stale
> Worker was redeployed). Kept for the diagnosis trail; the live list is
> "Deferred device checks" above.

Step 0 diagnosis (read-only, 2026-09-26):
- Live rules `89d484d1…` match `firestore.rules` byte-for-byte.
- **Live Worker is stale**: version `1a4d5663` (deployed 2026-09-19 13:40 UTC)
  predates five `worker/src` commits (`bcd6a59`, `0665a89`, `dde04c0`,
  `29f1ebb`, `86db693`). The deployed `notify.js` rejects `groupId: ''` as
  `item-missing-fields`, so **no item push is sent for friendship plans** —
  only group plans. It also lacks emergency data pushes, `planRequested`,
  inactivity, and the late-Done copy.
- Client suppresses the foreground Done push (`lib/app.dart` `_showForegroundBanner`,
  celebration instead); every other foreground push is only a 6 s SnackBar.
- "Skipped shown for a completed task": both deployed and local Worker copy
  branch correctly on `outcome.result`; not reproducible from code. Needs the
  exact repro (which button, planner app open/closed) after the Worker redeploy.

Batch A (one Worker deploy + client) — **BUILT, committed `68921ad`, Worker
`85f84670` deployed 2026-09-26; device check deferred by the user**
(DECISIONS.md "Planner notifications: named, timed, group-labelled…"):
1. Foreground pushes become real system notifications on a planner-activity
   channel (never the reminder channel); Done keeps the celebration too.
2. Named copy: "{name} completed the task: {task}" / "{name} skipped task:
   {task}" — `{name}` is the doer, read by the Worker from Firestore.
3. Early outcome: "{name} completed Task: {task} before time" / "{name} skipped
   Task: {task} before time" when `completedAt`/`skippedAt` < scheduled instant.
4. Group items say they are group tasks (normal and emergency), all events.

Batch B — **BUILT, committed `ccd8e00`, Worker deployed 2026-09-26; device
check deferred by the user** (DECISIONS.md "Dismiss and group-join pushes").
5. Dismiss notifies the planner (new `dismissed` event, gated on the existing
`alarm.dismissedAt`). 6. Group join approved notifies the candidate.

Batch B2 — pending approvals: visibility + reminders (added 2026-09-26) —
**BUILT, committed `fca87b4`, index + Worker deployed 2026-09-26; device check
deferred**
(DECISIONS.md "Pending-approvals badge moves…" and "Approval reminders").
Mechanism chosen for 13: **A, server-side Worker cron** (every minute).
Every item ships with thorough regression tests (listed per item).
10. **Badge on the right icon.** Bug: `plan_shell.dart` puts
    `planAttentionCountProvider` on the "My Schedule" TAB label; the Pending
    approvals app-bar icon (beside the overflow/Archive) has no badge. Move the
    count onto that icon, showing the real number (2 pending → "2"). Keep the
    Plan bottom-bar pillar badge (same provider — they can never disagree).
    Tests: widget test — N pending → icon badge shows N, tab label has none;
    0 → no badge; decide one → count drops; pillar and icon always equal.
11. **Glow on the Pending approvals icon** while ≥1 pending, until all are
    decided. Themed glow from `lib/core/theme/` (new recipe: DECISIONS →
    UI-RULES → code, lint-clean), visible in light AND dark; any pulse honours
    reduced-motion. Tests: glow present iff count > 0, both themes, disappears
    on last decision, `ui_rules_lint_test` passes, reduced-motion = static.
12. **Verify the initial "new plan for you" push reaches the target** (X plans
    for Y, due in ~30 min). Batch A/B fixed the likely cause (stale Worker
    dropped all friendship-plan pushes). Add a Worker test matrix for
    `created`: friendship/group/emergency × tokens/no-tokens × dedup, and a
    device check with `wrangler tail`.
13. **Approval reminders** while a plan stays pending: "Task: {task} planned
    by {planner} is waiting for your approval." Timing scales with the window
    W = due − created (proposal, needs sign-off):
    - W < 10 min → 1 reminder at W/2 (5-min plan → ~2.5 min).
    - 10 min ≤ W < 2 h → 2: at W/2, and a final one at due − 10% of W
      (clamped to 3–10 min before).
    - W ≥ 2 h → 3: at W/2, due − 1 h, and a final one at due − 10 min.
    - Never more than 3; drop one that is already past or < 2 min after the
      previous; stop at once on approve/reject/withdraw/lapse.
    Mechanism DECIDED 2026-09-26: server-side Worker cron (claims each slot
    against the item's updateTime, so a decision anywhere stops it).
    Tests: pure schedule function over many windows (1 min … 24 h, DST day,
    past-due, clock skew), cap and spacing invariants, stop-on-each-decision,
    dedup per reminder slot, self-plans never remind, copy with/without names.

Batch C — **BUILT, committed `99420a1`, Worker deployed 2026-09-26; device
check deferred**
(DECISIONS.md "Batch C: startup sound, tab gutter…"). Push taps now keep
the startup screen (only alarm launches skip it). Originally: 7. Startup-sound toggle (splash
only, not alarms). 8. Slightly larger left content inset — one theme token,
DECISIONS → UI-RULES → code order. 9. **Inactivity push (item 15) tap skips the
startup screen** (reported 2026-09-26): tapping the 6-hour inactivity
notification plays the startup bell but goes straight to My Schedule without
the loading/startup screen. Fix so the startup screen shows (likely the
`_openedFromNotification` / `_dismissColdStartReveal` path in `lib/app.dart`,
which suppresses the reveal for push taps while the splash sound still plays).
Also re-audit that the inactivity push reliably reaches ALL users: the
`*/5` cron in `worker/src/inactivity.js`, which users it scans, token
handling, dedup, and that it was not live until Worker `8229568f`
(2026-09-26) — it had never been deployed before that.

Batch D — explored and DECIDED 2026-09-26 (DECISIONS.md "Batch D decisions").
Batch C is committed (`99420a1`). The four decisions become build Batch E:

Batch E — build, one item at a time, thorough regression tests each:
18. **Planner in-app outcome pop-up** — **BUILT, rules deployed, committed
    `bc346ae`** (DECISIONS.md "Planner in-app outcome pop-up").
    Planner inside the app: Done → confetti PLUS a pop-up, heading "Your
    planning skills are amazing!", body "{name} completed task: {task}";
    Skipped → same pop-up shape, body "{name} skipped task: {task}", neutral
    heading, NO confetti. Planner outside the app: the Batch A push already
    does this (named Done/Skipped copy) — device check still deferred.
    Approach (recommended, pending sign-off): the pop-up rides the existing
    durable Firestore queue (`completionCelebrations`, seen-once per
    participant), generalised to carry `result: done|skipped` so a Skip also
    writes one — a rules change + deploy. While the planner is in the app,
    Done/Skipped pushes are NOT also posted as system notifications (the
    pop-up is the announcement); every other push still is. Only the planner
    sees the pop-up — the target keeps "Updating {planner}…" + confetti.
14. **Emergency notification.** — **BUILT, Worker deployed, committed** (DECISIONS.md "Emergency notification — its own channel"). A dedicated "Emergency plans" channel (max
    importance, own sound/vibration) for the immediate alert on the target, and
    "Emergency" in every push about an emergency item (created, decided,
    outcome, dismissed, withdrawn, reminders). Alarm timing unchanged. No DND
    bypass (would need notification-policy access).
19. **Two-hour minimum response window near midnight** — **BUILT, committed**.
    Deadline = the LATER of (a) midnight ending the task's own local day —
    today's rule, still the limit for every task scheduled before 22:00 — and
    (b) the scheduled time + 2 h. So a 23:50 task gets until 01:50, not 10
    minutes. One change in `endOfScheduledLocalDayUtc` / `hasLapsed`
    (`item_lapse_policy.dart`), applied to BOTH lapses (approved → Skipped "Did
    not respond"; pending → Rejected "Not approved in time") so there is one
    deadline. Tests: before/after 22:00, exactly 22:00, DST nights, unknown
    zone, the lapse reconciler, and the calendar/My Schedule "still
    actionable" state.
20. **Auto-skip notifies both people** — **BUILT, Worker deployed, committed** (DECISIONS.md "Server-side lapse…"). When an item lapses
    to Skipped "Did not respond", push to the target AND the planner (self-
    plans: target only). Recommended with it: move the lapse itself to the
    Worker cron (it already scans items every minute), because today it only
    happens when the target next opens the app — a user who never opens it is
    never skipped and nobody is told. The client reconciler stays as an
    idempotent fallback. **DECIDED 2026-09-26: the Worker does the lapse.** No
    clock time in the text (decided: overkill now — it would need each
    recipient's locale + 12/24h stored with their token; the task name plus a
    tap into the locale-correct app is enough). Proposed copy:
    - Target — title "Task skipped automatically"; body "{task}, planned by
      {planner}, was marked Skipped because you didn't respond in time."
      Self-plan: "{task} was marked Skipped because you didn't respond in
      time."
    - Planner — title "Task skipped automatically"; body "{name} didn't
      respond to {task}, so it was marked Skipped."
    - Group: add " in {group}" and "Group task" in the title; emergency:
      "Emergency task" in the title. Own dedup field per recipient.
15. **Group emergency plan — per-person grants only.** — **BUILT, rules +
    Worker deployed, committed** (DECISIONS.md "Group
    emergency plans"). "Plan for the group"
    gains an Emergency switch when the planner holds at least one member's
    FRIENDSHIP emergency grant; it fans out only to those members (born
    approved, as today) and reports who was skipped and why. Fixes needed
    first: the Worker's `itemGrantPath` must select `emergencyGrants` for
    `tier == 'emergency'` even when `groupId` is set; rules: the emergency
    create branch must require `groupId == ''` OR both parties be members of
    that group (today it does not check `groupId`). Rules deploy + byte-verify.
16. **Planner heads-up for pending plans.** — **BUILT, Worker deployed,
    committed** (DECISIONS.md "Planner heads-up"). When the FINAL approval reminder
    goes out and the plan is still pending, the planner gets one push: "{name}
    hasn't approved {task} yet". Rides the B2 cron and its claim; own dedup
    field. Lapse stays silent to the planner.
17. **WhatsApp invite link — real tap-to-open.** — **BUILT 2026-09-26;
    awaiting Worker deploy + commit; debug AND release fingerprints are in
    `APP_CERT_SHA256`** (DECISIONS.md "Tap-to-open
    invite links"). https link served by the
    Worker (`/i/u/{username}` add-friend, `/i/g/{joinCode}` join-group) with a
    small fallback landing page, `/.well-known/assetlinks.json`, an Android App
    Links `intent-filter` (autoVerify) and a router route that opens add-friend
    or join-group prefilled. Uses existing usernames/join codes — no new data.
    Share buttons send the link. Needs the signing SHA-256 fingerprints (debug
    now; release when a release key exists) for assetlinks.

## Remaining roadmap

### Batch F — device feedback after 32c (added 2026-09-26) — DONE

Decided with the user 2026-09-26. **This removes the per-item approval step
that mvp-spec.md / CLAUDE.md describe as the core loop** — record it in
DECISIONS.md as a directed product change before any code; consent now rests
entirely on the planning permission (still target-granted and revocable).

- **F1 — 12/24-hour clock.** — **BUILT 2026-09-26; awaiting commit + device check.** Bug (Nothing 4a): the time picker shows 24-hour
  while the phone is set to 12-hour. Cause: Flutter only exposes "forced
  24-hour"; when false, Material falls back to the LANGUAGE default, which is
  24-hour for e.g. English (UK/India). Fix: read Android's real
  `DateFormat.is24HourFormat` natively (startup + resume) and apply it to the
  picker AND the one format helper, both ways. Tests for both settings in a
  24-hour-default locale.
- **F2 — BUILT 2026-09-26 (awaiting user test/deploy/commit; phone check
  deferred).** Rules: create = one permission (planning grant, emergency grant
  merged in), `approved` or legacy `pending`; planner may cancel any
  unanswered alarm — 258/258. Worker: `hasActiveItemGrant`, every new alarm
  is an alarm command, "Alarm cancelled", Emergency label retired,
  approval-reminder cron + module deleted, stale legacy pending → skipped —
  131/131. App: approvals screen/route/badge/glow removed; builder + group
  fan-out save `approved` with a "Send" button; planner "Cancel alarm";
  legacy pending → alarms (past → skipped) via the lapse reconciler; ONE
  "Let {name} set alarms for me" switch (off revokes both grants); copy
  rewritten; `test/f2_no_approval_test.dart` — full suite 715. DECISIONS.md
  "Approval removed". Deploy order: rules → Worker → app. The "Emergency
  plans" channel survives until F3. Original item:
  - **F2 — Remove approval entirely (groups too).** Every alarm anyone sets
  through the app rings directly (what "emergency" did); the Emergency
  switch/label goes. One permission: the existing planning permission
  (friend or group) now authorises direct alarms; the separate emergency
  permission is merged in (either one keeps someone able to plan for you).
  Plans still pending at ship time become alarms (past ones are skipped).
  Removed with it: Pending approvals screen, its badge + glow (B2 items
  10–11), approval reminders + planner heads-up (items 13, 16), approve /
  reject pushes, the pending lapse. The planner keeps a Cancel for alarms
  they set (the emergency "recall", generalised). Rules + Worker + app.
- **F3 + F5 — BUILT 2026-09-26 (awaiting test/deploy/commit; phone check
  deferred).** Emergency channel retired (new-alarm alert on the activity
  channel, normal tone); plays 3–6 by length natively + recorder copy; Worker
  minimum 1 s; notes under 1 s discarded in the recorder. DECISIONS.md "Tones
  and voice replays". Worker tests: `node --test worker/test/*.test.mjs` from
  the repo root (there is no worker/package.json). Original items:
- **F3 — Tones.** At the scheduled time: a Default Alarm rings the alarm
  ringtone (as today); a Voice Note alarm plays the recording 3×. Everything
  else the app sends uses the phone's normal notification tone (the
  "Emergency plans" max-importance alert channel is retired).
- **F4 — BUILT 2026-09-26 (awaiting test/deploy/commit; phone look in light
  + dark deferred).** DECISIONS.md "Plan screen overhaul + field glow";
  UI-RULES §6.2b `FieldGlow` (replaces the retired pending glow). Voice alarms
  are stored titled "Voice alarm"; headline + push read "{planner} sent you a
  voice alarm". Validation on Send (red task-name / record-a-note lines).
  Original item:
- **F4 — Plan screen overhaul** (light + dark, UI-RULES first for the new
  glow recipe): "You're building in {Name}'s local time" (possessive fix);
  Pick date / Pick time bold, larger, subtle glowing outline; two rounded
  choices **Voice Note** / **Default Alarm**; Voice Note → Record (Play /
  Re-record / Discard) and **no name field** — the notification AND the
  lock-screen alarm read "{planner} sent you a voice alarm"; Default Alarm →
  mandatory **Name of the Task** (bold label, glowing border; empty → red
  "Please write task name. It is mandatory."); then Note (optional, glowing
  border); submit renamed **Send**. Self-plans: Default Alarm only (voice
  notes are for someone else).

- **F5 — Replays scale with the note's length** (user-directed 2026-09-26,
  replaces "exactly three"): 15–20 s → 3 plays, 10–15 s → 4, 5–10 s → 5,
  under 5 s → 6. Boundaries go to the LONGER band's count (exactly 15.0 s → 3,
  10.0 s → 4, 5.0 s → 5). The shortest note the Worker accepts rises from
  0.3 s to 1 s so every note falls in a band. Native `VoiceAlarmPolicy` (play
  count + cap = plays × duration + 1 s; a 5 s note × 6 = 31 s, a 20 s note × 3 =
  61 s, both inside the wake-lock window), the recorder copy ("Plays N times"),
  Worker `MIN_VOICE_MS`, tests at every boundary.
- **F6 — Remove language practice entirely** (widened 2026-09-26 — the
  feature code was already gone in `8b0b3e6`) — **BUILT 2026-09-26; awaiting commit.** Was: remove it from the app's explanations: the "How this
  app works" You line and the first-run tour's You step. The feature itself
  (You → Language practice) is untouched. Copy tests updated.

Order: **F1 + F6** (small, app-only) → **F2** → **F3 + F5** (both ring-time
sound) → **F4** → 32d.

### 32 — Custom voice-note alarms — DONE (32-0 … 32d, 2026-09-26)

Decisions (2026-09-26): storage = private Supabase bucket via the Worker;
recorder = `record` package, playback = native MediaPlayer; library = You →
Voice notes (pushed screen, no new nav tab); snooze does not exist (parked), so
only Dismiss interrupts; group plans excluded from v1.

**The ting is removed from ALARMS entirely (user-directed 2026-09-26)** — it
plays only when the app opens. Ringtone alarms start the ringtone at once;
voice alarms start the voice note at once. This supersedes "Ting then ring"
below and the `ringtoneDelayMs` 1.5 s offset.

**Ring rule:** a voice-note alarm plays the note exactly three times, then
ends into the normal missed-alarm flow (its cap = 3 × duration + 1 s, since a
20 s note × 3 is already the full minute). Ringtone alarms keep the 60 s cap.

**"It must never fail" — what is and is not possible, and the design:** no
code can guarantee a sound on a phone that is off, muted, killed by an OEM
cleaner, or never online again. The design makes failure rare, visible early,
and never silent:
- Download at approval (or emergency creation), not at ring time; retried off
  the item stream on every emission, resume and connectivity change; the file
  is hash-verified before it is armed.
- **Delivery receipt:** after a verified download the target's device stamps
  `voiceNote.deliveredAt` on the item; the planner's card shows "Voice note on
  their phone" or "Not on their phone yet".
- **Pre-due rescue (Worker cron):** undelivered 30 min before due → a
  high-priority data push asks the target's device to fetch it in the
  background (works on a killed app, like emergency alarms); still undelivered
  10 min before due → the planner is told it will ring with the normal
  ringtone unless it arrives.
- **At ring time** the native side re-checks the file (size + hash); if it is
  missing or damaged the alarm rings the normal ringtone (never silent), and a
  `voice_fallback` lifecycle event makes the app tell the planner "{name}'s
  alarm rang with the normal ringtone — your voice note couldn't play".

Steps (each its own tests + commit):
- **32-0** Remove the ting from alarms (native + tests + docs). — **BUILT, committed; Redmi check deferred.**
- **32a** — **BUILT, rules + Worker deployed, committed.** Worker `POST /voice` (auth, active grant, byte-sniffed AAC/M4A, header
  duration ≤ 20.5 s, ≤ 256 KB, immutable once the item exists), `GET` download
  (target or planner only), library copy, retention cron (item audio deleted 7
  days after its scheduled time; orphan uploads after 1 day); private bucket;
  rules for `voiceNote {durationMs, sha256}` (other-person plans only) and the
  target-only `deliveredAt` stamp.
- **32b** — **BUILT, committed; Redmi check deferred.** Recorder in the schedule builder (≤ 20 s, auto-stop, preview,
  discard/re-record, attach; mic permission only after an explanation);
  "Play voice note" on Pending approvals (hear it before consenting).
- **32c** — **32c-1 and 32c-2 BUILT, deployed, committed; installed on the
  device 2026-09-26 (feedback became Batch F).**
  Target download + receipt, native three-loop playback, reboot /
  process-death via `AlarmDeliveryStore`, fallback + planner notice, pre-due
  rescue push, local cleanup off the reminder mirror. Native unit tests +
  Redmi audio acceptance.
- **32d — BUILT 2026-09-26 (awaiting rules deploy → Worker deploy → commit;
  phone check deferred).** Auto-save of every sent note (Worker, send time +
  sweep fallback), newest 20 FIFO, You → Voice notes (play / rename / delete,
  localized default names, month groups), "Choose from library" in the builder
  via server-side copy. DECISIONS.md "Voice-note library". Original:
- **32d** Library: save, You → Voice notes (play, rename, delete, localized
  timestamp default name, newest first, month groups once two months exist),
  attach from library via server-side copy.

### Batch G — FINAL execution list (decided with the user 2026-09-27) — NEXT

Supersedes the first Batch G list. One item at a time, plan → sign-off →
build, regression tests each. Every consent/permission change gets a
DECISIONS.md entry BEFORE code (they reverse earlier recorded decisions).
Deploy order whenever rules/Worker change: rules → Worker → app.

**Done:** G1 literal-clash WARNING (`6fe18b0`) — becomes a hard block in G4
below; its group hint-row retry becomes dead once G2 lands (remove it there).

**Cancelled by the 2026-09-27 instructions:** the "Let {name} set alarms for
me" switch, friend/emergency planner grants, planning-permission requests
("Ask to plan" + its pushes), `plannerAccess` hint rows, unanimous group-join
approval, group per-member planning grants, Request Plan's flexible-window
mode and multi-friend selection.

1. **G2 — Pickers open in the recipient's time.** — **BUILT 2026-09-27;
   awaiting test run + commit; phone check deferred** (DECISIONS.md "Pickers
   open in the recipient's time"). Pick date opens on the
   recipient's current date (their "today" highlighted; range counted from
   their date; an already-chosen date kept); Pick time opens on their current
   time. Add the line "It's now 9:30 PM, Sat 26 Sep there." under the zone line
   (one format helper; not shown for self-plans). Self-plans use the profile
   zone. Group sheet pickers stay on the planner's own time (see G4).
2. **Friends = permission.** — **BUILT 2026-09-27; awaiting test run →
   rules deploy → Worker deploy → commit; phone check deferred** (DECISIONS.md
   "Friendship is the planning permission"). Rules tests:
   `firestore-tests/friendship_permission.test.mjs` (replaces
   `friend_grants.test.mjs`). Being friends is the ONLY permission: X may plan
   for Y (and read Y's schedule for the clash check) iff they are friends.
   Remove the switch, grants, planning requests, emergency grants, hint rows
   and the reconciler; rules + Worker authz switch to `areFriends`. Y's ways
   to stop an alarm: mark it Done/Skipped before it rings, unfriend, or block
   (user-confirmed intent). Reverses "friendship grants nothing".
3. **Groups, WhatsApp-style.** — **BUILT 2026-09-27; awaiting test run →
   rules deploy → Worker deploy → commit; phone check deferred** (DECISIONS.md
   "WhatsApp-style group admins"). Only the creator makes admins; any admin
   may remove another admin (never the creator). Creator = admin (existing groups: owner becomes
   admin); admins can make any number of members admins, and remove members.
   An admin's invite joins immediately; a non-admin's invite, or a join code
   entered by an outsider, becomes a join request pushed to EVERY admin — any
   one admin approves/denies. Any member may plan for the GROUP; there is no
   individual planning inside a group (plan 1:1 as friends instead). Replaces
   unanimous approval and group planner grants. Rules + Worker + app.
4. **Block double-booking** (replaces G1's warning). — **BUILT 2026-09-27
   (STRICT: old builds cannot create plans until updated); awaiting test run →
   rules deploy → Worker deploy → new APK everywhere → commit; phone check
   deferred** (DECISIONS.md "No double-booking — minute locks"). A live plan at the same
   minute for the same person blocks the save — self-plans included. Message:
   "{name} already has a plan scheduled for this time. Please select a
   different time." (self: "You already have …"). Server-enforced: a
   create-only per-minute lock doc written in the same batch as the item;
   client pre-check covers legacy items without a lock. Lock released when the
   item settles/cancels (stream-driven reconciler, not a transition hook).
   **Group plans:** pickers show the planner's time, plus a light pop-up
   listing every member's current local date/time ("Name: Sat 26 Sep, 9:30 PM",
   one line each) while picking. Busy members are excluded (no alarm) and get:
   "Group task "{task}" from {planner} wasn't set for you at {time} — you
   already have a plan then." The planner gets a summary: "Your group task
   "{task}" is set for {X} members. {Y} ({names}) were busy at that time and
   won't be alerted."
5. **Request Plan redesign.** — **BUILT 2026-09-27 (with G6's buttons);
   awaiting rules deploy → Worker deploy → commit; phone check deferred**
   (DECISIONS.md "Request Plan redesign + PLAN / REQUEST PLAN buttons"). One friend → date + time → "Task for which you
   need a reminder" → optional note → Send. Friend gets an instant push:
   "{X} has requested you to plan for them. Click to view details." Reminder
   pushes (same text, tagged "Reminder") at 50% and 75% of the window W =
   due − sent (4 PM → 6 PM: 5:00 and 5:30), Worker cron, stop ONLY when the
   friend creates the plan (viewing does not count); none once past due.
   Revives the deleted Item 13 cron pattern (git history). The Request Plan
   button moves beside Plan; both slightly larger, bold (theme tokens).
5b. **Fulfil a request through the Plan screen** (user update 2026-09-27):
   Set the alarm → the normal Plan screen, pre-filled and locked to the
   requested minute; Default Alarm or Voice Note. — **BUILT 2026-09-27;
   awaiting rules deploy → commit** (DECISIONS.md "Request Plan fulfilled
   through the Plan screen").
6. **"Unavailable" push with a custom tone.** — **BUILT 2026-09-27;
   awaiting Worker deploy → commit; phone check deferred (the tone on the
   Redmi)** (DECISIONS.md "'Unavailable' push with the 'Uh-Oh!' tone"). New planner push when the
   target's alarm auto-stops unanswered (`alarm.unavailableAt`): "{Y} was
   unavailable to dismiss the task: {task} you planned for them." Plays a
   bundled "ooh-ooooo" sound on its own new channel (channel sound is fixed at
   creation). Sound CHOSEN 2026-09-27: "Cartoon - Uh-Oh!" by Breviceps,
   CC0, 1.3 s — https://freesound.org/people/Breviceps/sounds/445964/ (record
   source + licence in DECISIONS.md when built).
7. **G3 + G4 (old numbering) — Home.** — **BUILT 2026-09-27; app-only
   (no deploy); awaiting commit** (DECISIONS.md "Home: 'My Schedule' renamed…"). Rename "My Schedule" to "Home"
   everywhere user-facing; plans the user set for others stay on Home until
   the recipient marks Done/Skipped (or lapse/cancel), then move to Activity.
8. **Remove Track Time** — **BUILT 2026-09-27: Request took Track's pillar
   (option d), REQUEST PLAN dropped from Plan; awaiting rules deploy →
   commit** (DECISIONS.md "Track Time removed; Request takes its pillar"). Was: entirely (feature folder, entry points, voice-parser
   hooks, stats reading it, tests, `trackedTime` rules block + deploy).
9. **Bigger Play and X** — **BUILT 2026-09-27; app-only; awaiting commit**
   (DECISIONS.md "Bigger Play and X on a library voice note"). on a library-attached voice note (≥ 48 dp, theme
   tokens, light + dark).

### 24 — Stats and product review (after Batch G)

- Last product-surface change: audit/reuse existing stats; prioritize useful,
  privacy-safe signals over surveillance/vanity metrics.
- Cover minimum samples, permission/relationship changes, timezone ranges,
  trends, empty states, and humane streaks.
- ~~Research whether standalone Log Time provides enough planned-vs-actual
  value~~ — superseded: Track Time is being removed (Batch G item 8).

### 33 — Competitor review (last)

- Competitors recorded: **PingPal** and **SnoozeSquad**.
- Research only after all preceding tasks. Use current first-party store/site
  evidence; compare positioning, planning/alarm flows, permissions, custom
  audio, pricing, privacy, reliability, and genuine gaps without copying.

## Invariants

- Items live at `scheduleItems/{targetUid}/items/{itemId}`; Item 23 must preserve
  legacy point alarms.
- Planning grants live on the sorted friendship document; group membership is
  never permission.
- Calendar is a projection of existing streams, not a datastore.
- Worker authorization re-reads Firestore; never trust request/notification data.
- Firestore rules and Worker policy tests are security boundaries.
- Android alarm/full-screen delivery is permission/OEM dependent; automated
  policy tests do not replace device wake/audio/hardware-key acceptance.

## Immediate next action

1. Collect the user's results from the release APK (their Redmi and the
   tester abroad). Fix anything reported before new work; record verified
   items in CLAUDE.md "Parked & unverified" / DECISIONS.md.
2. Batch G final list (see roadmap), item 1 (G2) first: plan each item, wait
   for sign-off, build.
3. Then Item 24 (stats and product review): research and audit first, present
   findings and a proposal, and wait for sign-off before changing anything.
4. Item 33 (competitor review) last.
