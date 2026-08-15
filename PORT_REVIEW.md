# PORT_REVIEW.md

A second pass on the Flutter → React Native question, written 2026-08-12 against
`feat/notification-events` (`37c9856`). This is not a plan. It is the reasoning
behind the recommendation, the diagnosis of what is actually wrong, and a method
you can run yourself next time.

Where this document cites a fact, I re-checked it in the code rather than
trusting PORT_PLAN.md or ARCHITECTURE.md. Where the two documents disagree with
the tree, the tree wins.

---

## 1. The recommendation, restated

**Stay on Flutter. Do not port.**

I wrote §5 of PORT_PLAN.md and I am not softening it. If anything, re-reading the
code has made the recommendation stronger, not weaker.

Let me name the thing you named, because you were right to name it. The commit
message on `37c9856` — the most recent commit, the one that contains
ARCHITECTURE.md itself — reads *"cleaned some security and client side problems
and now ready to rebuild before migration."* The decision to migrate was written
into the repository **before** the analysis of whether to migrate was finished.
That is the shape of a decision looking for evidence. So: no, this is not
permission. The answer is still don't.

### The three strongest pieces of evidence for staying, from this codebase

**1. The product's namesake feature is unbuilt, and you would be porting away
from the framework that is better at it.**

The app is called `time-app` and its premise is alarms firing reliably on a
Xiaomi HyperOS device. There is no alarm code — by explicit policy, CLAUDE.md
parks the entire layer. What exists today is `OutcomeScreen`: a checklist you
open manually and tap. Every one of the 4,512 lines in `lib/` is preamble to a
feature that has not been written.

So the port's real cost is not "rebuild what exists." It is "rebuild the
preamble, then attempt the hard part in the worse ecosystem." Flutter gives you
`android_alarm_manager_plus`, `flutter_local_notifications` with
`AndroidScheduleMode.exactAllowWhileIdle`, boot-receiver re-registration, and
direct Kotlin whenever the OEM fights you. `expo-notifications` has no
`setExactAndAllowWhileIdle` path with a custom sound surviving Doze — you would
be writing a native module, which is the one thing this port otherwise
gracefully avoids.

This is the argument that would settle it on its own. You are considering
changing frameworks immediately before the step where the framework choice
matters most, and changing it in the wrong direction.

**2. iOS is not hard because of Flutter. iOS has never been configured.**

I checked this rather than believing it. `ios/Runner/` contains
`AppDelegate.swift`, `SceneDelegate.swift`, `Info.plist`, the asset catalog and
the generated plugin registrant — and **no `GoogleService-Info.plist`**.
`lib/firebase_options.dart:28` hits `case TargetPlatform.iOS:` and throws
`UnsupportedError('DefaultFirebaseOptions have not been configured for ios')`.

The app has never launched on iOS. Not once. Whatever you experienced as "iOS
getting hard," it was not Flutter's iOS support, because Flutter's iOS support
has never been exercised here. It was the setup step, and the setup step is
`flutterfire configure` plus registering an iOS app in the Firebase console.
Hours.

The detail that makes this sharp: `Info.plist` has been hand-edited with a
~80-entry `CFBundleLocalizations` array for the worldwide-formatting
requirement. Someone did careful iOS work that has never been verifiable,
because the app cannot start. That is a configuration gap wearing the costume of
a framework problem.

And the parts of iOS that are genuinely painful — the $99 Apple Developer
Program, provisioning a physical device for push, the APNs `.p8` key, needing a
Mac, App Store review — are byte-for-byte identical under Expo. Expo's real iOS
wins are exactly two: EAS Build (CI without owning a Mac) and EAS Update (OTA JS
patches). Both real. Neither touches what you described.

**3. The defects a port fixes "for free" are hour-scale in place; the defects
that actually threaten this project survive the port untouched.**

`MainActivity.kt` is three lines of body. The `FLAG_SECURE` handler that
`lib/features/applock/data/secure_window.dart:22` has been calling into the void
is about 30 lines of Kotlin in `configureFlutterEngine`. That is the port's
single clearest technical win, and it is an afternoon in the app you already
have.

Meanwhile, the list that survives a rewrite unchanged: backgrounded/killed-app
push delivery on HyperOS (CLAUDE.md open item 1, never run — OEM battery policy
does not care what drew your UI); the Worker's zero test coverage (664 lines
holding all notification policy, no `package.json`, no test runner); the
grant-off negative rules test (never run); the four-event retest (blocked on a
second person, since every event requires `creator != target`); the two-timezone
DST loop test, which the port makes *worse* because PORT_PLAN §2.4 swaps the
resolver engine, so it would validate code that has never run on a real pair.

