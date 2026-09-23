# time-app — Data Model (v1)

**Status:** design doc, no app code. Firestore (committed backend). Alarm-related
shapes are marked **DESIGN-ONLY — NOT BUILT** and exist only so the model doesn't
paint itself into a corner; no alarm code follows from this doc.

Conventions:
- IDs are Firestore auto-ids unless noted.
- All timestamps are Firestore `Timestamp` (UTC) unless the field name says `local`.
- "Target" = the person being scheduled (A in the core loop). "Planner" = the
  person building the schedule (B).

---

## Collections overview

```
users/{uid}
users/{uid}/fcmTokens/{token}
users/{uid}/state/{doc}                   # per-user view state (archive)
users/{uid}/profileStats/{doc}            # SOCIAL — privacy-gated stats
inactivityStates/{uid}                    # private six-hour timer + delivery cursor
groups/{groupId}
groups/{groupId}/members/{uid}
groups/{groupId}/plannerGrants/{grantId}
joinCodes/{code}
usernames/{handle}                        # SOCIAL — uniqueness + search
friendRequests/{fromUid}_{toUid}          # SOCIAL — directed
friendships/{sortedPairId}                # SOCIAL — symmetric
blocks/{blockerUid}_{blockedUid}          # SOCIAL — directed record, symmetric effect
invites/{inviteId}
scheduleItems/{targetUid}/items/{itemId}
alarms/{alarmId}                          # DESIGN-ONLY — NOT BUILT
```

The four `# SOCIAL` collections arrived 2026-08-21 and are documented in full at
the end of this file. **They grant no planning permission.** Friendship is a
social tie; permission to build someone's schedule remains
`groups/{id}/plannerGrants`, target-granted and revocable. See DECISIONS.md
"Social profile layer".

Schedule items are keyed **under the target user** (`scheduleItems/{targetUid}/…`)
so "this data belongs to the target" is expressible as a simple ownership rule.
The cross-document part (a planner may write here only if a grant exists) is the
verbose-Firestore-rules cost we accepted in CLAUDE.md; privileged writes may go
through a Cloud Function instead of client-side rules.

## `inactivityStates/{uid}`

Private operational state; only the owner may get it, and no client may list the
collection. The app owns `uid`, `lastActivityAt`, and `nextNotificationAt`
(exactly six hours later). The notification Worker exclusively owns
`sequenceIndex`, `leaseUntil`, and `lastNotifiedAt`. Real foreground use resets
the due time without resetting the message cursor; the cursor advances only
after at least one FCM delivery and wraps after all 50 variants.

---

## `users/{uid}`

| Field | Type | Notes |
|---|---|---|
| `name` | string | Display name. |
| `avatarUrl` | string? | Optional. |
| `homeTimezone` | string | **Required.** IANA name, e.g. `America/New_York`. The premise depends on it. |
| `quietHours` | map? | `{ start: "HH:mm", end: "HH:mm" }` in the user's own home local time. Planner cannot override; only warned. |
| `fcmTokens` | string[] | Device push tokens for completion/invite notifications. |
| `createdAt` / `updatedAt` | Timestamp | |

Four more fields — `username`, `bio`, `isPublic`, `avatar` — arrived with the
social layer on 2026-08-21. They are documented in "The social layer" at the end
of this file, along with the rule that **nothing the privacy toggle governs may
ever be added to this document**.

---

## `groups/{groupId}`

| Field | Type | Notes |
|---|---|---|
| `name` | string | |
| `ownerUid` | string | Creator. |
| `createdAt` | Timestamp | |

### `groups/{groupId}/members/{uid}`

| Field | Type | Notes |
|---|---|---|
| `joinedAt` | Timestamp | |
| `status` | enum | `active` (v1 only needs this). |

Membership ≠ permission to plan. Planning permission is a separate, directed grant.

### `groups/{groupId}/plannerGrants/{grantId}`

Directed permission: `plannerUid` may build the schedule of `targetUid`, within
this group. Boolean model for v1 (full roles are parked).

| Field | Type | Notes |
|---|---|---|
| `plannerUid` | string | Who may plan. |
| `targetUid` | string | Whose schedule. |
| `granted` | bool | Active grant. Revocable. |
| `grantedByUid` | string | **Must be the target** — consent to be planned for is given by the target, not taken by the planner. (Caring, not coercive.) |
| `createdAt` / `revokedAt` | Timestamp | |

> Rule intent: only `targetUid` may create or revoke a grant over themselves.

---

## `invites/{inviteId}`

