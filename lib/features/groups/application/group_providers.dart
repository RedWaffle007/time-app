import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/group_repository.dart';
import '../domain/group.dart';
import '../domain/group_join_request.dart';
import '../domain/membership.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  return GroupRepository(FirebaseFirestore.instance);
});

/// Groups the signed-in user belongs to.
final myGroupsProvider = StreamProvider<List<Group>>((ref) {
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return ref.watch(groupRepositoryProvider).watchMyGroups(uid);
});

// These take a groupId, so a family is genuinely warranted here (a plain
// provider can't be parameterised).
final membersProvider = StreamProvider.family<List<Membership>, String>((
  ref,
  groupId,
) {
  return ref.watch(groupRepositoryProvider).watchMembers(groupId);
});

final groupJoinRequestsProvider =
    StreamProvider.family<List<GroupJoinRequest>, String>((ref, groupId) {
      return ref.watch(groupRepositoryProvider).watchJoinRequests(groupId);
    });
