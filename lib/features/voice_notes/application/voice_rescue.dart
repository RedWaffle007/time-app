import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';

import '../../scheduling/data/schedule_repository.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../data/voice_note_client.dart';
import 'voice_note_cache.dart';

/// The Worker's pre-alarm rescue (item 32c): a high-priority DATA push asking
/// this phone to fetch a voice note that has not arrived yet. Pure parse.
({String targetUid, String itemId})? voiceFetchRequestFromPushData(
  Map<String, dynamic> data,
) {
  if (data['command'] != 'fetchVoiceNote') return null;
  final target = data['targetUid'];
  final item = data['itemId'];
  if (target is! String || target.isEmpty) return null;
  if (item is! String || item.isEmpty) return null;
  return (targetUid: target, itemId: item);
}

/// Run from the killed-app background handler: fetch, verify, stamp the
/// receipt. Only for the signed-in TARGET's own item; anything else is ignored.
Future<void> fetchVoiceNoteInBackground(
  ({String targetUid, String itemId}) request,
) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || user.uid != request.targetUid) return;
  final db = FirebaseFirestore.instance;
  final snapshot = await db
      .collection('scheduleItems')
      .doc(request.targetUid)
      .collection('items')
      .doc(request.itemId)
      .get();
  if (!snapshot.exists) return;
  final item = ScheduleItem.fromDoc(snapshot);
  if (item.voiceNote == null ||
      item.status != ScheduleItemStatus.approved ||
      item.outcome != null) {
    return;
  }
  final cache = VoiceNoteCache(
    HttpVoiceNoteClient(),
    getApplicationSupportDirectory,
  );
  await cache.ensure(item);
  if (item.voiceNote!.deliveredAt == null) {
    await ScheduleRepository(
      db,
    ).markVoiceNoteDelivered(item.targetUid, item.id);
  }
}
