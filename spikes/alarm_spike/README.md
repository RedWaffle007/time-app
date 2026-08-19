# Alarm spike — throwaway, NOT the product

Answers one question with numbers instead of citations:

> **On this Redmi (HyperOS, Android 16), does a scheduled alarm actually fire
> when the app is not running — and how late is it?**

Nothing here is product code. `lib/main.dart` is a control panel with no theme
tokens, no design system and no tests, deliberately. Delete the whole
`spikes/alarm_spike/` directory when the numbers are recorded in DECISIONS.md.

Package id is `com.timeapp.alarm_spike`, distinct from the product's
`com.timeapp.time_app`, so **both install side by side**. It never touches
Firebase, the Worker, or any product data.

---

## What it measures

Four mechanisms are armed **at the same instant, in one tap**, so a single run
compares them under identical Doze depth and screen state. Comparing across
separate runs would be worthless.

| Variant | Call | Why it's in the matrix |
|---|---|---|
| `ALARM_CLOCK` | `setAlarmClock()` | Strongest primitive. Doze-exempt, user-visible (status-bar alarm icon), what shipped reminder apps use. |
| `EXACT_IDLE` | `setExactAndAllowWhileIdle()` | Exact + Doze-exempt, no user-visible claim on the device. |
| `INEXACT_IDLE` | `setAndAllowWhileIdle()` | **The baseline.** What DECISIONS.md's current plan would ship. Rate-limited to ~1 per 9–15 min in idle. |
| `WORKMANAGER` | `OneTimeWorkRequest` | The substrate DECISIONS.md names as "the reboot-durability answer". Gets a number next to the claim. |

Every fire is recorded by a **plain Kotlin `BroadcastReceiver`**, not a Dart
callback. A Dart isolate would add its own cold-start latency to every figure
we are trying to measure.

Each row records: variant, scheduled instant, actual fire instant, **delay in
seconds**, and the device state at the moment of firing — `idle` (Doze),
`power_save`, `batt_opt_ignored`, `interactive` (screen on). A 40-minute delay
is uninterpretable without knowing whether the phone was in Doze when it landed.

The log lives in **device-protected storage** so it can be written by the boot
receiver *before the first unlock*. Read it in-app (bottom card), or tap the
copy icon to put the whole CSV on the clipboard.

---

## Install

Per CLAUDE.md's Redmi quirk — if `INSTALL_FAILED_USER_RESTRICTED` appears, enable
**Developer options → Install via USB** *and* **USB debugging (Security
settings)**, which only stick while signed into a Mi account with internet.

```bash
cd spikes/alarm_spike
flutter run --release          # release, so the debug-build exemptions don't flatter the result
```

Use **`--release`**. Debug builds are attached to a debugger and are treated
differently by battery policy; a debug pass proves less than nothing here.

---

## Two traps found while verifying the build on the device (2026-08-19)

Both were observed on the Redmi itself, and either one silently corrupts a run.

**1. Reinstalling REVOKES the exact-alarm grant.** Logcat, on the install:

```
W AlarmManager: Package com.timeapp.alarm_spike, uid 10405
                lost permission to set exact alarms!
```

So `flutter run` / `adb install -r` drops you back to **G0**, no matter what you
granted before. The two exact variants then fail with a `SecurityException`,
which the app records as `SCHEDULE_FAILED` rather than crashing — but if you
weren't watching, you'd read a G3 run that was really a G0 run.
**Re-check the status card's three flags after every install, before arming.**

**2. A `BOOT` row can appear WITHOUT a reboot.** On this HyperOS build,
installing the app produced both of these within 500ms of each other:

```
...,BOOT,,,,,0,0,0,1,android.intent.action.LOCKED_BOOT_COMPLETED
...,BOOT,,,,,0,0,0,1,android.intent.action.BOOT_COMPLETED
```

No reboot happened. This matters more than it looks: "did a `BOOT` row appear?"
is the single most decision-relevant bit in Run E, and a stray install-time row
would answer it wrongly in the optimistic direction. **In Run E, check the BOOT
row's timestamp against when you actually rebooted** — not merely that one
exists.

