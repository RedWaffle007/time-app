# Decisions — reasoning log

Full rationale for architectural choices. CLAUDE.md holds the terse one-liners;
this file holds the "why" so it doesn't load every session. Newest at the bottom.

---

## Backend = Firebase (not Supabase)

Auth + Firestore + Cloud Functions + FCM.

The completion→planner push is non-negotiable in the spec, and FCM fires natively
from a Firestore write via a Cloud Function — one integrated pipeline, no
self-hosted server. Supabase would still need FCM wired by hand (Postgres trigger
→ Edge Function → own FCM creds).

**Trade-off accepted:** Firestore security rules for the consent/permission model
are more verbose and error-prone than Postgres row-level security. Mitigate by
(a) keying schedule items by target-user id for simple ownership rules and
(b) routing privileged writes through Cloud Functions.

## State management = Riverpod

Compile-safe, testable without a `BuildContext`, and `StreamProvider` maps cleanly
onto Firestore real-time streams (pending queue, outcomes). Kept deliberately
plain while the user learns it — no families/autoDispose/code-gen until a screen
genuinely needs it.

## Routing = go_router

Official router with first-class deep-link support, needed later for
invite-by-link.

## Feature-first folder layout

`lib/features/<feature>/presentation/`; `data/` + `application/` added per feature
as backend wiring lands.

## Auth = Google Sign-In only for v1 (email/password deferred)

Avoids building sign-up/reset/verify screens (less solo-dev code), gives one-tap
join for the invite-by-link flow, and is smoother for recruiting test pairs. Cost:
a one-time debug SHA-1 registered in the Firebase console (and re-run
`flutterfire configure` after adding it). Email/password is easy to add later if a
tester can't use Google.

## Firebase config via FlutterFire CLI

`flutterfire configure` registers the app and generates config, instead of manual
`google-services.json` placement. Re-run it after adding a SHA-1 so the Android
OAuth client lands in the config.

## Firestore in TEST MODE (rules pending) — RESOLVED 2026-07-18

~~Currently open read/write~~ — superseded by **Firestore security rules — v1**
(below), deployed 2026-07-18. Test mode is no longer in effect.

## minSdk = 23

Set in `android/app/build.gradle.kts`; required by Firebase Auth 6.x.

## Firestore security rules — v1 (deployed 2026-07-18)

`firestore.rules` written and deployed to `time-app-1e1c9`; **replaces TEST
MODE.** Rules mirror the app's actual read/write paths exactly (per
`lib/**/data/*_repository.dart`), so every real query is provably safe and
nothing extra is opened up.

Model:
- **users** — profile read = **any signed-in user** (name/avatar/home tz);
  writes owner-only. *(Decision ① — auth-gated read.)*
- **groups** — group doc (name, joinCode, memberUids) readable by any signed-in
  user so join-by-code can look it up; create only as owner + sole first member;
  the only permitted UPDATE by a non-member is a **self-join** that adds *only*
  the caller to `memberUids` (enforced: single-element diff, caller not already
  present). *(Decision ②.)*
- **members / plannerGrants / scheduleItems** — relationship-gated.
  - members: readable by group members; a user writes only their own member doc.
  - plannerGrants: **target-only consent** — caller must be the `targetUid` and
    the recorded `grantedByUid`, and both parties must be group members. Read by
    the planner/target of the grant or any group member.
  - scheduleItems: create by the creator, who is either the target or a planner
    holding an **active grant** over the target in the item's group; update is
    **target-only** (approve/reject/done/skip); createdByUid/targetUid can't be
    forged.