Those are the actual risks in this system. The port addresses none of them and
degrades one.

### The three strongest arguments against my position

I would rather state these properly than strawman them.

**1. The codebase is genuinely portable, and that is rare.** I verified the
grep results: zero `CustomPaint`, zero `AnimationController`/`Tween`/
`Transform`/`Hero`, no custom `RenderObject`s, no `dart:ffi`, no code
generation, 62 files with exactly one production file over 300 lines, and one
platform channel that is already dead. The usual reason Flutter→RN rewrites
collapse — a custom-painted chart, a bespoke animation system, a pile of native
interop — does not exist here. If you are going to do this, this is the codebase
you can do it with.

I have to be precise about what this proves, though, because it is the most
seductive fact in PORT_PLAN.md: it establishes **feasibility, not
justification.** "This would work" and "this is worth doing" are different
claims, and conflating them is the single most common error in rewrite
decisions.

**2. TypeScript/React genuinely has more surface for AI assistance.** This is
not a vague vibe. RN + Expo + Firebase-JS has far more public example code than
Flutter + Riverpod 3 + FlutterFire, and Riverpod 3 in particular is recent
enough that the training data is thin. First-draft quality would likely improve.
If your bottleneck really is "the model writes code I can't evaluate," a stack
where the first draft is more often correct is a real, if modest, help. I am not
going to tell you your experience of the last two months was imaginary.

**3. The layer boundaries would become visible.** You said you are learning
architecture fundamentals. Riverpod does three different jobs — dependency
injection, reactive server state, derived computation — behind one word,
`Provider`. That makes it excellent to *use* and poor to *learn from*. Splitting
into TanStack Query (server state) / Zustand (client state) / pure selector
functions forces you to name which of the three you are doing, every time. That
is a genuine pedagogical benefit and it is the best argument in favour of the
port that has nothing to do with the code.

It is also, as §3 shows, mostly available to you in Dart.

---

## 2. What your real problem is

You gave four candidate diagnoses. Ranked by weight of evidence in the code:

### (d) The workflow — **dominant, by a wide margin**

Bluntly, as you asked: this is the problem, and it ports to React Native
completely unchanged.

**The single most diagnostic artifact in the repository** is
`test/app_lock_test.dart`. It is 587 lines — the largest file in the project,
larger than any production file by 70% — and part of it asserts that `start()`
"re-applies `FLAG_SECURE`" against a *fake* `SecureWindow`. I grepped the whole
tree for `time_app/secure_window`: it appears in exactly one place,
`secure_window.dart:22`, on the Dart side. There is no Kotlin handler.
`MainActivity.kt` is `class MainActivity : FlutterActivity()` and nothing else.

So the test suite proves that the Dart calls a method that lands nowhere, and by
proving it, made a feature that does nothing look covered. `AppLockTile` tells
the user it "hides the app from the recents switcher and blocks screenshots."
It does neither. The tests are why nobody noticed.

That is the whole failure mode in one artifact: **work was generated,
mechanically verified against its own assumptions, and never checked against
reality.** No language changes that.

The supporting evidence is consistent:

- **Coverage is inverted, and the inversion has a signature.** 5 test files,
  1,354 lines. App lock (587) and archive isolation (321) — the two most
  recently built and most intellectually satisfying features — hold 908 of them,
  67%. All five repositories: zero. Every screen except the lock: zero. The
  `write → notify` pairing: zero. `core/timezone/quiet_hours.dart` — 59 lines of
  pure integer arithmetic with a wrap-past-midnight edge case, the single
  easiest testable thing in the repo: zero. Tests were written when the feature
  was *interesting*, not when the risk was high. That is a choice pattern about
  attention, not a property of Dart, and you would repeat it verbatim in Jest.

- **The documentation grew faster than the software.** 3,364 lines of markdown
  against 4,512 lines of Dart. `DECISIONS.md` alone is 2,068 lines and 125 KB —
  six times the largest source file. When a project's response to "I can't keep
  up" is to write more prose about the code, the prose becomes the second thing
  you can't keep up with.

- **The verification backlog is three weeks stale.** CLAUDE.md's "Parked &
  unverified" list has four items open since 2026-07-25, and the most important
  one — backgrounded push on the Redmi, the one the product depends on — has
  never been run. CLAUDE.md itself states the rule: an item isn't done until a
  dated run sits next to it. The rule is right. It has been slipping.

