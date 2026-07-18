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