| Field | Type | Notes |
|---|---|---|
| `groupId` | string | |
| `kind` | enum | `link` \| `username`. |
| `createdByUid` | string | |
| `targetUsername` | string? | For username invites. |
| `status` | enum | `pending` → `accepted` \| `expired`. |
| `createdAt` / `acceptedAt` | Timestamp | |

---

## `scheduleItems/{targetUid}/items/{itemId}` — the core entity

Split into **commitment fields** (changing these re-triggers consent) and
**cosmetic fields** (changing these does not) — see the status model below.

**Commitment fields** (edit ⇒ reset to `pending`):

| Field | Type | Notes |
|---|---|---|
| `title` | string | What the target is being asked to do. |
| `localWallTime` | string | Wall-clock the planner set, e.g. `2026-07-20T09:00`. No offset — a wall time, not an instant. |
| `timezone` | string | IANA tz the item was **built against** — a snapshot of the target's `homeTimezone` at creation time. Stored per-item so later profile changes don't silently move existing commitments. |
| `scheduledInstantUtc` | Timestamp | Resolved absolute instant = `localWallTime` interpreted in `timezone` (DST-correct at that date). This is the source of truth for *when it fires*. |

**Cosmetic fields** (edit ⇒ status unchanged):

| Field | Type | Notes |
|---|---|---|
| `note` | string? | Note shown to the target. |
| `plannerLabel` | string? | Planner's private label. |

**Provenance / lifecycle:**

| Field | Type | Notes |
|---|---|---|
| `targetUid` | string | Redundant with path; kept for collection-group queries. |
| `createdByUid` | string | The planner. |
| `groupId` | string | Group context the planning happened in. |
| `status` | enum | See state machine. |
| `outcome` | map? | See below. Recordable in the core loop **without alarms** (Step 5 records completion/skip directly). |
| `rejectionReason` / `withdrawnReason` / `cancellationReason` | string? | Optional, per terminal transition. |
| `createdAt` / `decidedAt` / `updatedAt` | Timestamp | `decidedAt` = when the target approved/rejected. |

---

## Status model (state machine)

```
                 ┌────────────────────────── target edits consent ──────────────┐
                 │                                                               │
  (planner       ▼                                                               │
   creates)  ┌────────┐  target approves   ┌──────────┐                          │
 ───────────▶│ pending│───────────────────▶│ approved │                          │
             └────────┘                     └────┬─────┘                         │
                 │                               │                               │
   target rejects│              planner cancels  │  target withdraws consent     │
                 ▼                (before fire)   │      (before fire)            │
             ┌────────┐               ┌───────────▼──┐        ┌───────────┐       │
             │rejected│               │  cancelled   │        │ withdrawn │◀──────┘
             └────────┘               └──────────────┘        └───────────┘
             (terminal)                 (terminal)             (terminal)

             from `approved`, at/after fire time the target records an outcome:
             approved ──Done──▶  status stays `approved`, outcome = done
             approved ──Skip──▶  status stays `approved`, outcome = skipped
```

**States:**

- `pending` — created by planner, awaiting the target's per-item decision.
- `approved` — target consented. (Alarm *would* be scheduled — design-only.)
- `rejected` — target declined before ever approving. Terminal.
- `cancelled` — **planner pulls an approved item before it fires.** Terminal.
- `withdrawn` — **target revokes consent on something previously approved.** Terminal.
- Outcome (`done` / `skipped`) is recorded on an `approved` item and lives in the
  `outcome` map rather than as a status, because an item can be approved-and-fired
  yet still needs its approval provenance intact. Recording an outcome is what
  notifies the planner (Step 5).

**The `outcome` map (shape):**

```
outcome: {
  result:       "done" | "skipped",
  completedAt:  Timestamp?,   // set when result == "done"
  skippedAt:    Timestamp?,   // set when result == "skipped"
  skipReason:   string?,      // optional, only meaningful when skipped
}
```

The item's `status` stays `approved`; the outcome is a separate fact layered on
top. Keeping `completedAt` / `skippedAt` (rather than one generic timestamp) and
the optional `skipReason` means **completion timing and skip reasons survive** for
later analysis (the core accountability signal: of what the planner approved, how
much did the target complete, and when?).

**Re-approval rule (explicit):**
- Editing a **commitment field** — `title`, `localWallTime`/`scheduledInstantUtc`
  (date or time) — on an `approved` item **resets it to `pending`** for fresh
  consent.
- Editing a **cosmetic field** — `note`, `plannerLabel` — **does not** change
  status; the item stays `approved`.

