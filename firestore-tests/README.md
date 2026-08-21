# Firestore security-rules tests

Unit tests for `../firestore.rules`, run against the Firestore emulator.

```bash
cd firestore-tests
npm install     # once
npm test
```

`npm test` starts the emulator via `firebase emulators:exec` (using the repo's
`../firebase.json`, so it loads the **real** rules file — not a copy) and runs
`rules.test.mjs` under `node --test`. Project id is `demo-time-app`; the `demo-`
prefix keeps the emulator fully offline, so no Firebase credentials are needed
and nothing can touch the live project.

## What is covered

`rules.test.mjs` covers the two findings in `ARCHITECTURE.md` §4.1 that the rules
were changed to close:

- **Enumeration** — `users` and `groups` may not be listed; a non-member may not
  read a group doc or resolve an invite code by querying `groups`.
- **Notification suppression** — no client may write the push Worker's
  `notified*` dedup fields, on `create` or on `update`, as either party.

Each denial is paired with the legitimate operation it must not break (approve,
reject, mark done, mark skipped, planner withdraw, planner create, self-plan,
`watchMyGroups`, the planner's collection-group read). A rules file that denied
everything would pass only half this suite.

## Why it lives here and not in `test/`

`test/` is the Flutter test directory. Keeping `node_modules/` out of it means
`flutter test` never walks 780 npm packages.

## Reading a failure

The emulator prints its evaluation trace on every denial, e.g.

```
evaluation error at L276:24 for 'create' @ L276, false for 'update' @ L301
```

The `evaluation error` line is **normal noise, not a defect**. The rules engine
evaluates the whole ruleset in one pass; when a rule needs a document lookup
(`get()`/`exists()` — the item-create rule looks up the planner grant) the first
pass cannot complete and reports an error, then re-evaluates with the fetched
document. The verdict is the *last* clause on the line — here `false for
'update'`. Read that one.

## Why the suite runs single-threaded

`npm test` passes `--test-concurrency=1`, and it is not a performance choice.

`node --test` runs each test *file* in its own process, in parallel by default.
Every file here calls `testEnv.clearFirestore()` in `beforeEach` — against the
one emulator all of them share. Run in parallel, one file wipes the database out
from under another file's seeded world, and the failures land on whichever
assertions happen to lose the race. They look like rule bugs and are not: the
symptom is a scatter of `ALLOWS …` tests failing across unrelated describes,
changing from run to run, while each file passes on its own.

So: one file at a time. Add a new `*.test.mjs` freely — it inherits this.
