import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_item.dart';

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  return ScheduleRepository(FirebaseFirestore.instance);
});

/// Items where the signed-in user is the TARGET (their pending queue + approved
/// items to complete/skip).
final myItemsAsTargetProvider = StreamProvider<List<ScheduleItem>>((ref) {
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return ref.watch(scheduleRepositoryProvider).watchItemsForTarget(uid);
});

/// Items the signed-in user created as PLANNER (their activity/outcomes view).
final myItemsAsPlannerProvider = StreamProvider<List<ScheduleItem>>((ref) {
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return ref.watch(scheduleRepositoryProvider).watchItemsByPlanner(uid);
});
