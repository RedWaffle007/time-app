# Checkmate handoff — 2026-09-23

## Verified baseline

- Branch: `main`; latest pushed commit: `baa304e` (`Replace completion confetti
  with ballistic burst`). Worktree was clean when this handoff was written.
- Full local suite passed, GitHub CI was green, and a release APK was built,
  installed, and checked on-device. No known regressions remain.
- The 1.4-second silent completion burst was visually approved on-device.
- Current release artifact:
  `build/app/outputs/flutter-apk/app-release.apk` (generated file; a clean/build
  may replace it).
- Firestore rules changed in `01ff2b5`. A deployment command was provided, but
  successful production deployment was not explicitly confirmed in chat.

## Working agreement

- Do not run tests, commit, push, deploy, or publish. The user performs those
  actions after receiving exact commands.
- Use `apply_patch` for edits. Preserve unrelated user changes.
- Every change needs regression coverage proportional to its risk.
- Full verification command:

  ```bash
  flutter analyze && flutter test && (cd firestore-tests && npm test) && node --test worker/test/*.test.mjs && (cd android && ./gradlew :app:testDebugUnitTest)
  ```

- After a green run, provide one explicit `git add ... && git commit -m "..."`
  command. A push alone does not deploy Firestore rules or other backend state.

## Status

Items 1–21, 26, 28, and 29 are complete. Recent stability work includes native
due-time alarm delivery, single-owner alarm audio, Volume Down dismissal,
immutable outcomes, missed-alarm recovery, silent durable completion events,
the approved ballistic confetti, and the 1.5-second splash/audio fade. Details
and rationale live in `DECISIONS.md`; do not duplicate them here.

Remaining work, in intended order: **22, 23, 24, 25, 27**.

## Remaining roadmap

### 22. Friend and group pictures — next

- Fix full-screen friend-photo opening through the real Friends/Profile
  surfaces; the isolated `AvatarImage` test is insufficient.
- Add optional group avatars with owner-only upload, replacement, and deletion;
  storage authorization; list/detail rendering; and the shared viewer.
- Preserve legacy fallbacks. Test real gesture routing, ownership/rules,
  metadata validation, broken URLs, deletion, and animated formats.

### 23. Request a plan

- Create a distinct request model; do not reuse the existing permanent
  `PlanningRequest` permission model.
- Require active friendship plus an existing normal planning grant, rechecked
  when each resulting item is created. Requests grant no authority and can
  never create emergency/auto-approved items.
- Support one-plan and flexible-window modes, optional messages, multi-friend
  batches, timezone-safe start/end bounds, and non-overlapping results.
- Add durations without rewriting legacy instant-only items. Enforce bounds,
  overlap, lifecycle, and replay safety transactionally and in rules—not only UI.
- Test grants/revocation, DST, adjacency and concurrent overlap, multi-item
  fulfillment, legacy compatibility, notifications, routing, and all creation
  modes.

### 24. Stats and product review

- Do this after the preceding product work. Audit existing profile/group stats
  before extending them; avoid parallel calculations.
- Prefer useful shared signals over surveillance or vanity metrics. Cover
  privacy, minimum samples, asymmetric permissions, relationship changes,
  timezone ranges, trends, empty states, and humane streak behavior.
- Decide whether standalone Log Time earns its friction through meaningful
  planned-vs-actual insight; research before changing or removing it.

### 25. Calendar prominence

- Plan is the landing surface. Calendar already exists in its app bar and is
  duplicated under You. Confirm desired prominence with the user, then remove
  the misplaced You entry without changing the route, creation flow, Back
  behavior, bottom navigation, or notification routing.

### 27. Conditional conflict disclosure

- Replace the always-visible timetable with a day-scoped warning. Show nothing
  when the selected target has no live items that day; otherwise show one popup
  listing every conflict by localized time/date, never title or note.
- Include pending/approved outcome-less items only, using each target's timezone.
  Apply to self, individual, prefilled, and group flows; group warnings are one
  consolidated name-grouped popup. This is context, not a collision block.
- Re-evaluate when target/date/live conflicts change; suppress identical popup
  repeats. Read errors must be explicit, never treated as an empty schedule.
- Reuse authorized schedule streams and the existing live-item policy. This is
  UI minimization, not a new backend free/busy boundary.
- Test timezone/DST filtering, state exclusions, ordering/fingerprints, empty /
  one / many conflicts, mixed-zone groups, read failures, removal of the old
  timetable entry points, and successful save after acknowledgement.

## Constraints worth carrying forward

- Schedule items are under `scheduleItems/{targetUid}/items/{itemId}` and are
  currently point alarms. Item 23 must preserve legacy records.
- Friendship planning grants live under the sorted friendship document; group
  membership never implies planning permission.
- Calendar is a projection of existing streams, not a separate datastore.
- The Worker re-reads Firestore and validates actors/recipients/state; never
  trust notification or storage request payloads.
- Firestore rules and Worker policy tests are security boundaries.
- Android alarm/full-screen behavior remains OEM and permission dependent;
  automated tests cover policy/lifecycle, while device acceptance covers actual
  wake, audio, hardware keys, and visual/audio quality.

## Next session

Start item 22 by tracing friend-photo taps through the real Friends and Profile
screens, then inspect the current profile image/storage model before designing
group-avatar writes or rules.
