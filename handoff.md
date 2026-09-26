# Checkmate handoff — 2026-09-25 (end of day)

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
  debug signature, so `adb install -r` keeps data. Never release on the Redmi.

## Current state

- Branch `main`, clean. Latest commits: `489c922`, `09ea496`, `a3d7e3d` — three
  device-pass correction rounds, all verified green by the full suite.
- Completed: Items **1–23, 25–31, 34, 35**, plus the three 2026-09-25 device
  passes (DECISIONS.md: "Device-pass corrections…", "Second device pass…",
  "Third device pass…").
- **Firestore rules deployed 2026-09-25 and byte-verified** with
  `scripts/check-deployed-rules.sh` (they had been stale at `01ff2b5`).
- **Cloudflare Worker deploy state is UNKNOWN.** Items 23/34 changed it
  (plan-request pushes, late-Done follow-up). If planner pushes misbehave,
  redeploy (`wrangler deploy` then `wrangler versions deploy <id>@100%`).
- Latest profile build installed on the Redmi; the third-pass fixes await the
  user's device check.
- Next implementation order (revised 2026-09-26 after the in-person device
  check): **Batch A ✓ → B ✓ → B2 ✓ → C ✓ → D ✓ (decided) → E (18 → 19 → 20 → 15 → 14 → 16 → 17) ✓ → 32-0…32c ✓ → F (F1+F6 ✓ → F2 ✓ built → F3+F5 → F4) → 32d → 24 → 33**. See "Device-check
  backlog (2026-09-26)" below.
- Detailed rationale/history belongs in `DECISIONS.md`; do not duplicate it here.

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
  {task} for you" / "You planned {task}". It is carried natively with the armed
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
  sign-in. PLAN button is bottom-left.
- My Schedule and History cards open the status timeline; Calendar → "Open in
  Activity" reveals and outlines the exact item.

## Deferred final release gate

- Item 22: deploy `worker/`; verify profile/group GIF/WebP upload, animation,
  replacement, deletion, and non-owner denial.
- Re-run the full suite, build/install a release APK, and test the alarm
  lifecycle on supported devices. Do not call Item 22 production-complete
  before this gate.
- Still unproven on device: reboot re-arm, and killed-app delivery after an OEM
  cleaner (see CLAUDE.md "Parked & unverified").

## Device-check backlog (2026-09-26) — before Item 32

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

### Batch F — device feedback after 32c (added 2026-09-26) — BEFORE 32d

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
- **F3 — Tones.** At the scheduled time: a Default Alarm rings the alarm
  ringtone (as today); a Voice Note alarm plays the recording 3×. Everything
  else the app sends uses the phone's normal notification tone (the
  "Emergency plans" max-importance alert channel is retired).
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

### 32 — Custom voice-note alarms (NEXT) — PLAN AGREED 2026-09-26, not started

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
- **32d** Library: save, You → Voice notes (play, rename, delete, localized
  timestamp default name, newest first, month groups once two months exist),
  attach from library via server-side copy.

### 24 — Stats and product review

- Last product-surface change: audit/reuse existing stats; prioritize useful,
  privacy-safe signals over surveillance/vanity metrics.
- Cover minimum samples, permission/relationship changes, timezone ranges,
  trends, empty states, and humane streaks.
- Research whether standalone Log Time provides enough planned-vs-actual value
  before changing or removing it (the post-Done Log Time prompt is already gone).

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

1. Get the user's device result for the third-pass fixes (profile build
   installed). Fix anything reported before new work.
2. Then plan Item 32 — state the plan and wait for sign-off before code (it
   needs storage, rules and Worker decisions; deploy rules before its device
   pass and re-run `scripts/check-deployed-rules.sh`).
