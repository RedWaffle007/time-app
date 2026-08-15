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
- **Firestore rules deployed.** Ruleset `45d5f8bc…` (2026-07-24T15:55:56Z) replaced
  the 6-day-stale `57de3ae0…`. Both the `fcmTokens` block and the item-create
  `status` constraint are confirmed present in the *deployed* source.
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
- **Group C — planner withdraw. SHIPPED + DEPLOYED** (same commits). Rules ruleset
  `1ced7bb3-ddc8-4dfe-ab27-ae35e60d4a63` (2026-07-24T21:18Z); the withdraw branch
  is confirmed in the *deployed* source and the earlier fcmTokens + item-create
  `status` blocks did not regress.
  **SUPERSEDED — `1ced7bb3…` is NOT the live ruleset.** The current deployed
  ruleset is `1cff4c97-3dbf-4e6b-abec-8d3d9a048a8e` (released 2026-08-10T18:40:31Z),
  which carries the §6/§6.1 hardening on top of the above. Quote that id, not
  `1ced7bb3…`, when reasoning about what is live. (DECISIONS.md → "Security
  hardening DEPLOYED (2026-08-10)".)
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

1. **BACKGROUNDED / killed-app delivery.** The one that actually matters. The
   verified run was *foregrounded*, which sidesteps OEM background policy entirely —
   a live process gets the message via `onMessage` regardless of Xiaomi. System-tray
   delivery to a backgrounded or process-killed app on HyperOS is **unproven**, and
   is exactly what the Autostart/battery primer is for (primer placement in
   onboarding should be decided from this test's result). Nothing in the foreground
   result predicts this one.
2. **Rules Test 3 — grant-off negative test.** With the planner grant revoked,
   confirm B's item-create is rejected `PERMISSION_DENIED`. Never run.
3. **Real two-timezone loop (build step 5g).** A genuine two-people/two-devices run
   across a **DST-observing** timezone pair (the early Chicago↔Kolkata check was
   neither a real pair nor DST-observing, so the gap/overlap rule is unverified live).
4. **iOS locale check.** Whether `CFBundleLocalizations` actually makes iOS report
   the user's language and render local digits — **blocked: no iOS target is wired
   up yet.** (DECISIONS.md, 2026-07-22.)

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

**Parked to the alarm layer (do NOT build until explicitly directed):** all alarm
firing (Xiaomi spike — the whole premise is empirically unverified), voice-mode
alarms, quiet-hours *enforcement*, boot-persistence/re-registration, and the
tz-snapshot **detect-and-re-approve** upgrade (option 3; v1 stays pure snapshot —
DECISIONS.md 2026-07-22). Card-day items (Cloud-Function push swap, CF-mediated
join) are parked to Blaze, not to now.

## Committed stack

- **Frontend:** Flutter (single codebase).
- **Backend:** Firebase — Auth + Firestore + Cloud Functions + FCM (not Supabase).
- **Push:** FCM (completion/skip notifications, invites).

## Build-order rules (enforce these)

1. **Reliable-mode alarms before voice-mode alarms.** Get one mode firing reliably and the core loop tested with real pairs *before* layering voice mode on top.
2. **Do not build any parked feature, and do not add any alarm/voice logic, until the user explicitly directs it.** This is a hard rule: no code for a parked feature or for alarm/voice behavior may be added — **not even as a stub, placeholder, TODO comment, empty function, config flag, or "while I'm here" convenience.** If something seems useful, **propose it and wait** — do not build it. Parked = streaks, gentle stakes, templates, panic mode, Cheerleader/Buddy roles, public template sharing, reactions beyond the voice note. Alarm code, voice notes, and roles come after the core loop is proven and are directed separately.
3. Suggested build order: auth+profile(tz) → groups+invites+planner-permission → schedule items + pending queue + approve/reject → reliable-mode alarms → completion/skip + planner push (test with real pairs HERE) → voice-mode alarms → quiet hours + tz warnings.

## Alarm work (when directed — not yet)

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
