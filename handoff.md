# Checkmate handoff — 2026-09-23

## Baseline

- Branch: `main`; latest verified local commit is `aa6b8fc` (durable missed
  alarm handling).
- The full local verification command passed through `aa6b8fc`; remote sync and
  GitHub CI status were not re-checked in this handoff.
- Items 28–29 (early native alarm wake/fallback Dismiss and splash-ting fade)
  are implemented and fully verified in the working tree; their commit is
  pending.
- Do not assume backend/rules deployment from a Git push. Confirm with the user
  before any deployment or other external state change.

## Working agreement

- Never run tests. Give the exact command; the user runs it and returns output.
- Never commit or push. After each passing change session, give one complete,
  one-line `git add ... && git commit -m "..."` command. The user commits/pushes.
- Every feature or bug fix ships with regression-proof tests. Preserve the
  stable alarm path and avoid unrelated edits.
- Use `apply_patch` for edits. Inspect existing behavior and tests before coding.
- Full verification command:

  ```bash
  flutter analyze && flutter test && (cd firestore-tests && npm test) && node --test worker/test/*.test.mjs && (cd android && ./gradlew :app:testDebugUnitTest)
  ```

## Roadmap status

Completed and committed:

1. Show who planned an item in My Schedule.
2. Bold target names in Activity.
3. Correct future/present/past classification.
4. Use the app logo for notifications.
5. Remove notification-tap loading delay.
6. Order same-date cards latest to oldest.
7. Preserve main navigation after adding a friend.
8. Let a full alarm tone finish before repeating.
9. Correct first-install permission onboarding.
10. Add friends to an existing group.
11. Require unanimous approval for all group joins, including friend invites.
12–13. Move friend planning permission permanently to profiles; show the group
   permission control only for non-friend members, with migration and tests.
14/20. WhatsApp-style colored-paper completion celebration with a 1.5-second
   sound for the target and planner; queued durably for an offline planner.
15–16. Durable six-hour inactivity notification with 50 sequential variants and
   real-use timer reset (`0665a89`).
17. Month/year buckets for sufficiently long histories, preserving day order,
   deep links, archive behavior, and accessibility (`cdb89e8`).
18. Planner Activity detail timeline with observed ring/dismiss timestamps and
   an explicit pending outcome (`5066218`).
19. Testmates group planning visibility regression proving friendship-scoped
   permission works on the real group screen (`b6d822a`).
21. Alarm auto-stop and missed handling: one-minute native cap, foreground
Volume Down silence where Android delivers the key, durable timeout recovery,
conditional `Skipped: User unavailable`, planner notification retry, and an
app-wide next-open review card. Missed items remain in their normal date groups
(`aa6b8fc`).

Still to do, in original order:

22. Group and friend pictures:

- Fix full-screen friend-picture opening through real Friends/Profile surfaces;
  the existing isolated `AvatarImage` viewer test is insufficient.
- Add optional group avatar metadata, owner-only upload/replace/delete, storage
  authorization, list/detail rendering, and the shared full-screen viewer.
- Legacy groups use their current fallback. Test gesture routing, permissions,
  metadata validation, storage ownership, broken URLs, and animated formats.

23. Request a plan:

- X and Y must be active friends, and X must already grant Y normal “can plan
  for me” permission. A request grants no permission itself; re-check the grant
  when each item is created, so revocation stops further planning.
- Use a new model/collection, not the existing `PlanningRequest` permission
  model. One assignment per friend, linked by a batch id for multi-friend sends.
- X supplies a timezone-safe window and optional message. Multi-friend windows
  must not overlap.
- Make intent explicit rather than guessing natural-language ambiguity:
  “One plan” or “Build this time window.” Flexible requests allow one or more
  resulting items.
- Every resulting item has start and end instants, lies wholly within that
  friend’s window, and cannot overlap existing or concurrently created items.
  Extend slot-lock/transaction behavior rather than relying only on UI checks.
- Single mode fulfills atomically with its item. Flexible mode becomes
  `inProgress` while Y adds items and `fulfilled` when Y taps Finish.
- Resulting items remain normal plans requiring X’s ordinary approval; requests
  can never mint emergency/auto-approved items.