Read together: **generating work outpaced verifying it.** A rewrite resets the
code and keeps the process. Six weeks from now you would be here again, with
less working software and staler documentation.

### (c) iOS is toolchain/config, not code — **strongly supported, but narrow**

Fully evidenced (§1 above): no plist, `firebase_options.dart` throws, never
launched, ~80 hand-written `CFBundleLocalizations` entries that have never been
observable. This is real and it is fixable in a day.

I rank it second rather than first only because it is *narrow*: it explains the
iOS half of your motivation completely, and none of the rest. And it is not an
argument for the port, because the port does not fix it either — Expo needs the
same Apple account, the same provisioning, the same APNs key, the same review.

### (b) The architecture makes changes hard regardless of language — **real, moderate, and language-independent**

This one is genuinely true and worth acting on. I verified the sharpest case by
grep: `notify(` appears at six call sites, and **every one of them is in a
`presentation/` file** —

```
schedule_builder_screen.dart:99
pending_approvals_screen.dart:115, 147
outcome_screen.dart:156, 189
planner_activity_screen.dart:169
```

Reading `pending_approvals_screen.dart:112-120`, the pattern is "await the
repository, then await the notifier," hand-written, with a nice comment
explaining the semantics. It is correct in all six places. Nothing enforces it,
nothing tests it, and one forgotten paste silently kills an entire event type
with no symptom except a push that never arrives.

Around it: item filters inlined in four screens, `_reasonLine()` duplicated
verbatim between `planner_activity_screen.dart:188` and
`archived_screen.dart:135`, three structurally identical reason dialogs, the
pending count computed twice, two different idioms for "get the current uid,"
three different error presentations, and anaemic repositories with no service
layer to catch any of it.

But note what this is: business logic living in widgets. That is a design
choice, and every fix for it is expressible in Dart. It is not evidence for
TypeScript. It is evidence that you have found a real architecture lesson —
which is the thing you said you wanted to learn.

### (a) The Flutter/Dart stack is a poor fit for AI-assisted development — **weakest, and the code actively contradicts it**

If AI assistance had been producing Dart you couldn't manage, the repository
would show it. Look for the damage: 800-line god-screens, dead branches,
inconsistent layering, analyzer noise, abandoned half-features.

It isn't there. `flutter analyze` reports no issues. 66/66 tests pass in ~2s.
*(Amended 2026-08-14: 65/65 — the deleted test was a fake `FLAG_SECURE`
assertion, and the routing dead end this review discusses is now fixed in Dart.
This document is otherwise left as written, as a point-in-time review.)*
Sixty-two files, and exactly **one** production file exceeds 300 lines
(`schedule_builder_screen.dart`, 344). Nine features, all shaped identically as
`domain/data/application/presentation`, with layers omitted only where they'd be
empty. No `build_runner`, no `freezed`, no `mockito` — deliberate restraint at
this size. `family` used in exactly three places where the parameter is real.
Roughly 21% of `lib/` is comments, and they are multi-paragraph justifications
with cross-references, not `// increment i`.

This is disciplined code. Whatever you could not keep up with, it was not the
quality of what was generated. The evidence says generation went *well* and
verification did not happen.

The one honest point for (a): Riverpod 3 is new and the model's grasp of it is
thinner than its grasp of React. That is a real friction. It is not a
four-to-eight-week friction.

**Ranking: (d) ≫ (c) > (b) ≫ (a).** And since (d) dominates: yes, bluntly, a
rewrite carries your actual problem to React Native intact, and hands it a fresh
codebase with no tests at all to practise on.

---

## 3. What a port would and would not buy you

The distinction you asked for is the right one, and it does most of the work
here. For each claimed benefit: does it come from **the framework change** or
from **rewriting with better structure**? Only the first requires switching
languages.

