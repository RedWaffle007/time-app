import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/voice_notes/application/group_voice_attacher.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';

/// Group voice notes (2026-09-27): one upload, then server-side copies.
void main() {
  test(
    'a recording is uploaded ONCE, then copied to every other member',
    () async {
      final client = _Client();
      final attach = GroupVoiceAttacher(
        client: client,
        groupId: 'group1',
        recording: Uint8List.fromList([1, 2, 3]),
      );
      for (final (uid, id) in [('A', 'iA'), ('B', 'iB'), ('C', 'iC')]) {
        await attach(targetUid: uid, itemId: id);
      }
      expect(client.calls, [
        'upload:A:iA:group1',
        'copy:iA->B:iB:group1',
        'copy:iA->C:iC:group1',
      ]);
    },
  );

  test('a failed first upload is retried on the next member', () async {
    final client = _Client(failFirstUpload: true);
    final attach = GroupVoiceAttacher(
      client: client,
      groupId: 'group1',
      recording: Uint8List.fromList([1]),
    );
    await expectLater(
      attach(targetUid: 'A', itemId: 'iA'),
      throwsA(isA<VoiceNoteFailure>()),
    );
    await attach(targetUid: 'B', itemId: 'iB');
    await attach(targetUid: 'C', itemId: 'iC');
    expect(client.calls, [
      'upload:A:iA:group1',
      'upload:B:iB:group1',
      'copy:iB->C:iC:group1',
    ]);
  });

  test('a library note is attached per member, never uploaded', () async {
    final client = _Client();
    final attach = GroupVoiceAttacher(
      client: client,
      groupId: 'group1',
      libraryNoteId: 'note1',
    );
    await attach(targetUid: 'A', itemId: 'iA');
    await attach(targetUid: 'B', itemId: 'iB');
    expect(client.calls, [
      'attach:note1:A:iA:group1',
      'attach:note1:B:iB:group1',
    ]);
  });
}

class _Client implements VoiceNoteClient {
  _Client({this.failFirstUpload = false});

  bool failFirstUpload;
  final calls = <String>[];

  static const _meta = VoiceNoteMeta(
    durationMs: 5000,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    sizeBytes: 100,
  );

  @override
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    calls.add('upload:$targetUid:$itemId:$groupId');
    if (failFirstUpload) {
      failFirstUpload = false;
      throw const VoiceNoteFailure('offline');
    }
    return _meta;
  }

  @override
  Future<VoiceNoteMeta> copyToMember({
    required String fromItemId,
    required String targetUid,
    required String itemId,
    required String groupId,
  }) async {
    calls.add('copy:$fromItemId->$targetUid:$itemId:$groupId');
    return _meta;
  }

  @override
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    calls.add('attach:$noteId:$targetUid:$itemId:$groupId');
    return _meta;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
