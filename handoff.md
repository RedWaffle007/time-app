# Checkmate handoff — 2026-09-23

## Baseline

- Branch: `main`; clean and synchronized with `origin/main` at `eba8b32`.
- GitHub CI is green: Flutter analyze/tests, Worker tests, Firestore rules tests,
  and Android native tests.
- Latest release work added durable 1.5-second completion celebrations for both
  target and planner, including offline delivery to the planner.
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

Still to do, in original order:

15–16. Six-hour inactivity notification: about 50 short variants delivered in
sequence, repeat only after all are used, and reset the timer on real app use.

17. Collapse sufficiently long item histories into month/year groups without
breaking day ordering, deep-link scrolling, archive behavior, or accessibility.

18. Activity item detail/timeline for planners: scheduled/rang/dismissed and
done/skipped timestamps. Show reached events and keep the final outcome visibly
pending until the target actually marks the item done or skipped.

19. Investigate why “Plan for group” was missing for Testmates. Permission
resolution changed in `b7adf45`, so reproduce first and determine whether that
already fixed it; add a regression case for the actual cause.

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

Start with item 15/16 unless the user reprioritizes. First inspect lifecycle and
notification infrastructure, define exactly what counts as activity, and design
the durable per-user sequence cursor/timer before editing. Add tests first or in
the same slice; then give the user the full verification command above.

On-device feedback from the previously distributed APK may still arrive. Apply
it to the relevant roadmap item without broadening unrelated work.
