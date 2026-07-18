# Time-Management App — Prototype (v1) Spec

## Goal of This Prototype
Prove, in priority order:
1. **People accept a friend scheduling them** (the core behavioral bet).
2. **Alarms fire reliably** across both modes and both platforms.
3. **Planners stay engaged** by seeing progress.
4. **The consent flow feels caring, not invasive.**

Scope decision: **both alarm modes + both platforms from day one.** Slower build accepted deliberately.

---

## The Core Loop
> A creates a group → invites B → B builds A's timetable → A approves each item → alarms fire → A completes/skips → B is notified.

Everything in v1 exists to make this loop work end-to-end. If a feature doesn't serve the loop, it's parked.

---

## In-Scope Features (v1)

### 1. Auth & Accounts
- Email or Google sign-in (Firebase/Supabase Auth).
- Minimal profile: name, avatar, **home timezone** (required — the premise depends on it).

### 2. Groups & Invites
- Create a group, invite by link or username.
- A group member can be granted "planner" permission over another member (simple boolean for v1 — full roles are parked).

### 3. Consent-Based Schedule Sharing
- Planner (B) creates timetable items for A: title, date/time (in A's local tz), optional note.
- Each item lands in A's **pending queue**.
- A approves or rejects **per item**. No blanket-trust in v1 — we want to observe accept/reject behavior directly (serves priority #1).
- **Quiet hours**: A sets hours during which no alarm can be scheduled; planner sees a warning if they try.

### 4. Alarms — Both Modes (per-alarm toggle)
On approving an item, A (or the default) picks:
- **Reliable mode** — native-clock handoff (Android) / robust local notification (iOS). Standard tone.
- **Voice mode** — in-app scheduled local notification carrying the planner's voice note as the sound.

See implementation notes below — this is the expensive part.

### 5. Completion / Skip → Notify Planner
- When an alarm fires, A can mark **Done** or **Skip** (with optional reason).
- B gets a push notification of the outcome. Non-negotiable — without it the planner works into a void.

### 6. Timezone-Aware Planning
- B always builds in **A's local time**, clearly labeled.
- Warn B before scheduling inside A's quiet hours or between ~11pm–6am local.

---

## Parked (explicitly NOT in v1)
Streaks · gentle stakes · templates · panic mode · Cheerleader/Buddy roles · public template sharing · reactions beyond the voice note.

---

## Alarm Implementation Notes (both modes, both platforms)

### Android
- **Reliable mode:** `AlarmClock.ACTION_SET_ALARM` intent → creates alarm in native clock. Survives app-kill. **No custom sound.** Usually shows a confirm screen.
- **Voice mode:** scheduled local notification (e.g. `flutter_local_notifications` / Notifee) with a custom sound. **Must request exact-alarm + battery-optimization exemption**; test on Xiaomi/Samsung/Oppo (aggressive killers).
- Voice note file: pre-downloaded, bundled as a notification sound resource.

### iOS
- **Reliable mode:** scheduled local notification (no native-Clock API exists). For silent-mode override, apply for **Critical Alerts** entitlement.
- **Voice mode:** local notification with custom sound — **< 30s, pre-bundled/downloaded, not streamed.**
- No handoff to native Clock is possible on iOS; "reliable mode" here just means a hardened notification.

### Cross-cutting
- Voice notes: capture, upload, and **pre-download to device** before the alarm time (never stream at fire-time).
- Store scheduled-alarm state server-side so a reinstall/device-change can re-register alarms.
- Build a test harness to fire alarms at short offsets during QA.

---

## Suggested Stack
- **Frontend:** Flutter (single codebase, strong native-alarm plugin ecosystem) — favored over RN here because of the alarm/notification plugin maturity.
- **Backend:** Firebase (Auth + Firestore + FCM) or Supabase.
- **Push:** FCM (completion notifications, invites).

---

## Suggested Build Order
1. Auth + profile w/ timezone.
2. Groups + invites + planner permission.
3. Schedule item creation (B) + pending queue + approve/reject (A).
4. **Reliable-mode alarms** on both platforms (get *one* mode firing reliably first).
5. Completion/skip + planner notification (close the loop — test with real pairs HERE).
6. **Voice-mode alarms** (the harder second mode).
7. Quiet hours + timezone warnings.

> Note: even though scope is "both modes," build reliable mode first and get the loop tested before layering voice mode on top. You can validate priority #1 after step 5 without waiting for voice.

---

## Success Signals to Watch in Testing
- Do people **approve** most items, or reject them? (Rejection rate = the core signal.)
- Do planners keep creating items after seeing the first few outcomes?
- Do alarms actually fire on testers' real devices (esp. Android budget phones)?
- Does anyone say the app feels intrusive? Where exactly?