**Collection-group reads need `{path=**}` rules (fixed 2026-07-18).** Two screens
issue `collectionGroup` queries — Planner Activity (`items` where
`createdByUid == me`) and Schedule Builder (`plannerGrants` where
`plannerUid == me`). Root cause of the `permission-denied`: **a `collectionGroup()`
query is matched ONLY by a rule written with a recursive `{path=**}` wildcard;
a rule scoped to a specific parent path (`/scheduleItems/{targetUid}/items/...`)
never matches it, regardless of the condition** — so there was literally "No
matching allow statements." This is about the match PATH SHAPE, not the
condition. (Two earlier hypotheses were wrong: it was not a `resource` vs
parent-wildcard mix, and splitting one `allow` into two changed nothing —
verified on the Firestore emulator.)

Fix — keep the specific-path rules for DIRECT/path-scoped reads + writes, and add
top-level recursive rules for the collection-group reads:
```
match /{path=**}/items/{itemId} {
  allow read: if signedIn() && resource.data.createdByUid == request.auth.uid;
}
match /{path=**}/plannerGrants/{grantId} {
  allow read: if signedIn()
    && (resource.data.plannerUid == request.auth.uid
        || resource.data.targetUid == request.auth.uid);
}
```
`resource.data`-scoping DOES work for collection-group lists, so the model stays
restrictive: the client query must filter on the same field (the app's queries
do), and a user can read only items they created / grants naming them. No
denormalization needed (`createdByUid`, `plannerUid` already on the docs). Reads
were NOT opened to any-signed-in.

**How it was verified (do this, not console-eyeballing):** the Firestore emulator
(`firebase emulators:start --only firestore`) loads the real `firestore.rules`,
and its `emulator/v1/.../:securityRules` endpoint hot-swaps rulesets for a fast
loop. Ran the exact query shapes with a mock ID token, seeded a group/grant/item
as admin, and asserted ALLOW **plus negative controls** (can't read others'
items/grants, unfiltered collection-group query denied, non-member roster denied)
before deploying. The Rules **test API** / Playground could NOT verify this — they
evaluate `list` with `resource == null`, so they falsely deny any resource-scoped
list. See also the "diagnostic hazard" note below.

Deferred hardening (logged, not built):
- **Cloud-Function-mediated join** — server-validated "add only yourself" instead
  of a client `arrayUnion`. Needs the **Blaze** plan. The current rule already
  proves the self-join is single-element and caller-only, which is sufficient
  for v1; the CF version is the tighter form.
- **"Share-a-group" profile-read scoping** — restrict profile reads to users who
  share a group with the owner, rather than any-signed-in. Tighter than Decision
  ①; deferred.
- **Planner cancel/edit of an approved item** — the data model allows
  `cancelled`/`withdrawn` and commitment-edit → `pending`, but there is no code
  path yet, so item UPDATE is target-only for now. Widen the rule when that step
  is built.
- **Emulator rules unit tests** (`@firebase/rules-unit-testing`) — deferred; v1
  is verified by an on-device happy-path run plus manual negative tests
  (unauthenticated write blocked; grant-off write blocked).

---

# Plan / sequencing

## Validate the loop with a real friend BEFORE building alarms

Once security rules are in, test the current loop (no alarms — in-app reminders
only) with **one real friend** before investing in alarm work. The behavioral bet
("people accept a friend scheduling them") matters more than the alarm feature; if
that bet fails, the expensive alarm work is wasted. Alarms come *after* this test.

---

# UI: no silent infinite spinners (AsyncView)

All list/stream screens render through `lib/core/widgets/async_view.dart`, which
adds a **loading timeout** on top of the usual loading/error/empty states: if a
Firestore listener sits in `loading` past ~12s with no data or error, the screen
shows an actionable "taking longer than expected → Retry" instead of spinning.

**Why:** a Firestore `.snapshots()` listener does NOT surface `UNAVAILABLE`
(network) errors to the stream — it retries silently — so a query with no cached
data to fall back on hangs forever with no error. First seen 2026-07-18: the
planner's two collection-group screens (Schedule Builder, Planner Activity) spun
forever on the Redmi while every other screen worked.

