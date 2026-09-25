import 'package:cloud_firestore/cloud_firestore.dart';

/// One durable completion celebration shared by the target and planner.
///
/// It remains in Firestore until every participant has displayed it. That is
/// what makes an offline planner see the same celebration on their next return
/// without replaying it again afterwards.
class CompletionCelebration {
  const CompletionCelebration({
    required this.id,
    required this.itemId,
    required this.targetUid,
    required this.plannerUid,
    required this.participantUids,
    required this.seenByUids,
    this.createdAt,
  });

  final String id;
  final String itemId;
  final String targetUid;
  final String plannerUid;
  final List<String> participantUids;
  final List<String> seenByUids;
  final DateTime? createdAt;

  bool isUnseenBy(String uid) =>
      participantUids.contains(uid) && !seenByUids.contains(uid);

  static String eventId(String targetUid, String itemId) =>
      '${targetUid}_$itemId';

  /// The event this device just committed with a Done, built locally so the
  /// burst starts on save instead of after Firestore echoes it back. It shares
  /// the durable document's id, so the echo is de-duplicated, not replayed.
  factory CompletionCelebration.committed({
    required String targetUid,
    required String itemId,
    required String plannerUid,
  }) => CompletionCelebration(
    id: eventId(targetUid, itemId),
    itemId: itemId,
    targetUid: targetUid,
    plannerUid: plannerUid,
    participantUids: <String>{targetUid, plannerUid}.toList(),
    seenByUids: const [],
  );

  factory CompletionCelebration.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return CompletionCelebration(
      id: doc.id,
      itemId: (data['itemId'] ?? '') as String,
      targetUid: (data['targetUid'] ?? '') as String,
      plannerUid: (data['plannerUid'] ?? '') as String,
      participantUids: List<String>.from(data['participantUids'] ?? const []),
      seenByUids: List<String>.from(data['seenByUids'] ?? const []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
