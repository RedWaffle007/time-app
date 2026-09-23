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

Items 1–21, 26, 28, 29, and 30 are complete. Recent stability work includes native
due-time alarm delivery, single-owner alarm audio, Volume Down dismissal,
immutable outcomes, missed-alarm recovery, silent durable completion events,
the approved ballistic confetti, the 1.5-second splash/audio fade, and shared
two-month categorization plus persistent explainer cards for Activity and Track.
Details and rationale live in `DECISIONS.md`; do not duplicate them here.

Remaining feature work, in intended order: **25, 31, 23, 27, 32, 24, 33**.
Item 22 is implementation-complete and locally verified, but its backend
deployment and real-device acceptance are intentionally deferred to the final
combined release pass after the feature list is complete.

The newly requested schedule/history pass takes priority after the current
picture work. Item 24 remains last because it is explicitly a product review of
the completed product surface, and should not be performed against UI that is
about to change.

## Remaining roadmap

### 22. Friend and group pictures — implementation complete; release gate deferred

- Fix full-screen friend-photo opening through the real Friends/Profile
  surfaces; the isolated `AvatarImage` test is insufficient.
- Add optional group avatars with owner-only upload, replacement, and deletion;
  storage authorization; list/detail rendering; and the shared viewer.
- Preserve legacy fallbacks. Test real gesture routing, ownership/rules,
  metadata validation, broken URLs, deletion, and animated formats.
- As part of this work, verify the complete profile-picture path for animated
  GIF and WebP files: picker, validation, upload, storage response, rendering,
  animation, replacement, and deletion on a real supported device. The current
  Flutter SDK explicitly supports animated GIF/WebP decoding and tests both
  codecs' loop counts, so JPEG, PNG, GIF, and WebP remain enabled pending the
  deployed real-device check. The Edit Profile helper text must list only
  formats that pass end-to-end. Remove a format everywhere if the deployed path
  cannot preserve and display it correctly.
- Implemented shared friend/group rendering and full-screen viewing, shared
  JPEG/PNG/GIF/WebP selection, owner-only group upload/replacement/deletion,
  Firestore metadata validation, Worker storage authorization, legacy/broken
  image fallbacks, exact helper copy, and regression coverage. The targeted
  Flutter suite, Firestore rules suite, Worker suite, and analyzer passed on
  2026-09-24.
- Deferred release gate: deploy `firestore.rules` and the Cloudflare Worker,
  then verify profile and group GIF/WebP upload, visible animation in list,
  detail, and full-screen surfaces, replacement, deletion, and non-owner denial
  on supported real devices. Batch this with the final feature-list acceptance
  pass as requested; do not mark Item 22 production-complete before it passes.

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

### 25. My Schedule, History, and Calendar restructure

- Keep My Schedule focused on scheduled upcoming plans only. Move elapsed and
  completed plans into a dedicated History surface; do not duplicate a plan
  between Upcoming and History. Use one explicit, timezone-safe boundary so a
  plan cannot jump into the wrong surface around midnight or DST.
- Replace the current `Today` / time-section heading on My Schedule with
  `Upcoming Plans`. Put two rounded text buttons in that same row: bold,
  all-caps `CALENDAR` in the middle and bold, all-caps `HISTORY` at the far
  right. Remove the calendar glyph from this affordance.
- History retains the current past-plan card and collapsible day UI, remains
  latest-to-oldest, shows the `Past Plans` heading, and adds localized month
  grouping the moment entries span two distinct calendar months. A feed confined
  to one month remains day-grouped, regardless of its number of entries. Preserve
  lazy building, expansion state, and empty/error behavior.
- Calendar remains a projection of existing streams. Opening a past plan from
  Calendar must route to History, expand its month/day as necessary, auto-scroll
  to the exact plan, and retain the existing temporary highlight treatment.
  Current/future plans must continue to route to My Schedule; pending items must
  continue to route to Approvals.
- Remove the old Calendar app-bar icon and the duplicate Calendar entry under
  You after the new row control is working. Preserve the existing calendar
  route, Back behavior, bottom navigation, creation flows, and notification
  routing.
