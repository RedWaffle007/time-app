/// The double-booking lock's key (Batch G item 4, DECISIONS.md "No
/// double-booking — minute locks"): a plan's absolute instant in whole minutes
/// since the epoch. Each person's own timezone is already folded in, and DST's
/// repeated hour is two different minutes. Must match `epochMinute()` in
/// firestore.rules and the Worker's `group-plan.js`.
String minuteLockId(DateTime instantUtc) =>
    '${instantUtc.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute}';
