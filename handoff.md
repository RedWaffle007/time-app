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
- Next implementation order: **32 → 24 → 33**.
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
- **Ting then ring, owned by `AlarmSoundService`**: strike on the alarm stream,
  ringtone exactly 1.5 s later. The splash ting is suppressed while ringing; an
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

## Remaining roadmap

### 32 — Custom voice-note alarms (NEXT)

- Planning for another person may attach a per-alarm voice-note override; max
  20 seconds with preview, discard/re-record, and optional library save.
- At fire time, play exactly three loops, then end—no fallback/minimum duration.
  Existing Dismiss/Snooze interrupts immediately; each snoozed occurrence gets
  its own three loops.
- Deliver an immutable recipient-side offline snapshot. Sender rename/deletion
  must not affect scheduled alarms. Define safe lifecycle cleanup.
- Saved Voice Notes tab: listen/rename/delete, localized timestamp default name,
  newest-first, month grouping immediately at two distinct months.
- Keep audio out of Firestore/notifications. Add authenticated storage,
  server-side MIME/duration/size/ownership checks, idempotent delivery/download,
  native alarm/reboot/process-death integration, and exhaustive regression plus
  device audio/lifecycle acceptance.
- **Integration points from 2026-09-25:** playback belongs in
  `AlarmSoundService` (after the ting, replacing the ringtone loop; it already
  owns the ting→ring order and the one-minute cap). The voice note must travel
  with the native arm call the way the headline does (`AlarmDelivery.arm` →
  `AlarmDeliveryScheduler` extras → `AlarmDeliveryStore` for reboot).

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