**Also: tap the trash icon to clear the log before the first real run.** The
build was verified with a live `+2 min` arm-and-cancel, so the log already has
`APP_OPEN`, `SCHEDULE_FAILED`, `SCHEDULED` and `CANCELLED` rows in it.

## The grant matrix

Four configurations. **Run the whole test at each one, in this order** — each
adds a grant without removing the previous.

| # | Exact alarms | Battery | Autostart | What it tells you |
|---|---|---|---|---|
| **G0** | denied | Restricted (default) | off | The floor. What a user who taps through nothing gets. |
| **G1** | **granted** | Restricted | off | Isolates the exact-alarm permission's contribution. |
| **G2** | granted | **No restrictions** | off | Adds the power allowlist — which is *also* an independent route to exact alarms. |
| **G3** | granted | No restrictions | **on** | The full Xiaomi checklist. The ceiling. |

Set each from the app's own status card:
- **Exact alarm** → `SCHEDULE_EXACT_ALARM` settings screen
- **Battery** → the ignore-battery-optimizations dialog
- **Autostart** → Security Center → Autostart (falls back to App info if the
  component has moved on this HyperOS build)

The status card's three check/cross rows must read as the table says **before
you arm anything**. Screenshot it — that screenshot is the label on the run.

---

## The runs

### Run A — short, phone in use (~2 min)

1. Tap **+2 min**.
2. Leave the screen on, app foregrounded.
3. Record all four delays.

This is the sanity check, and the only cell where everything should be near
zero. If `ALARM_CLOCK` is late here, something is wrong with the harness, not
with Xiaomi.

### Run B — short, app swiped away (~15 min)

1. Tap **+15 min**.
2. **Swipe the app from recents.**
3. **Screen off. Put the phone down. Do not touch it, do not reopen the app.**
4. After the fire time, wake it and read the log.

**This is the realistic cell.** It is what actually happens to a user: the
process gets killed by the OEM, but the app was never *force-stopped*.

### Run C — force-stop (control, run once)

1. Tap **+15 min**, then **Settings → Apps → Alarm Spike → Force stop**
   (or `adb shell am force-stop com.timeapp.alarm_spike`).
2. Wait past the fire time without opening the app.

> ⚠️ **Expect nothing to fire, on every configuration including G3, and that is
> NOT a Xiaomi finding.** Force-stop puts an app into Android's *stopped state*:
> the framework **cancels its pending alarms and jobs** and delivers it no
> broadcasts until a user manually launches it again. This is stock AOSP
> behaviour and applies equally to Google Clock. Run C exists to confirm the
> harness reproduces the known behaviour — if something *does* fire after a
> force-stop, distrust the rig. **Do not read Run C as "alarms are unreliable."**

### Run D — overnight deep Doze (**the one that matters**)

1. Tap **At time…** and pick a wall time 6–8 hours out (e.g. 06:30).
2. Confirm the status card shows the run armed.
3. **Swipe the app from recents.**
4. **Unplug the charger.** Screen off. Leave the phone stationary — on a desk,
   not in a pocket. Motion resets Doze and invalidates the whole run.
5. Do not touch it until after the fire time.
6. In the morning: read the log **before** doing anything else.

Deep Doze needs the device stationary, unplugged and screen-off for a sustained
period; a phone that gets picked up at 3am never enters it and the run is void.
This is the cell where `INEXACT_IDLE` is expected to be badly late and the two
exact variants are expected not to be. **That gap is the entire decision.**

### Run E — reboot durability

1. Tap **At time…**, pick ~20 minutes out.
2. **Reboot the phone.** Do **not** unlock it, do **not** open the app.
3. Wait past the fire time, then unlock and read the log.

What to look for, in order:

- **A `BOOT` row.** Its absence is itself the headline result: on Xiaomi,
  `BOOT_COMPLETED` is blocked outright without Autostart. Expect no `BOOT` row
  at G0–G2 and one at G3. That single difference is the strongest argument for
  the OEM primer.
- **`REARMED` rows** — the boot receiver found the pending set and re-registered.
- **`MISSED_AT_BOOT` rows** — the reboot ate an alarm whose time had already
  passed. Every one of these is a reminder a real user would never have seen.
