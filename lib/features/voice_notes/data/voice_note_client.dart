import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../../scheduling/domain/schedule_item.dart';

/// A voice-note request that did not work, with a message written for people.
class VoiceNoteFailure implements Exception {
  const VoiceNoteFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to the Worker's `/voice` routes (item 32a). The Worker re-checks
/// everything; this only carries bytes and maps refusals to plain words.
abstract interface class VoiceNoteClient {
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  });

  Future<Uint8List> download({
    required String targetUid,
    required String itemId,
  });

  /// One of your own library notes (32d).
  Future<Uint8List> downloadLibrary(String noteId);

  /// Delete one of your library notes — its audio and its entry (32d).
  Future<void> deleteLibrary(String noteId);

  /// Reuse a library note on a plan about to be created: the Worker copies it
  /// server-side and records it exactly like an upload (32d).
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  });
}

/// The words for each Worker refusal.
String voiceNoteErrorMessage(String? code) => switch (code) {
  'too-long' => 'Voice notes can be at most 20 seconds.',
  'too-short' => 'That recording is too short. Try again.',
  'too-large' => 'That recording is too large. Try a shorter one.',
  'unsupported-type' ||
  'unreadable-audio' => "That recording couldn't be read. Record it again.",
  'no-planning-permission' => "You can't plan for this person right now.",
  'item-exists' => 'This plan already exists; its voice note is fixed.',
  'self-plan' => 'Voice notes are for plans you make for someone else.',
  'no-voice-note' || 'gone' => 'This voice note is no longer available.',
  'forbidden' => "You can't play this voice note.",
  'not-found' => 'That voice note is no longer in your library.',
  _ => "The voice note couldn't be sent. Check your connection and try again.",
};

class HttpVoiceNoteClient implements VoiceNoteClient {
  HttpVoiceNoteClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  Future<String> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const VoiceNoteFailure('Sign in again to continue.');
    }
    final token = await user.getIdToken();
    if (token == null) {
      throw const VoiceNoteFailure('Sign in again to continue.');
    }
    return token;
  }

  @override
  Future<VoiceNoteMeta> upload({
    required Uint8List bytes,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    final response = await _http
        .post(
          Uri.parse('$kNotifyEndpoint/voice'),
          headers: {
            'Authorization': 'Bearer ${await _token()}',
            'Content-Type': 'audio/mp4',
            'x-target-uid': targetUid,
            'x-item-id': itemId,
            if (groupId != null && groupId.isNotEmpty) 'x-group-id': groupId,
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 30));
    return parseUploadResponse(response.statusCode, response.body);
  }

  @override
  Future<Uint8List> download({
    required String targetUid,
    required String itemId,
  }) async {
    final response = await _http
        .get(
          Uri.parse('$kNotifyEndpoint/voice/$targetUid/$itemId'),
          headers: {'Authorization': 'Bearer ${await _token()}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw VoiceNoteFailure(voiceNoteErrorMessage(errorCode(response.body)));
    }
    return response.bodyBytes;
  }

  @override
  Future<Uint8List> downloadLibrary(String noteId) async {
    final response = await _http
        .get(
          Uri.parse('$kNotifyEndpoint/voice/library/$noteId'),
          headers: {'Authorization': 'Bearer ${await _token()}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) _fail(response);
    return response.bodyBytes;
  }

  @override
  Future<void> deleteLibrary(String noteId) async {
    final response = await _http
        .delete(
          Uri.parse('$kNotifyEndpoint/voice/library/$noteId'),
          headers: {'Authorization': 'Bearer ${await _token()}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) _fail(response);
  }

  @override
  Future<VoiceNoteMeta> attachFromLibrary({
    required String noteId,
    required String targetUid,
    required String itemId,
    String? groupId,
  }) async {
    final response = await _http
        .post(
          Uri.parse('$kNotifyEndpoint/voice/attach'),
          headers: {
            'Authorization': 'Bearer ${await _token()}',
            'x-note-id': noteId,
            'x-target-uid': targetUid,
            'x-item-id': itemId,
            if (groupId != null && groupId.isNotEmpty) 'x-group-id': groupId,
          },
        )
        .timeout(const Duration(seconds: 30));
    return parseUploadResponse(response.statusCode, response.body);
  }
}

extension on HttpVoiceNoteClient {
  Never _fail(http.Response response) =>
      throw VoiceNoteFailure(voiceNoteErrorMessage(errorCode(response.body)));
}

String? errorCode(String body) =>
    RegExp(r'"error"\s*:\s*"([a-z-]+)"').firstMatch(body)?.group(1);

/// Upload response → metadata, or a [VoiceNoteFailure]. Pure, for tests.
VoiceNoteMeta parseUploadResponse(int status, String body) {
  if (status != 200) {
    throw VoiceNoteFailure(voiceNoteErrorMessage(errorCode(body)));
  }
  final sha = RegExp(r'"sha256"\s*:\s*"([0-9a-f]{64})"').firstMatch(body);
  final duration = RegExp(r'"durationMs"\s*:\s*(\d+)').firstMatch(body);
  final size = RegExp(r'"sizeBytes"\s*:\s*(\d+)').firstMatch(body);
  if (sha == null || duration == null || size == null) {
    throw VoiceNoteFailure(voiceNoteErrorMessage(null));
  }
  return VoiceNoteMeta(
    durationMs: int.parse(duration.group(1)!),
    sha256: sha.group(1)!,
    sizeBytes: int.parse(size.group(1)!),
  );
}
