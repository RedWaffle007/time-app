import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../archive/application/archive_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_item.dart';

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  return ScheduleRepository(FirebaseFirestore.instance);
});

// ---------------------------------------------------------------------------
// The RECORD layer — every item: live, auto-hidden and manually archived alike.
//
// These two are the canonical read. Screens should NOT watch them; they want
// the filtered views below.
//
// **THE CONSTRAINT, stated where it can be violated. Every summary, stats,
// streak, goal-progress or records-generation consumer MUST aggregate from
// THESE TWO PROVIDERS, never from `myItemsAs*` or `archivedItemsProvider`.**
//
// Archiving hides rows; it does not change what happened. A consumer that
// counted a filtered view would silently drop every rejected item (auto-hidden
// the instant it is rejected) and every item the user chose to archive, out of
// that user's own numbers — and nobody would notice until the totals looked
// wrong, with no error to trace. That is precisely the lie-by-omission
// DECISIONS.md rejected "delete for me" over, reintroduced through the back
// door.
//
// **As of this commit there is NO such consumer.** The only readers of item
// data are the four screens and the pending-count badge, all of which correctly
// want the filtered view. This comment exists for the goals/effort-tracking
// phase, which is where the first record-layer consumer will be written.
// ---------------------------------------------------------------------------

/// Every item where the signed-in user is the TARGET.
final allItemsAsTargetProvider = StreamProvider<List<ScheduleItem>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(scheduleRepositoryProvider).watchItemsForTarget(uid);
});

/// Every item the signed-in user created as PLANNER.
final allItemsAsPlannerProvider = StreamProvider<List<ScheduleItem>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(scheduleRepositoryProvider).watchItemsByPlanner(uid);
});

// ---------------------------------------------------------------------------
// The VIEW layer — the record minus everything hidden from this user.
//
// TWO hide routes converge here, and this is the ONLY place either is applied,
// so every surface a settled item can reach is covered at once (My Schedule,
// the pending queue, Activity). Per-screen filtering would leak the first time
// a screen was forgotten.
//
//   AUTO   `item.isAutoArchived` — rejected / withdrawn. A pure view rule with
//          no stored state and no write, applied identically for both parties.
//          See the note on that getter for why it CANNOT be a write.
//   MANUAL `archivedIdsProvider` — done / skipped that the user chose to hide.
//
// `whenData` keeps the *items* stream's own loading and error states intact —
// a real schedule failure still reaches AsyncView, as it should. What cannot
// reach AsyncView is an archive failure: [archivedIdsProvider] is a plain
// `Set<String>` that reads empty when the archive is unreadable, so the worst a
// broken archive can do is fail to hide rows. The auto rule needs no such
// guard: it reads a field already in hand and has nothing to fail.
// ---------------------------------------------------------------------------

/// Items where the signed-in user is the TARGET (their pending queue + approved
/// items to complete/skip), minus everything hidden from them.
final myItemsAsTargetProvider = Provider<AsyncValue<List<ScheduleItem>>>((ref) {
  final archived = ref.watch(archivedIdsProvider);
  return ref
      .watch(allItemsAsTargetProvider)
      .whenData((items) => _visible(items, archived));
});

/// Items the signed-in user created as PLANNER (their activity/outcomes view),
/// minus everything hidden from them.
final myItemsAsPlannerProvider = Provider<AsyncValue<List<ScheduleItem>>>((ref) {
  final archived = ref.watch(archivedIdsProvider);
  return ref
      .watch(allItemsAsPlannerProvider)
      .whenData((items) => _visible(items, archived));
});

/// Everything hidden from this user's feeds, by either route, newest first.
///
/// Both routes land here so the Archived screen is a truthful answer to "what
/// am I not being shown" — a rejected item that appeared nowhere at all would
/// make its own record unreachable. Only the MANUAL ones are reversible there;
/// see [ArchivedScreen].
///
/// A self-planned item is in both source streams (the user is creator *and*
/// target), so this dedups by id — otherwise it would be listed twice.
final archivedItemsProvider = Provider<AsyncValue<List<ScheduleItem>>>((ref) {
  final archived = ref.watch(archivedIdsProvider);
  final asTarget = ref.watch(allItemsAsTargetProvider);
  final asPlanner = ref.watch(allItemsAsPlannerProvider);

  // Strictness is fine on this leaf screen: unlike My Schedule, nothing else
  // depends on it, so surfacing a genuine read failure here costs nothing.
  if (asTarget.hasError) {
    return AsyncError(asTarget.error!, asTarget.stackTrace ?? StackTrace.empty);
  }
  if (asPlanner.hasError) {
    return AsyncError(
        asPlanner.error!, asPlanner.stackTrace ?? StackTrace.empty);
  }
  final target = asTarget.value;
  final planner = asPlanner.value;
  if (target == null || planner == null) return const AsyncLoading();

  final byId = {for (final item in [...target, ...planner]) item.id: item};
  final items = byId.values
      .where((i) => i.isAutoArchived || archived.contains(i.id))
      .toList()
    ..sort((a, b) => b.scheduledInstantUtc.compareTo(a.scheduledInstantUtc));
  return AsyncData(items);
});

/// The single hide rule. Auto first — it needs no archive read at all, so a
/// rejected item is cleared from the feed even when the archive is unreadable.
List<ScheduleItem> _visible(List<ScheduleItem> items, Set<String> archived) {
  return items
      .where((i) => !i.isAutoArchived && !archived.contains(i.id))
      .toList();
}
