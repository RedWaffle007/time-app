import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../plan_requests/application/plan_request_providers.dart';
import '../../plan_requests/domain/plan_request.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../social/application/stats_providers.dart';
import 'my_stats.dart';

RequestSummary _toRequestSummary(PlanRequest r) => RequestSummary(
  fulfilled: r.status == PlanRequestStatus.fulfilled,
  declined: r.status == PlanRequestStatus.declined,
  cancelled: r.status == PlanRequestStatus.cancelled,
  open: r.isOpen,
  expired: r.status == PlanRequestStatus.expired,
  windowEndUtc: r.windowEndUtc,
);

/// The signed-in user's private Stats page (item 24b).
///
/// Reads the RECORD providers, like every stat. The outgoing-requests stream
/// is secondary: if it fails, the request tile reads zero rather than taking
/// the whole page down.
final myStatsProvider = Provider<AsyncValue<MyStats>>((ref) {
  final asTarget = ref.watch(allItemsAsTargetProvider);
  final asPlanner = ref.watch(allItemsAsPlannerProvider);
  final requests = ref.watch(outgoingPlanRequestsProvider);
  final home = ref.watch(profileProvider).value?.homeTimezone;

  if (asTarget.hasError) {
    return AsyncError(asTarget.error!, asTarget.stackTrace ?? StackTrace.empty);
  }
  if (asPlanner.hasError) {
    return AsyncError(
      asPlanner.error!,
      asPlanner.stackTrace ?? StackTrace.empty,
    );
  }
  final target = asTarget.value;
  final planner = asPlanner.value;
  if (target == null || planner == null || home == null) {
    return const AsyncLoading();
  }

  return AsyncData(
    buildMyStats(
      itemsAsTarget: target.map(toStatItem).toList(),
      itemsAsPlanner: planner.map(toStatItem).toList(),
      outgoingRequests: (requests.value ?? const [])
          .map(_toRequestSummary)
          .toList(),
      // The impurity stops here; the builder takes `now` as an argument.
      now: DateTime.now().toUtc(),
      timezone: home,
    ),
  );
});