- Implement in this internal order: define/test the Upcoming-versus-History
  partition; extract the History surface and route/intent; add the row controls;
  update Calendar ownership routing and deep-link scrolling; then remove the
  superseded entry points.
- Cover boundary-time and timezone/DST partitioning, latest-first month/day
  order, short and long histories, cold/warm navigation, a far-away highlighted
  plan, collapsed month/day expansion, pending-plan routing, empty states, and
  regression of the existing Upcoming outcome actions.

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

### 31. Rename the manual Plan affordance

- Replace the Plan shell's bottom-right plus-icon FAB with a bold `PLAN` label.
  Keep its existing schedule-builder destination, tooltip/semantics, placement,
  availability across all three Plan sub-tabs, and separation from the center
  voice FAB.
- Use an extended or equivalently accessible rounded button sized for text, and
  update coach marks, help copy, screenshots, and tests that refer to `+` as the
  manual planning entry point. Do not rename Track's separate log-time action.

### 32. Custom voice-note alarms

- Allow a planner scheduling for another person to record or select a custom
  voice note as a per-alarm override of that recipient's default alarm tone.
  Do not offer the override for unrelated audio surfaces or silently change the
  recipient's account-level default.
- Limit every recording to 20 seconds. Before confirmation, support playback,
  discard, and re-record. The planner may attach the one-off recording directly
  and may optionally save it to their personal voice-note library for reuse.
- When the alarm fires on the recipient's device, play the attached recording
  exactly three times, independent of clip length. End the alarm completely
  after the third playback: no default-tone fallback and no minimum alarm-cycle
  duration. Existing Dismiss and Snooze actions must interrupt playback
  immediately; a snoozed occurrence retains the same attached recording and
  receives its own three-play limit when it fires again.
- Treat the scheduled attachment as an immutable delivered snapshot, not a
  live reference to the planner's library entry. Once scheduling succeeds, the
  recipient must retain everything needed to fire it independently and offline.
  Renaming or deleting the planner's saved source must not alter any existing
  scheduled alarm. Define cleanup for withdrawn, rejected, completed, skipped,
  and permanently expired alarms without deleting bytes still referenced by a
  live recipient alarm.
- Add a dedicated Saved Voice Notes tab. The owner can listen to, rename, and
  delete recordings. Sort newest-to-oldest by save date. If no custom name is
  supplied, use a localized timestamp-derived name such as
  `Voice Note – Sep 24, 2026`.
- Activate localized month dropdowns as soon as saved recordings span two
  distinct calendar months. Keep a single-month library unwrapped and order
  both month headers and recordings newest-to-oldest.
- Keep audio bytes out of notification payloads and Firestore documents. Design
  authenticated storage, server-validated MIME/duration/size limits, planner
  ownership, recipient-scoped delivery access, retry/idempotency, and local
  durable download before considering the alarm scheduled. A notification URL
  alone is not sufficient for an offline due-time alarm.
- Integrate with the native due-alarm lifecycle and its single-owner audio
  policy. Preserve full-screen delivery, hardware Volume Down dismissal,
  missed-alarm recovery, process death/reboot recovery, and the existing
  immutable outcome rules.
- Test recording limits and permissions, preview/re-record, one-off versus
  saved selection, naming/rename/delete, two-month activation, attachment
  snapshot independence, sender deletion, recipient authorization, upload and
  download failures, offline/process-death/reboot delivery, exact three-loop
  completion for short and long clips, Dismiss/Snooze during every loop,
  concurrency/replay safety, cleanup, and default-tone regression for alarms
  without an override. Finish with real-device audio and lifecycle acceptance.

### 33. Competitor review — last

- Direct competitors identified by the user: **PingPal** and **SnoozeSquad**.
- Return to these only after every preceding roadmap task is complete. At that
  point, compare positioning, planning/alarm flows, social permissions, custom
  audio, pricing, privacy, reliability expectations, and meaningful product
  gaps using current first-party store/site evidence. Do not copy branding or
  interaction details merely for parity.

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

Commit the locally verified Item 22 implementation, then proceed to Item 25.
Keep Item 22's Firestore/Worker deployment and real-device GIF/WebP acceptance
on the final combined release checklist after all feature work is complete.
