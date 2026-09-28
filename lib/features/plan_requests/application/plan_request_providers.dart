import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/plan_request_repository.dart';
import '../domain/plan_request.dart';

final planRequestRepositoryProvider = Provider<PlanRequestRepository>((ref) {
  return PlanRequestRepository(FirebaseFirestore.instance);
});

final incomingPlanRequestsProvider = StreamProvider<List<PlanRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(planRequestRepositoryProvider).watchIncoming(uid);
});

final outgoingPlanRequestsProvider = StreamProvider<List<PlanRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(planRequestRepositoryProvider).watchOutgoing(uid);
});

/// Every request received, finished ones included (Request History).
final receivedPlanRequestsProvider = StreamProvider<List<PlanRequest>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(planRequestRepositoryProvider).watchReceived(uid);
});

final planRequestProvider = StreamProvider.family<PlanRequest?, String>((
  ref,
  id,
) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(planRequestRepositoryProvider).watchOne(id);
});

/// The Request pillar's badge: requests still waiting on me whose time has
/// not passed (an expired one never counts, even before the Worker marks it).
final incomingPlanRequestCountProvider = Provider<int>((ref) {
  final now = DateTime.now().toUtc();
  return ref
      .watch(incomingPlanRequestsProvider)
      .maybeWhen(
        data: (requests) => requests.where((r) => r.isLiveAt(now)).length,
        orElse: () => 0,
      );
});