- Preserve legacy instant-only items. Define a backward-compatible effective
  interval when doing collision checks; do not silently rewrite old documents.
- Test friendship/grant gates, revocation, DST and timezone bounds, exact edge
  adjacency, overlap/concurrency rejection, replay prevention, multi-item
  lifecycle, rules, notifications, routing, and every existing creation mode.

24. Stats review and overall functional analysis — intentionally do this after
the preceding product changes:

- Assess friend-pair stats visible to X and Y, per-group stats, and broader
  friendship/relationship stats. Prefer meaningful shared signals (reliability,
  follow-through, response time, planned-vs-completed patterns) over vanity or
  competitive metrics that could encourage surveillance.
- Existing profile-stat and group-progress/leaderboard foundations must be
  audited and extended rather than replaced with parallel calculations.
- Audit privacy, minimum sample sizes, asymmetric permissions, blocked/unfriended
  behavior, timezone ranges, and whether summaries can be computed without
  exposing private schedules.
- Review visual engagement: trends, comparisons to one’s own baseline, streaks
  with humane failure handling, useful empty states, and actionable insights.
- Review the complete feature set and recommend keep/change/remove decisions.
  In particular, test whether standalone Log Time earns its friction once
  planning is mature. Likely value proposition: keep it only if it powers useful
  planned-vs-actual insight or lightweight retrospective capture; otherwise it
  risks becoming a redundant parallel workflow. Do research/analysis before
  changing or deleting it.

25. Move Calendar to the Home/landing surface. Current IA has no tab literally
named Home: Plan is the landing pillar. Calendar is already a Plan app-bar icon
and is duplicated under You. Treat this item as making Calendar clearly and
easily accessible from the landing Plan/Home surface and removing the misplaced
You entry; confirm the desired prominence (app-bar versus visible tile/button)
before changing navigation. Preserve the existing route, calendar create flow,
Back behavior, bottom bar, and notification routing.

26. Apply the completion confetti and 1.5-second celebration sound to every task
type: self-planned items, items another person planned for the current user, and
items the current user planned for someone else. The existing durable event
model may already cover one-participant self plans and both parties in delegated
plans, so reproduce each path before changing it. Add explicit repository,
queue, widget, and rules regression cases proving: self completion celebrates
once on the same device; a target celebrates immediately when completing an
incoming plan; its planner celebrates live or once on next app open; neither
party sees duplicates; skipped/rejected/withdrawn items never celebrate.

27. Conditional schedule-conflict disclosure while planning:

- Replace the always-visible/auto-open full timetable with a day-scoped conflict
  summary. Do not open or offer a timetable when the selected target has no live
  items on the day being planned.
- Once target and date are known, show a compact pop-up only when live pending or
  approved items without outcomes exist on that calendar day in the target's
  own timezone. Say who has an item and at what localized time/date; list every
  existing item, sorted by instant, without exposing titles or notes.
- Apply the same policy to self, individual, calendar/voice-prefilled, and group
  creation. For a group, evaluate each eligible target in their own timezone and
  show one consolidated, name-grouped pop-up; omit members with no items.
- Treat this as warning/context, not a collision block: current schedule items
  are point alarms and may share a time. Date/target changes re-evaluate; avoid
  duplicate pop-ups for an unchanged target/day/item-set, but alert again if the
  live conflict set changes. A read error must say the schedule could not be
  checked, never masquerade as an empty day.
- Reuse the existing authorized schedule streams and `blocksSlot` live-item
  policy. This is UI data minimization, not a tighter Firestore privacy boundary:
  planners still need the existing read permission to detect conflicts. A true
  backend free/busy-only guarantee would require a separate projection and is
  outside this item unless explicitly requested.
- Regression tests: pure target-timezone/DST day filtering, terminal/outcome
  exclusion, ordering and duplicate-dialog fingerprinting; widget cases for
  empty versus one/multiple conflicts across self, individual, prefilled, and
  group flows; group members in different zones; inaccessible schedule state;
  removal of the old auto-open grid/reopen button; and preservation of normal
  save behavior after acknowledging a warning.

28. Wake the Android screen for an alarm and expose Dismiss as reliably as the
platform permits:

  **Implemented and verified in the working tree; commit pending.**

