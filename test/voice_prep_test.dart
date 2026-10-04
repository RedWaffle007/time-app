import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';
import 'package:time_app/features/voice_notes/application/voice_prep.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';

/// 2026-10-04: the voice note is sent while the planner finishes the plan.
void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  VoicePrep prep(_Client client) {
    var n = 0;
    return VoicePrep(
      client: client,
      mintItemId: (uid) => 'id-${++n}',
      retryDelays: const [Duration.zero, Duration.zero],
    );
  }

  test('one recipient: uploaded at start, ready for Send', () async {
    final client = _Client();
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    final result = await p.ready();
    expect(p.phase, VoicePrepPhase.ready);
    expect(result['A']?.itemId, 'id-1');
    expect(client.calls, ['upload:A:id-1']);
  });

  test('several recipients: one upload, then a server copy each', () async {
    final client = _Client();
    final p = prep(client)
      ..start(recording: bytes, targetUids: ['A', 'B', 'C'], groupId: 'g');
    await p.ready();
    expect(client.calls, [
      'upload:A:id-1',
      'copy:id-1->B:id-2',
      'copy:id-1->C:id-3',
    ]);
  });

  test('a dropped connection is retried quietly and succeeds', () async {
    final client = _Client(connectionFailures: 2);
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    await p.ready();
    expect(p.phase, VoicePrepPhase.ready);
    expect(client.calls, hasLength(3));
  });

  test('a connection down through every attempt fails; ready() tries once '
      'more, as Send does', () async {
    final client = _Client(connectionFailures: 3);
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    // Let the first run use up its attempts.
    await pumpEventQueue();
    expect(p.phase, VoicePrepPhase.failed);
    expect(p.error, isNotNull);
    final result = await p.ready();
    expect(p.phase, VoicePrepPhase.ready);
    expect(result['A'], isNotNull);
  });

  test('a refusal is never retried, and names the reason', () async {
    final client = _Client(refuse: {'A'});
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    final result = await p.ready();
    expect(result['A'], isNull);
    expect(p.phase, VoicePrepPhase.failed);
    expect(p.refused['A'], "You can't plan for this person right now.");
    expect(client.calls, ['upload:A:id-1'], reason: 'one attempt only');
  });

  test('a refused group member is skipped; the others still get it', () async {
    final client = _Client(refuse: {'B'});
    final p = prep(client)
      ..start(recording: bytes, targetUids: ['A', 'B', 'C'], groupId: 'g');
    final result = await p.ready();
    expect(p.phase, VoicePrepPhase.ready);
    expect(result['A'], isNotNull);
    expect(result['B'], isNull);
    expect(result['C'], isNotNull);
  });

  test('re-recording supersedes: only the newest run counts, under fresh '
      'ids', () async {
    final gate = Completer<void>();
    final client = _Client(gate: gate);
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    final stale = p.ready();
    p.start(recording: Uint8List.fromList([9]), targetUids: ['A']);
    gate.complete();
    final result = await p.ready();
    await stale; // never hangs
    expect(result['A']?.itemId, 'id-2');
  });

  test('a new person gets the same note sent again', () async {
    final client = _Client();
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    await p.ready();
    p.retarget(['B']);
    final result = await p.ready();
    expect(result.keys, ['B']);
    expect(client.calls.last, 'upload:B:id-2');
  });

  test('clear forgets the note; ready() then has nothing', () async {
    final client = _Client();
    final p = prep(client)..start(recording: bytes, targetUids: ['A']);
    p.clear();
    expect(p.hasSource, isFalse);
    expect(p.phase, VoicePrepPhase.idle);
    expect(await p.ready(), isEmpty);
  });

  test('server errors and lost answers are retryable; refusals are not', () {
    expect(isRetryableVoiceStatus(502, 'store-failed'), isTrue);
    expect(isRetryableVoiceStatus(429, null), isTrue);
    expect(isRetryableVoiceStatus(401, 'unauthorized'), isTrue);
    expect(isRetryableVoiceStatus(403, 'no-planning-permission'), isFalse);
    expect(isRetryableVoiceStatus(413, 'too-long'), isFalse);
  });
}

class _Client implements VoiceNoteClient {
  _Client({this.connectionFailures = 0, this.refuse = const {}, this.gate});

  int connectionFailures;
  final Set<String> refuse;
  final Completer<void>? gate;
  final calls = <String>[];

  static const _meta = VoiceNoteMeta(
    durationMs: 3000,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    sizeBytes: 3,
  );

  Future<VoiceNoteMeta> _answer(String targetUid) async {
    if (gate != null && !gate!.isCompleted) await gate!.future;
    if (connectionFailures > 0) {
      connectionFailures--;
      throw TimeoutException('no signal');
    }
    if (refuse.contains(targetUid)) {
      throw VoiceNoteFailure(voiceNoteErrorMessage('no-planning-permission'));
    }
    return _meta;
  }

  @override
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) {
    calls.add('upload:$targetUid:$itemId');
    return _answer(targetUid);
  }

  @override
  Future<VoiceNoteMeta> copyToMember({
    required String fromItemId,
    required String targetUid,
    required String itemId,
    required String groupId,
  }) {
    calls.add('copy:$fromItemId->$targetUid:$itemId');
    return _answer(targetUid);
  }

  @override
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) {
    calls.add('attach:$noteId:$targetUid:$itemId');
    return _answer(targetUid);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