**Why `cancelled` and `withdrawn` both exist:** they distinguish *who* backed out.
The app should feel caring, not coercive — a target must always be able to revoke
consent (`withdrawn`) on something they earlier approved, and a planner pulling a
plan (`cancelled`) is a different, non-punitive event. Keeping them separate lets
the UI and notifications treat them differently.

---

## Alarms — DESIGN-ONLY, NOT BUILT

Sketched so the item model above doesn't corner us. **No alarm code is written
from this.** When an item is `approved`, an alarm record *would* be created:

```
alarms/{alarmId}                         # DESIGN-ONLY — NOT BUILT
  itemId               string            # → scheduleItems/{targetUid}/items/{itemId}
  targetUid            string
  scheduledInstantUtc  Timestamp         # mirror of the item's fire instant
  mode                 enum              # "reliable" | "voice"  (per-alarm toggle)
  voiceNoteRef         string?           # storage path; pre-downloaded, never streamed
  active               bool              # false once fired/cancelled/withdrawn
  platformHandle       map?              # native-clock id / local-notification id per device
  registeredDevices    string[]?         # so reinstall/device-change can re-register
```

Server-side alarm state is retained deliberately so a reinstall or device change
can re-register alarms (per spec).

**What happens to a scheduled alarm on each terminal transition (design-only):**

| Transition | Alarm effect (when alarms exist) |
|---|---|
| `approved → cancelled` (planner) | De-register the device alarm (native-clock entry / local notification) and set `active=false`. |
| `pending → withdrawn` (**planner**) | Same de-registration, treated as **immediate**. NOTE: this row said `approved → withdrawn` (target) until 2026-08-19 and was wrong from the day Group C shipped — `withdrawn` is the **planner** retracting a plan the target has **not yet decided on** (`ScheduleRepository.withdraw`, and the withdraw branch of firestore.rules permits only a `pending` item). A target revoking consent after approving is a *different*, currently unbuilt transition. Any reminder-cancellation code that trusts the old wording would cancel on the wrong actor and the wrong state. |
| commitment edit resets `approved → pending` | Old alarm de-registered; a new one is scheduled only if/when the target re-approves. |
| outcome recorded after fire | Alarm already fired; nothing to de-register. |

---

## Timezone handling

