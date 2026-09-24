# Checkmate handoff — 2026-09-24

## Operating rules

- Do not run tests, commit, push, deploy, or publish. The user does those after
  receiving exact commands.
- Edit with `apply_patch`; preserve unrelated worktree changes.
- Every feature/fix needs proportional regression coverage.
- Full verification:

  ```bash
  flutter analyze && flutter test && (cd firestore-tests && npm test) && node --test worker/test/*.test.mjs && (cd android && ./gradlew :app:testDebugUnitTest)
  ```

- After a green run, give one exact `git add ... && git commit -m "..."` line.
  A push does not deploy Firestore rules or the Cloudflare Worker.

## Current state

- Branch: `main`; latest committed work: `deaac3a` (Item 31 Plan affordance).
- Complete locally: Items **1–22, 25, 26, 28, 29, 30, 31, 34**.
- Item 34 is implemented and fully verified in the current worktree; it needs
  its commit.
- Next implementation order: **23 → 27 → 32 → 24 → 33**.
- Detailed rationale/history belongs in `DECISIONS.md`; do not duplicate it here.

## Deferred final release gate

Batch deployment and real-device acceptance after feature work is finished:

- Item 22: deploy `firestore.rules` and `worker/`; verify profile/group
  GIF/WebP upload, animation, replacement, deletion, and non-owner denial.
- Item 25: verify Upcoming/History/Calendar layout, Back/bottom-nav behavior,
  and past-plan expansion, scroll, and highlight on-device.
- Re-run the full suite, build/install release APK, and test alarm lifecycle on
  supported devices. Do not call Item 22 production-complete before this gate.
- Production deployment of Firestore rules from `01ff2b5` was never confirmed.

## Recently completed — Item 25

- My Schedule contains only approved, outcome-less plans whose UTC due instant
  has not passed. Equality remains Upcoming; elapsed or outcome-bearing plans
  appear only in History. The partition is disjoint and DST/timezone-safe.
- Added `Upcoming Plans` with rounded bold `CALENDAR` and `HISTORY` controls.
- Added Plan sub-route History with `Past Plans`, newest-first cards/days,
  localized month grouping at two distinct months, lazy collapse state, and
  empty/error handling.
- Past target-side Calendar items open History, force the month/day open,
  auto-scroll, and highlight. Pending → Approvals, current/future → My Schedule,
  planner-side → Activity.
- Removed the Plan app-bar Calendar icon and You-tab Calendar entry; updated help.
- Coverage includes boundary/DST partitioning, no duplication, one/two-month
  behavior, short/long histories, cold/warm/far highlights, routing ownership,
  empty states, and existing Done/Skip behavior.

## Recently completed — Item 31

- Replace Plan's bottom-right `+` FAB with a bold rounded `PLAN` text button.
- Preserve schedule-builder destination, tooltip/semantics, placement, all three
  Plan sub-tabs, and separation from the center voice FAB.
- Update coach/help copy and tests. Do not rename Track's log-time action.

## Remaining roadmap

### 34 — Missed-alarm review actions (complete locally)

- Treat the current few-second popup lag as a separate bug within this item.
  Show the review promptly on the next unlocked foreground after reconciliation;
  do not keep it behind planner-notification delivery, unrelated async work, or
  an arbitrary UI delay. Measure and test this independently of outcome actions.
- Preserve two independent facts. A one-minute no-response permanently records
  `User unavailable` at the alarm-time instant in the item timeline; `Done` or
  `Skipped` remains the mutable task outcome. Never erase or relabel the
  alarm-time fact when the later outcome changes.
- Keep the Item 20 default: after the one-minute auto-stop, transactionally set
  an otherwise-unsettled task to `Skipped: User unavailable`. Persist the
  unavailability event separately so changing that default outcome cannot
  destroy the delivery/response-time evidence.
- Replace `Mark reviewed` with item-specific `Mark as Done` and
  `Mark as Skipped` actions. `Mark as Done` may replace only that exact automatic
  skip; it must never overwrite a manual/concurrent outcome. `Mark as Skipped`
  retains the default. Either action completes review for that item; there is no
  outcome-free acknowledgement or bulk outcome mutation. Add no third or fourth
  popup button; keep the decision surface to these two actions.
- Present both facts to target and planner. Keep the canonical outcome as
  `Done`/`Skipped`, but derive a nuanced display label such as `Done (Late)` when
  the immutable `User unavailable at alarm time` event is also present; a normal
  on-time completion remains plain `Done`. This is presentation, not a third
  stored outcome, and the fixed timeline event remains independently visible.
- The planner already receives the automatic unavailable/Skipped notification.
  If the target later changes that exact default to Done, send an idempotent
  follow-up update so the planner is not left with the stale belief that the task
  remained skipped. The live item remains authoritative if either push is lost.
- Define multi-miss behavior one item at a time, notification/idempotency rules
  for the automatic Skip → later Done transition, and safe legacy handling for
  existing `Skipped: User unavailable` records that predate the separate event.
- Test popup latency separately, app-lock gating, single/multiple misses, exactly
  two actions, Done/Skip behavior, plain Done versus derived `Done (Late)`,
  immutable unavailability display, concurrent manual outcomes, process death,
  offline/retry behavior, rules, planner timeline, follow-up delivery, dedupe,
  and notification replay.

### 23 — Request a plan

- New request model; never reuse the permanent `PlanningRequest` grant.
- Require active friendship plus an existing normal planning grant, rechecked
  transactionally when each item is created. Never create emergency/auto-approved
  items or let a request grant authority.
- Support one-plan and flexible-window requests, optional message, multi-friend
  batches, durations, timezone-safe bounds, non-overlap, lifecycle/replay safety,
  legacy instant-item compatibility, notifications, and routing.
- Test grant/revocation, DST, adjacency/concurrency, multi-item fulfillment, and
  every creation mode in rules and application layers.

### 27 — Conditional conflict disclosure

- Replace the always-visible timetable with a day-scoped warning shown only when
  the selected target has live pending/approved outcome-less items that day.
- Reveal localized time/date only—never title/note. Group flow uses one
  consolidated name-grouped popup. It informs; it does not block saving.
- Re-evaluate on target/date/feed changes, suppress identical repeats, and show
  read errors explicitly. Reuse authorized streams and live-item policy.
- Test DST/timezones, state filtering, ordering/fingerprints, mixed-zone groups,
  errors, removed old entry points, and successful save after acknowledgement.

### 32 — Custom voice-note alarms

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

### 24 — Stats and product review

- Last product-surface change: audit/reuse existing stats; prioritize useful,
  privacy-safe signals over surveillance/vanity metrics.
- Cover minimum samples, permission/relationship changes, timezone ranges,
  trends, empty states, and humane streaks.
- Research whether standalone Log Time provides enough planned-vs-actual value
  before changing or removing it.

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

Commit Item 34, then implement Item 23.
