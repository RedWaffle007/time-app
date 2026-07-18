# Time-Management App — Feature Parking Lot

A place to hold every feature idea so we can pick a lean first prototype and defer the rest.

---

## Core Concept

A cross-platform accountability app where trusted people can build your timetable and set alarms on your device **with your consent**. Solves the core failure of self-managed time: it doesn't rely on the discipline you're missing. A friend across the world can plan your day and hold you accountable.

---

## Feature List

### Core (the reason the app exists)
- **Groups / trusted circles** — create groups, invite people.
- **Consent-based schedule sharing** — someone else builds your timetable; you approve.
- **Consent model (granular)** — per-item approval vs blanket trust; snooze/reject; quiet hours the planner can't override.
- **Alarms** — either handed off to the native clock app (reliable, standard tone) or fired as in-app notifications (can carry a voice note). See the alarm tradeoff note below.
- **Completion notifications** — when you finish a task, your planner gets pinged ("Sam finished his study block ✅"). Closes the accountability loop.

### Accountability & motivation
- **Streaks (shared)** — streaks between you and your planner.
- **Gentle stakes** — friendly consequences (e.g. skip 3 alarms → friend picks your Saturday).
- **Reaction / nudge messages** — attach a short message or voice note to an alarm.

### Planning power-ups
- **Templates** — publishable, reusable timetables ("exam prep week," "morning routine for night owls") that friends apply and tweak for you.
- **Panic mode** — "I have 4 free hours and no idea what to do" button that pings your group for a quick plan.

### Roles & structure
- **Roles** — Planner (can edit your schedule), Cheerleader (sees progress + reacts, can't edit), Buddy (mutual planning for each other).

### Cross-timezone (native to the premise)
- **Timezone-aware planning** — planner sees *your* local time while building; warns before setting a 3 AM alarm.

---

## Alarm Handoff — Technical Note

Handing the alarm to the native clock app and playing a custom voice-note tone are **mutually exclusive**:

- **Android** — Can create alarms in the native clock app via a public intent. Reliable, survives app-kill, but **cannot set a custom sound** (no voice note) and usually opens the clock app for user confirmation.
- **iOS** — **No API** to create native Clock alarms at all. Only option is scheduled local notifications, which *can* carry a custom sound (< 30s, pre-bundled/downloaded, not streamed). Overriding silent mode requires Apple's **Critical Alerts** entitlement (special approval).

**Design implication:** offer two modes per alarm —
- **Reliable mode** — native clock handoff (Android) / robust notification (iOS), standard tone.
- **Voice mode** — in-app notification, friend's voice note, slightly less bulletproof.

---

## Suggested Tech Stack (for reference)
- **Frontend:** Flutter or React Native (cross-platform, Play Store + App Store).
- **Backend:** Firebase or Supabase (auth, real-time sync).
- **Push:** Firebase Cloud Messaging (FCM).
- **Known hard parts:** reliable background alarms on Android (aggressive battery-killing by Xiaomi/Samsung/etc.), iOS alarm limitations, and the consent/permission UX.

---

## Goal tracking with effort stats (PARKED — do not build)

A user defines a long-running goal with a target duration and scope (e.g. "learn
Spanish, 3 months"). They log progress; the app computes:
- average effort per day and per week
- total effort logged vs. expected pace
- estimated finish date from actual pace vs. the original target
- effort/completion percentage
- trend: improving, flat, or slipping

**Decided (not open questions):**
- **Effort unit is MINUTES.** Stored as minutes always; displayed as hours +
  minutes once totals get large. Never store hours.
- **Visibility is owner-controlled and private by default.** A goal is private /
  shared-with-selected-people / public-to-group. A planner does NOT get to see a
  target's goal stats just because they hold a planner grant — visibility is a
  separate, explicit choice by the goal owner, same consent-first principle as
  `plannerGrants`. Model it as its own share list on the goal, not as a reuse of
  `plannerGrants`.
- **ScheduleItems count toward a goal ONLY if created under that goal** (explicit
  `goalId` link at creation). An unlinked item never contributes, and linking is
  not retroactive-by-inference.

**Still open for design time:**
- How progress gets logged when it isn't tied to a scheduleItem (manual entry?).
- Whether completing a linked item logs its planned duration or asks for the
  actual minutes spent.

---

## Prototype Selection — TBD

*(We'll fill this in together. Candidate MVP: groups + consent-based schedule sharing + reliable alarms + completion notifications. Everything else parked above.)*
