# Checkmate handoff — 2026-09-23

## Baseline

- Branch: `main`; latest verified local commit is `5066218` (planner activity
  timelines).
- The full local verification command passed through `5066218`; remote sync and
  GitHub CI status were not re-checked in this handoff.
- Item 19 (Testmates group-plan visibility regression) is implemented in the
  working tree and is awaiting the full user-run verification command.
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

Still to do, in original order:

19. Investigate why “Plan for group” was missing for Testmates. Permission
resolution changed in `b7adf45`, so reproduce first and determine whether that
already fixed it; add a regression case for the actual cause. Investigation
confirmed the fix; the real-screen regression is awaiting verification.

21. Alarm auto-stop and missed handling: ring for at most one minute; permit
volume-down silencing where Android permits it; auto-record `Skipped: user
unavailable` when the minute expires; notify the planner; show missed tasks on
next open and mark them reviewed/skipped. They remain in normal date groups in
My Schedule. Do not promise identical volume-key interception on every Android
OEM without validating platform limitations.

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

Run the full verification command for item 19. If it passes and the user commits
it, continue with item 21: research Android volume-key constraints, then design
the one-minute timeout/missed-item state before changing native alarm behavior.

On-device feedback from the previously distributed APK may still arrive. Apply
it to the relevant roadmap item without broadening unrelated work.