**Planner always builds in the target's local time.** We store three things on
each item: the `localWallTime` (what the planner typed), the `timezone` it was
built against (snapshot of the target's home tz), and the resolved
`scheduledInstantUtc`. DST is handled by resolving the wall time against the IANA
zone *at that date* when computing the instant; v1 items are one-off (recurrence
is parked), so a stored instant is safe.

### DECISION — travel / target-changes-timezone

> **Question:** if a target sets a 9:00 AM item in `America/New_York` and then
> travels to `Asia/Tokyo`, does the alarm follow them (fire at 9:00 AM *Tokyo*
> local) or stay at the original absolute instant (9:00 AM New York = later that
> day in Tokyo)?

**v1 default (chosen, flagged — not buried):** **stay at the original absolute
instant.** The item is anchored to the `timezone` it was built against; we fire at
the stored `scheduledInstantUtc` regardless of where the target's device
currently is.

Rationale: it's predictable, needs no live device-timezone detection or
re-registration while travelling, and matches "the planner built this against your
home timezone." A planner across the world sees a stable plan.

**Alternative, explicitly deferred:** *follow-the-user* (always fire at the local
wall-clock time in whatever zone the device is in). Requires detecting device-tz
changes and recomputing/re-registering the fire instant — parked for a later
version.

**Related, decided the same way:** if a target edits their **profile**
`homeTimezone`, existing items keep the per-item `timezone` they were created
against (they don't silently shift); only *new* items use the new home tz.

---

## Open decisions for review

1. **Travel behavior** — v1 default is *anchor to original instant* (above).
   Confirm, or switch to follow-the-user.
2. **Quiet-hours enforcement** — spec says planner is *warned*, not blocked.
   Model assumes warn-only (item can still be created). Confirm.
3. **Privileged writes** — planner-writes-to-target's-schedule via client-side
   security rules vs. a Cloud Function. Model supports either; decide at Step 4/5.


---

# The social layer (added 2026-08-21)

Four top-level collections and one subcollection. Full reasoning in DECISIONS.md
→ "Social profile layer — SHIPPED 2026-08-21".

**The one thing to understand before reading any of it:** every document id here
is **computed from the two uids involved**, never an auto-id. Firestore security
rules can `exists()` a path they can construct and **cannot run a query**, so an
address that a rule can derive is the only way a privacy predicate is
expressible at all. `lib/features/social/domain/social_ids.dart` and the
`sortedPairId()` helper in `firestore.rules` compute the same ids and must stay
in step.

## `users/{uid}` — new fields

| Field | Type | Notes |
|---|---|---|
| `username` | string? | Canonical (lowercase) handle. A **mirror** of `usernames/{handle}`; the reservation is what guarantees uniqueness. Rules refuse a value the caller does not hold. |
| `bio` | string? | Free text, ≤ 300 chars (enforced in rules and in the field's `maxLength`). |
| `isPublic` | bool | Privacy toggle. **Absent decodes to `false`** — shipping this did not make anyone's numbers public. |
| `avatar` | map? | `{url, storageKey, mime, sizeBytes, moderation, updatedAt}`. |

There is deliberately **no `displayName`**: `name` already is one, is required,
is server-enforced and is rendered everywhere.

**Nothing that `isPublic` governs may ever be added to this document.** Its read
rule is `allow get: if signedIn()` by design (the delegation loop needs name and
timezone) and does not consult the toggle. Stats live in the subcollection below
for exactly this reason.

## `users/{uid}/profileStats/summary`

| Field | Type | Notes |
|---|---|---|
| `values` | map | `statKey → number`. Open by design — a new stat is a new key. Unknown keys are ignored on read, so an older build degrades gracefully. |
| `version` | int | Bumped only if an existing key's MEANING changes. A new key needs no bump. |
| `updatedAt` | Timestamp | |

Written **only by the owner**; read through the privacy gate:

```
blocked either way   → deny (checked first — a block outranks everything)
own document         → allow
owner isPublic       → allow      (the future leaderboard)
caller is a friend   → allow
otherwise            → deny       (a PENDING request grants nothing)
```

Fixed doc id `summary`, because `list` is denied and a visitor must be able to
name the document without enumerating.

Published rather than derived: a visitor cannot read
`scheduleItems/{owner}/items`, so they cannot compute anything.

## `usernames/{handle}`

Doc id **is** the canonical lowercased handle — that is the uniqueness
mechanism, since Firestore has no unique index.

| Field | Type | Notes |
|---|---|---|
| `uid` | string | Who holds it. Must be the caller. |
| `createdAt` | Timestamp | |

`get` open to any signed-in caller; **`list` DENIED**, which is what keeps users
un-enumerable and is why app search is exact-match only. `update` denied except
for an idempotent re-claim by the holder; `delete` by the holder only.

## `friendRequests/{fromUid}_{toUid}` — directed

| Field | Type | Notes |
|---|---|---|
| `fromUid` / `toUid` | string | Immutable. The id must equal `fromUid_toUid`. |
| `participants` | string[2] | For the inbox queries only; rules read the two fields. |
| `status` | enum | `pending` → `accepted` \| `rejected` \| `cancelled`. |
| `createdAt` / `decidedAt` / `updatedAt` | Timestamp | |

`rejected` is **stored and kept, never deleted** — deleting would let the sender
re-ask immediately and forever, turning "no" into a button that does nothing.
Rules refuse reviving a `rejected` row to `pending`. `cancelled` is distinct
because who backed out is a fact worth keeping, exactly as `cancelled` and
`withdrawn` are distinct on a schedule item.

Only the recipient may accept or reject; either party may cancel; nobody may
delete.

## `friendships/{sortedPairId}` — symmetric

Id is the two uids sorted and joined with `_`. **One document per pair.**

| Field | Type | Notes |
|---|---|---|
| `uidA` / `uidB` | string | Sorted. Which is which carries NO meaning — a sort key, not a role. |
| `participants` | string[2] | Powers `array-contains` listing. |
| `createdAt` | Timestamp | |

No status field, deliberately: this document is what every privacy rule
`exists()`-checks, and a field in that predicate would be a second thing to read
on the hot path.

Created **only by the accepting party, and only against a real pending request
addressed to them** — that check is the consent story of the whole layer.
Deleted unilaterally by either party. Never updated.

## `blocks/{blockerUid}_{blockedUid}` — directed record, symmetric effect

| Field | Type | Notes |
|---|---|---|
| `blockerUid` / `blockedUid` | string | Only the blocker may create or delete. |
| `createdAt` | Timestamp | |

Every gate checks **both** ids. `get` is allowed to either party (the blocked
client needs it to hide the profile); `list` to the blocker only.

Placing a block cascades — block doc, then planner grants both directions, then
the friendship, then pending requests — in that order, so every intermediate
state is safe. **Existing schedule items are untouched.** Unblocking restores
nothing.