- **Whether `WORKMANAGER` fires without a `REARMED` row.** It should: WorkManager
  reschedules from its own database on boot. If it does *and* the AlarmManager
  variants don't, DECISIONS.md's "WorkManager is the reboot-durability answer"
  is vindicated. If it doesn't, that claim is wrong on this ROM and needs
  correcting.

---

## Recording the results

Copy the CSV out (copy icon → paste), then fill this in. **Delays in seconds,
`—` for never fired.** Paste the completed table into DECISIONS.md.

```
Device: Redmi ______  HyperOS ______  Android 16  Build ______
Date: ____________   Build type: release
```

| Config | Run | `ALARM_CLOCK` | `EXACT_IDLE` | `INEXACT_IDLE` | `WORKMANAGER` |
|---|---|---|---|---|---|
| G0 | A · in use | | | | |
| G0 | B · swiped, 15m | | | | |
| G0 | D · overnight | | | | |
| G0 | E · reboot | | | | |
| G1 | A · in use | | | | |
| G1 | B · swiped, 15m | | | | |
| G1 | D · overnight | | | | |
| G1 | E · reboot | | | | |
| G2 | B · swiped, 15m | | | | |
| G2 | D · overnight | | | | |
| G2 | E · reboot | | | | |
| G3 | B · swiped, 15m | | | | |
| G3 | D · overnight | | | | |
| G3 | E · reboot | | | | |
| G3 | C · force-stop | | | | |

Also record, per config: **did a `BOOT` row appear in Run E? (Y/N)** — the
single most decision-relevant bit in the whole matrix.

---

## Pass criteria — decided BEFORE the run, so the result can't be rationalised

Judged on **Run D (overnight)** and **Run E (reboot)**, at **G3** and at **G1**:

- **PASS** — an exact variant lands within **±60s** overnight, and Run E shows a
  `BOOT` row with `REARMED` rows and an on-time fire.
  ⇒ Exact alarms are real on this phone. The reminder layer is a solved problem
  and the product can promise a time.
- **CONDITIONAL PASS** — the above holds at **G3 only** (needs the full Xiaomi
  checklist).
  ⇒ Shippable, but the OEM onboarding primer stops being polish and becomes a
  **prerequisite**, and the product must show an honest per-user "reminders may
  be unreliable" state when the checklist is incomplete.
- **FAIL** — no variant lands within **±5 min** overnight even at G3, or reboot
  loses alarms at G3.
  ⇒ On-device scheduling cannot carry the product's core promise on Xiaomi. The
  fallback is a **server-scheduled FCM push** at the item's fire time (the
  Worker already exists; it would need a scheduler), which trades exactness for
  a dependency on network + FCM background delivery — and that is itself still
  unproven here (CLAUDE.md open item 1).

**The G1-vs-G3 comparison is the most valuable single number in the matrix.**
If G1 passes, exact alarms alone carry the product and the OEM primer is a
nice-to-have. If only G3 passes, every user must be walked through Xiaomi's
settings or the core promise silently breaks for them.

---

## Notes

- `POST_NOTIFICATIONS` only affects whether you *see* a heads-up. The CSV is
  written regardless — a denied notification permission does not void a run.
- The status card shows the **system's** next alarm clock. When `ALARM_CLOCK` is
  armed this should be populated and the status bar should show the alarm icon.
  If it doesn't, `setAlarmClock` silently didn't take.
- **WorkManager crashed the release build on launch once** (2026-08-19) — R8
  removed Room's generated constructor, inside an `androidx.startup` provider
  that runs before any of our code. Fixed three ways: minification is off for
  this build, keep rules exist anyway, and WorkManager is now initialised lazily
  behind a try/catch with its auto-initialiser removed from the manifest. If it
  ever fails again it costs one `SCHEDULE_FAILED` row, not the run.
- `MY_PACKAGE_REPLACED`, `TIME_SET` and `TIMEZONE_CHANGED` are also wired to the
  boot receiver. They aren't part of the matrix, but a stray `BOOT` row with one
  of those in the note column explains an otherwise confusing re-arm.