- This is feasible as a best-effort Android feature, not an all-device
  guarantee. `Activity.setTurnScreenOn(true)` plus `setShowWhenLocked(true)` is
  the supported API on Android 8.1+ (legacy window flags below that), but it only
  helps if the alarm Activity is actually launched and visible. Android 14+
  lets the user revoke full-screen-intent access, notification/channel settings
  remain user-controlled, and OEM background policy may suppress the launch.
- The current app already applies show-when-locked, turn-screen-on, and
  keep-screen-on, but only after Flutter mounts `AlarmScreen` and invokes the
  sound channel. Move this configuration to the earliest native alarm-intent
  boundary—before Activity resume/content presentation—and apply it on both
  cold `onCreate` and warm `onNewIntent` paths. Use an explicit alarm-launch
  marker rather than waking the screen for ordinary app or notification opens.
- Keep the full-screen notification as the delivery mechanism, verify
  `canUseFullScreenIntent()` on Android 14+, and retain a high-priority,
  lock-screen-visible notification with a direct Dismiss action when full-screen
  launch is unavailable. Do not use a deprecated screen wake lock as the primary
  mechanism; the foreground service's partial wake lock remains audio/CPU-only.
- Clear turn/show/keep-screen state on every dismiss, timeout, non-alarm intent,
  and Activity teardown so later ordinary launches cannot inherit alarm window
  behavior. Do not request keyguard dismissal or bypass device authentication;
  the alarm UI may cover the keyguard, not unlock the phone.
- Regression tests: pure native alarm-intent classification (alarm versus FCM,
  ordinary launch, malformed/empty payload); a testable wake-window controller
  proving enable/clear symmetry across modern and legacy branches; cold/warm
  launch routing to the same Dismiss UI; denied full-screen permission preserving
  the actionable notification fallback; timeout/dismiss clearing flags; and the
  existing alarm-screen navigation/Volume Down behavior. On-device acceptance
  matrix: locked/unlocked × screen off/on × full-screen access allowed/denied on
  AOSP/Pixel plus Redmi/HyperOS and Motorola, with an explicit recorded result
  rather than a claim of universal support.

29. Fade the cold-start clock ting without changing the 1.5-second reveal:

  **Implemented and verified in the working tree; commit pending.**

- Keep `SplashOverlay.introDuration` at 1,150 ms and `outroDuration` at 350 ms;
  the existing exact-1,500-ms visual contract remains unchanged.
- Replace `SplashSound`'s abrupt 1,500-ms `SoundPool.stop()` edge with a short
  native volume ramp over the final portion of the same deadline, ending at
  zero and then stopping/releasing the stream. Use `SoundPool.setVolume()` on
  the active stream and cancel all prior fade/stop callbacks before replay.
- Anchor the audio deadline to the original `play` request, not delayed sample
  load completion. If preload finishes late, shorten the remaining playback and
  fade; if the 1.5-second deadline has passed, do not start a stale ting. Preserve
  the current ringer-normal check and one-shot behavior.
- Regression tests: the existing widget assertion that intro + outro equals
  exactly 1,500 ms; pure native fade-policy tests for full volume before the
  fade, monotonic ramp-down, zero at 1,500 ms, clamping, and late-load expiry;
  controller tests proving replay cancels stale callbacks and stops only the
  current stream; and mute/vibrate behavior remaining silent. On-device listen
  checks cover normal and delayed cold starts without extending the splash.

## Important architecture constraints

- Schedule items live under `scheduleItems/{targetUid}/items/{itemId}`. Current
  items store one scheduled instant; item 23 introduces bounded duration only
  with backward compatibility.
- Friendship planning grants live below the sorted friendship document. Group
  membership never implies permission to plan.
- The existing social `PlanningRequest` requests permanent planning permission;
  item 23 needs a distinct name and storage path.
- The Worker authenticates notification/storage calls and re-reads Firestore;
  never trust actor, recipient, state, or image ownership from request payloads.
- Calendar is a projection of existing streams, not a separate datastore.
- Firestore rules and Worker policy tests are security boundaries, not optional
  integration coverage.

## Next session

Commit items 28–29, then continue with item 22 (group and friend pictures).

On-device feedback from the previously distributed APK may still arrive. Apply
it to the relevant roadmap item without broadening unrelated work.
