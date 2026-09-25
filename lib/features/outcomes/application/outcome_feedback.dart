/// How long "Updating {planner}…" stays up after Done/Skip (directed 2026-09-25).
///
/// It replaces an unexplained wait with a truthful one: the outcome is being
/// saved and the planner told. The celebration (Done) starts when it ends —
/// or when the save does, if that takes longer.
const kPlannerUpdateDuration = Duration(milliseconds: 1500);

/// The label shown for [kPlannerUpdateDuration] after Done/Skip.
///
/// A self-plan has no one else to update; an unresolved name never shows a
/// uid.
String updatingPlannerLabel({required bool selfPlanned, String? plannerName}) {
  if (selfPlanned) return 'Updating your schedule…';
  final name = plannerName?.trim();
  if (name == null || name.isEmpty) return 'Updating your planner…';
  return 'Updating $name…';
}

/// Runs [work] and resolves no sooner than [minimum] after it started.
Future<T> atLeast<T>(
  Future<T> work, {
  Duration minimum = kPlannerUpdateDuration,
}) async {
  final floor = Future<void>.delayed(minimum);
  final result = await work;
  await floor;
  return result;
}