| Claimed benefit | Source | Available in Flutter today? |
|---|---|---|
| EAS Update — ship a JS fix without store review | **Framework.** No Flutter equivalent exists | ✗ genuinely unavailable |
| Notification-tap dead end becomes structurally impossible | **Framework.** A file is inside `(tabs)/` or it isn't; you cannot register a screen twice | ✓ fixed today by `StatefulShellRoute` (~half a day) |
| `FLAG_SECURE` really applies on Android | **Framework/ecosystem** — `expo-screen-capture` exists | ✓ ~30 lines of Kotlin, one hour |
| EAS Build — iOS CI without owning a Mac | **Framework-adjacent** (Codemagic does this for Flutter, less turnkey) | ~ partial |
| Better AI first drafts | **Framework.** Larger public corpus | ✗ real, but unquantified |
| Four `TextEditingController` leaks vanish | **Framework.** React has no imperative object to forget | ✓ 15 minutes |
| `write → notify` cannot be skipped | **Restructuring.** Nothing in TS enforces it; a mutation hook is a *design* | ✓ one day, in Dart |
| Filters become pure, fast-testable selectors | **Restructuring.** Pure Dart functions test in milliseconds too | ✓ |
| Parse-don't-cast at the Firestore boundary | **Restructuring.** zod is better ergonomics, not a new capability — and Dart's sound null safety means you start *ahead* of TS-without-`strict` | ✓ |
| `fromDoc` stops inventing a timestamp | **Restructuring.** `?? DateTime.now().toUtc()` → return null and report | ✓ 30 minutes |
| Pagination seam on the repositories | **Restructuring.** `limit()` is one line per query | ✓ |
| One error presentation, one uid accessor | **Restructuring.** | ✓ |
| Visible layer boundaries (Query / Zustand / selectors) | **Mostly restructuring.** The framework's contribution is that it *forces* the naming; you can impose the same three boxes in Dart | ✓ with discipline |
| Release signing via managed credentials | **Framework-adjacent** | ✓ a proper keystore is ~an hour |

Thirteen benefits. **Three come from the framework itself** (OTA updates, the
routing structural guarantee, better AI corpus), and two of those three have
hour-scale Flutter equivalents. The rest is architecture you could do this week,
in Dart, and would learn more from because you'd be changing a system you
already understand rather than re-typing one.

**What the port buys you that nothing else does: EAS Update.** That is the
honest, complete list. For a solo dev shipping to two friends' phones it is
genuinely nice. It is not four to eight weeks nice.

