import 'dart:typed_data';

import '../../scheduling/domain/schedule_item.dart';
import '../data/voice_note_client.dart';

/// Puts ONE voice note on every member's group alarm (2026-09-27).
///
/// A fresh recording is uploaded once, for the first member; every later
/// member gets a server-side copy of that upload (`/voice/copy`), so the phone
/// never re-uploads the audio. A library note is attached per member, which is
/// already a server-side copy. Call it once per member, in order, before that
/// member's alarm is created.
class GroupVoiceAttacher {
  GroupVoiceAttacher({
    required this.client,
    required this.groupId,
    this.recording,
    this.libraryNoteId,
  }) : assert((recording == null) != (libraryNoteId == null));

  final VoiceNoteClient client;

  /// Empty when one plan goes to several friends with no group (R4).
  final String groupId;
  final Uint8List? recording;
  final String? libraryNoteId;

  /// The item the one upload was made for, once it succeeded.
  String? _sourceItemId;

  Future<VoiceNoteMeta> call({
    required String targetUid,
    required String itemId,
  }) async {
    final noteId = libraryNoteId;
    if (noteId != null) {
      return client.attachFromLibrary(
        noteId: noteId,
        targetUid: targetUid,
        itemId: itemId,
        groupId: groupId,
      );
    }
    final source = _sourceItemId;
    if (source == null) {
      final meta = await client.upload(
        bytes: recording!,
        targetUid: targetUid,
        itemId: itemId,
        groupId: groupId,
      );
      _sourceItemId = itemId;
      return meta;
    }
    return client.copyToMember(
      fromItemId: source,
      targetUid: targetUid,
      itemId: itemId,
      groupId: groupId,
    );
  }
}