**There were TWO stacked bugs, and the outer one hid the inner one:**
1. **App-scoped network block** — the device OS resolved `firestore.googleapis.com`,
   but the app process could not (HyperOS per-app network restriction). This made
   the listeners retry silently and never emit — a spinner with no error. Cached
   screens rendered; uncached collection-group queries hung.
2. **A real collection-group rules denial** (below) — once the network block was
   cleared, the true error surfaced immediately: `permission-denied`.

The timeout does not fix either bug; it makes both *visible* (spinner → error or
retry) so we stop mistaking a backend problem for a broken app.

## Diagnostic hazard: an offline app makes rules tests lie

While the network block (above) was in effect, a "broaden the rules to any
signed-in user" test was deployed to check whether permissions were the cause.
It changed nothing — but **only because the app couldn't reach the server at
all**, so no rule (loose or strict) could have mattered. That falsely exonerated
the rules. **Rule: never conclude "not a permissions problem" from a live-app
test until the app is confirmed to be actually reaching Firestore** (a genuine
`permission-denied` error, or a server-side query that returns). An
infinite/silent spinner means "no answer," not "allowed."

# Outstanding verification debt (UNPAID)

Things that are **built/deployed but not yet exercised end-to-end.** Listed here
so they stay visible as debt — do NOT treat any of these as "done" until the run
is actually performed and the result recorded.

**Deadline — Tests 2 & 3 are due BEFORE the debug APK goes to the friend, not
after.** A build must not reach a real user while the rules protecting their data
have never been exercised end-to-end. (The APK can be built and self-tested
first; the gate is the hand-off to the friend.)

- **Firestore rules — on-device happy path (Test 2).** Rules deployed 2026-07-18
  and verified only against an unauthenticated caller (Test 1: anon read + write
  both 403). The two-account happy path — A creates group → B joins by code → A
  grants B planner → B creates item → A approves + marks Done → B sees outcome —
  has **not** been run on a device. Until it is, "the rules don't break the app"
  is unproven.
- **Firestore rules — grant-off negative test (Test 3).** Not run. Need to
  confirm that with the planner grant revoked (`granted:false`), B's item-create
  is rejected with `PERMISSION_DENIED`.
- **Cross-timezone planning (build step 5g) — real two-timezone run.** An early
  on-device resolution check was done with a Chicago planner + Kolkata target,
  but the user is (correctly) tracking the full step-5g run as **not yet paid**:
  it has not been exercised as a real two-people / two-devices loop, and neither
  side of the earlier check sat in a DST-observing zone, so the known DST
  gap/overlap edge case (below) is still completely unverified. Do not mark 5g
  done until a run across a DST-observing timezone pair is recorded.

# Open questions (unresolved)

## Consent setup: toggle vs. "planner requests → target approves"

**Current:** the target flips a per-member "can plan for me" switch to grant
consent (built in 5c).

**Concern:** the product vision is a friend taking initiative to help someone
who's *overwhelmed* — but the toggle puts all setup burden on the person least
likely to do it (the target). A **request model** (planner asks → target taps
approve) may fit the vision better by letting the initiator drive.

**Decision deferred** until after the first real end-to-end test — decide from how
the loop actually feels, not in the abstract. Do not rebuild before then.

## DST-invalid / ambiguous local times (known edge case, unhandled)

Resolving a wall-clock time in a zone can hit two DST problems:
- **Invalid/skipped** — the wall time falls in a spring-forward gap (that local
  time never occurs).
- **Ambiguous** — the wall time falls in a fall-back overlap (it occurs twice).

`resolveWallTimeToUtc` currently just trusts `TZDateTime`'s default resolution and
does not detect or warn about either case. **India (Asia/Kolkata) does not observe
DST, so this won't bite the first test** — but it must be handled before testing
with anyone in a DST-observing zone (US/EU/etc.). Handling = detect the gap/overlap
and either warn the planner or pick a defined rule.
