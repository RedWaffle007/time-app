# CLAUDE.md

## What this is

**time-app** — a cross-platform (Android + iOS) Flutter accountability app: trusted people build your timetable and set alarms on your device **with your consent**.

## Source of truth

- **`mvp-spec.md` is the source of truth for what to build.** Read it before implementing anything.
- **`feature-ideas.md` is the parked backlog and is NOT part of this build.** Do not implement from it.

## The core loop (everything in v1 serves this)

> A creates a group → invites B → B builds A's timetable (in A's local timezone) → A approves each item → alarms fire → A completes/skips → B is notified.

If a feature doesn't serve this loop, it's parked.

**Completion/skip → notify planner is non-negotiable** — it's what closes the accountability loop; it ships, it does not get cut.

## Status — where we actually are (as of 2026-07-22)

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

## Parked & unverified — the durable checklist (nothing gets lost between sessions)

Keep this current. Do not mark an item done until its run/decision is recorded here
or in DECISIONS.md.

**Unverified — built/deployed but never exercised end-to-end** (all block the
friend hand-off per DECISIONS.md "Outstanding verification debt"):
1. **Rules Test 2 — on-device happy path.** A creates group → B joins by code → A
   grants B planner → B creates item → A approves + marks Done → B sees outcome.
   Never run on a device.
2. **Rules Test 3 — grant-off negative test.** With the planner grant revoked,
   confirm B's item-create is rejected `PERMISSION_DENIED`. Never run.
3. **Real two-timezone loop (build step 5g).** A genuine two-people/two-devices run
   across a **DST-observing** timezone pair (the early Chicago↔Kolkata check was
   neither a real pair nor DST-observing, so the gap/overlap rule is unverified live).
4. **iOS locale check.** Whether `CFBundleLocalizations` actually makes iOS report
   the user's language and render local digits — **blocked: no iOS target is wired
   up yet.** (DECISIONS.md, 2026-07-22.)
5. **Worker deploy + `kNotifyEndpoint`.** Confirm the Cloudflare Worker is deployed
   and the app's `kNotifyEndpoint` points at the live URL, and that a real outcome
   write triggers a push. (Silent-miss gap at N=2 is knowingly accepted — see
   DECISIONS.md; this item is just "is the transport actually wired and live?")

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
