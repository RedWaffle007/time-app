import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/tracked_time_repository.dart';
import '../domain/tracked_entry.dart';

final trackedTimeRepositoryProvider = Provider<TrackedTimeRepository>((ref) {
  return TrackedTimeRepository(FirebaseFirestore.instance);
});

/// The signed-in user's own tracked entries. No screen watches this yet — the
/// stats page and a tracked-time list are parked for a later session.
final myTrackedEntriesProvider = StreamProvider<List<TrackedEntry>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(trackedTimeRepositoryProvider).watch(uid);
});
