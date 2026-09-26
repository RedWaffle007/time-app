import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/http_group_plan_reporter.dart';

/// Reports a group plan that could not be set for some members (Batch G item
/// 4). The Worker VERIFIES each claimed-busy member against Firestore, pushes
/// the verified ones ("wasn't set for you — you already have a plan then") and
/// the planner's summary, and returns the verified uids so the app can name
/// them. Null means the Worker could not be reached — the app then says only
/// how many could not be set.
abstract class GroupPlanReporter {
  Future<Set<String>?> reportBusy({
    required String groupId,
    required String title,
    required int setCount,
    required List<({String uid, DateTime instantUtc})> failed,
  });
}

final groupPlanReporterProvider = Provider<GroupPlanReporter>((ref) {
  return HttpGroupPlanReporter();
});