**What it does not buy you, restated so it can't quietly slip back in:** alarms
(harder), HyperOS background delivery (unchanged), the Worker's zero coverage
(unchanged), all four CLAUDE.md open items (unchanged, one degraded), the
profile-read residual (a data-model change, out of scope), the second-person
blocker (unchanged), iOS screenshot blocking (impossible on iOS regardless), iOS
recents blanking (still new work you'd have to write), and dependency drift —
41 outdated pub packages become a fresh `package.json` that starts drifting on
day one, plus an annual Expo SDK upgrade with real breakage. That is a reset,
not a fix.

---

## 4. What you would lose

**Time — specifically.**

PORT_PLAN §4 estimates 21–37 focused days across M0–M7, which is 4–8 calendar
weeks solo. Weight that estimate correctly: **I wrote it, and I wrote it while
scoping the work.** Rewrite estimates produced by the person scoping the rewrite
are systematically low, because the unknown work is by definition the work
nobody has looked at yet. Treat 21–37 days as a floor, not a range.

Now the alternative, priced the same way:

| Work | Cost |
|---|---|
| Configure Firebase for iOS, launch the existing app | 1 day |
| ARCHITECTURE §5 items 3–8 (`FLAG_SECURE` Kotlin, nav dead end, `write→notify`, `limit()`, `fromDoc`, controllers, duplicated filters) | 2–4 days |
| Core-loop tests: approve / reject / done / skip / withdraw, plus repositories against the emulator you already run for `firestore-tests/` | 2–3 days |
| The PORT_PLAN §3.5 architecture changes, in Dart | ~1 week |
| **Total** | **~2–3 weeks, for strictly more value** |

Roughly a third of the cost, and it ends with a *verified* app rather than an
unverified one.

**66 passing tests → 0.** And notice the trap in the consolation: the tests
worth re-implementing are the ones covering app lock and archive — features that
ship no product value. The tests you actually need, on the core loop, don't
exist in either world. The port does not hand them to you; it just deletes the
908 lines you did write.

**1,408 lines of comments — the *why*.** This is the loss I'd weight highest
after time, because it is the one that is invisible until it's gone. These are
not decoration. `_leftAt` carries a paragraph on why the grace window must never
be persisted. `archivedIdsStreamProvider` carries one on which direction a
failure must degrade. `_wall()` carries one on why the `DateTime` must be
UTC-kind — because a local `DateTime` would be silently normalized by the
*planner's* DST rules, which is a bug somebody found the hard way and then wrote
down so it could never be found again. The record/view split carries a loud
comment stating that any future stats consumer must read the record layer.

Those survive a port only if you carry every one across by hand, and a rewrite
is precisely the situation where the temptation is to write fresh code and
re-derive the reasoning later. The reasoning does not get re-derived. It gets
re-discovered, as bugs.

**3,364 lines of design documentation go stale on day one.** ARCHITECTURE.md,
DECISIONS.md and UI-RULES.md are dense with file paths and line numbers. After
the port every one of those references is wrong, including the ones in the
document arguing for the port.

**Dart and its ecosystem.** You currently know Riverpod's provider graph,
go_router's redirect model, FlutterFire's quirks, the `timezone` package,
Flutter's `ThemeData`/`ColorScheme` inheritance. That knowledge was expensive.
You would pay the tuition a second time, in a stack where the theme layer in
particular has no equivalent primitive at all — PORT_PLAN §2.3 is right that
`lib/core/theme/` (1,045 lines, plus 384 lines of tests, plus 584 lines of
UI-RULES.md) is the most carefully built asset in the repo and the most
Flutter-coupled. Rebuilding it lands in week one, is the least rewarding work in
the plan, and is where motivation goes to die.

**And one nobody lists: momentum against a specific queue.** CLAUDE.md has a
real build order — icons (done), archive + app lock (done), goals next — gated
behind a real-pair validation that has been waiting since July. A port pauses
all of it for two months and returns you to exactly the same gate, still
unopened.

---

## 5. The method — so you can run this yourself

Here is the actual sequence I used. It generalizes; the questions matter more
than my answers to them.

### The seven questions I asked of the code

**1. What is the hardest thing this product has *not yet built*, and which
option is better at that?**

Rewrites are cheap for what exists and expensive for what comes next, so
evaluate the framework against your **roadmap, not your backlog**. Here: the
roadmap's headline item is exact alarms surviving Doze on Xiaomi HyperOS, and
Flutter is materially better at it. This question nearly settled the whole
decision before I had read any application code, and it's the one most people
skip because it feels like it's about the future rather than the code.

**2. Can I find, in the tree, the file that proves the complaint?**

A complaint is a hypothesis until you locate it. "iOS is getting hard" → open
`ios/Runner/` and `firebase_options.dart`. There is no `GoogleService-Info.plist`
and the options file throws on iOS. The complaint was real; its *location* was
wrong. It lived at the setup step, not in the framework.

Make this a habit: **before accepting a diagnosis, name the file that would
demonstrate it, then read that file.** If you can't name one, the diagnosis
isn't testable yet.

**3. For each pain point: would the new stack make this impossible, or merely
different?**

Only "impossible" counts as a fix. Undisposed controllers: impossible in React
(no imperative object exists) — counts. Skipping `notify()` after a write:
merely different — a mutation hook is a design you could adopt in Dart tonight;
does not count. Test coverage landing on the fun features instead of the risky
ones: identically possible in Jest — does not count, and this was the one that
mattered.

Run this over the whole benefit list and it collapses. Mine went from thirteen
claimed benefits to three framework-derived ones, two of which are an hour's
work in place.

**4. Does the physical evidence of my stated problem actually appear in the
code?**

You said you couldn't keep up with AI-assisted development. So I went looking
for the fingerprint: bloated files, dead branches, inconsistent structure,
analyzer noise. Found the opposite — one file over 300 lines out of 62, clean
analyzer, nine identically-shaped features, deliberate restraint on codegen.

When the evidence contradicts the self-diagnosis, the self-diagnosis is wrong,
and the interesting question becomes *what was actually overwhelming?* Answer:
the review-and-verification surface, plus a 2,068-line decisions document
written to cope with it. That reframe is the most valuable output of this whole
review, and it came from one negative search.

**5. What is the one-day experiment that discriminates between the hypotheses?**

Before a six-week bet, find the one-day version of the question. Here it is:
**configure Firebase for iOS in the existing Flutter app and launch it.** If
that goes fine, the main stated motivation evaporates and you've spent a day. If
it's genuinely miserable, you now know *why*, specifically, and you know it
before spending your summer.

Generalize: a rewrite is a bet that a cheap experiment can usually resolve. If
you cannot design that experiment, you do not yet understand the problem well
enough to bet on it.

**6. What survives the change unchanged? Subtract it first.**

I enumerated the invariants before weighing anything: `firestore.rules`, the 38
rules tests, the Worker's 664 lines, the entire data model, HyperOS battery
behaviour, the Apple Developer account, the blocked-on-a-friend test, the absent
alarms. Anything on that list is not an argument in either direction, and
leaving it in the discussion is how rewrite conversations get muddy — people
argue about problems the decision cannot touch.

Then reason only about the remainder. The remainder here was small.

**7. What is the ratio of fix-in-place to move?**

2–4 days versus 21–37. When the ratio is ten to one, the move has to buy
something the fix categorically cannot. Here it buys EAS Update. Do the ratio
arithmetic explicitly and out loud — it is unglamorous and it is usually
decisive.

### The evidence that actually moved me

- **The `MethodChannel` with no handler, tested against a fake.** Most
  diagnostic artifact in the repo. It converted my read of the problem from
  "language" to "verification discipline" in one step. When one artifact
  reframes the question, chase it.
- **Six `notify(` call sites, all in `presentation/`.** Told me (b) is genuine
  but Dart-fixable — an architecture lesson, not a language verdict.
- **The empty `ios/Runner/`.** Told me (c) is configuration wearing a costume.
- **Zero `CustomPaint` / `AnimationController` / `Transform` / `Hero`.** This is
  the strongest fact *against* my conclusion, and I had to concede it fully. It
  is why the honest verdict is "feasible but not warranted" rather than "don't."
  Argue your opponent's best fact at full strength; if your conclusion survives
  that, it's worth acting on.

### What would have changed my mind — falsifiable, so check them yourself

- **If alarms were already built and firing reliably.** The single strongest
  argument against porting is that you'd be leaving the better alarm framework
  right before you need it. Build alarms first and that argument disappears; the
  calculus gets genuinely close.
- **If iOS had been configured, launching, and *still* painful.** That would be
  real, framework-specific iOS pain with evidence behind it, and (c) would
  become an argument for switching instead of an argument that dissolves.
- **If the code showed damage from unmanageable generation.** Sprawling files,
  incoherent layering, analyzer warnings. "Start clean" has independent value
  when the existing code is a liability. This code is an asset.
- **If a second developer were joining, or you were hiring.** TypeScript's
  talent pool is a real advantage that solo work cannot cash.
- **If your goal were "learn React Native" rather than "ship this app."** Then
  six weeks is tuition, not waste, and the app is just the vehicle. Worth being
  honest with yourself about which question you're actually asking — I answered
  the one you wrote down.
- **If custom rendering existed** — a chart, an animation system, native
  interop. Then I'd be saying no *harder*, and the port would be infeasible
  rather than merely unwarranted.

### The failure mode to watch for in yourself

The reason this decision is hard is not that the evidence is balanced. It isn't.
It's that a rewrite is the most satisfying available response to *"I have lost
control of this project"* — it converts an ambiguous, ongoing discipline problem
into a concrete, bounded, gratifying build task. That trade feels like progress
for about three weeks.

The tell was already in the repo before I read a line of it: the commit that
added ARCHITECTURE.md announced the migration in its own message. When you find
yourself gathering evidence for a decision you've already made, the useful move
is to write down what would falsify it — the list above — and then go check
those things instead.

### What to actually do, in order

1. **(1 day)** Configure Firebase for iOS in the Flutter app. Launch it. This is
   the experiment; do not skip it, it is the cheapest information available.
2. **(2–4 days)** ARCHITECTURE §5 items 3–8. Write the `secure_window` Kotlin
   handler — or change the copy in `AppLockTile`. Either is honest; silence is
   not.
3. **(2–3 days)** Core-loop tests. This is the direct fix for "I couldn't keep
   up": tests are what let you accept generated changes without reading every
   line. Point the repositories at the emulator you already run for
   `firestore-tests/`.
4. **Run the real-pair validation.** Oldest open item, gates everything, three
   weeks stale.
5. **(~1 week, optional but recommended)** The §3.5 architecture changes in
   Dart — selectors out of widgets, one mutation layer owning `write → notify`,
   parse-don't-cast at the Firestore boundary, a pagination seam. Framework-
   agnostic, every one a real architecture lesson, and if you port later the
   port gets easier because the boundaries already exist.
6. **Revisit the port after that.** You would then be porting a *verified* app
   with a test suite to port against — a completely different and far safer
   exercise than porting this one.

**If you rewrite anyway:** do M0 alone, as a spike, and set the stopping rule in
advance — if M0 and M1 don't feel materially better than the Flutter workflow
did, stop and keep the Flutter app. Sunk cost after two milestones is two weeks.
After five it is your whole summer.
