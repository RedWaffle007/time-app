import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/voice_note_client.dart';
import 'voice_note_providers.dart';

/// Whether [bytes] are exactly the voice note the plan was made with.
bool voiceBytesMatch(Uint8List bytes, VoiceNoteMeta meta) =>
    bytes.length == meta.sizeBytes &&
    sha256.convert(bytes).toString() == meta.sha256;

/// A verified local copy of an item's voice note, fetched once. Used for the
/// approval preview now; 32c reuses it for the alarm's offline copy.
class VoiceNoteCache {
  VoiceNoteCache(this._client, this._dir);

  final VoiceNoteClient _client;
  final Future<Directory> Function() _dir;

  Future<File> _fileFor(ScheduleItem item) async {
    final dir = Directory('${(await _dir()).path}/voice-notes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/${item.id}.m4a');
  }

  /// The path of a verified copy, downloading it if needed. Throws
  /// [VoiceNoteFailure] if the note cannot be fetched or does not match.
  Future<String> ensure(ScheduleItem item) async {
    final meta = item.voiceNote;
    if (meta == null) {
      throw const VoiceNoteFailure('This plan has no voice note.');
    }
    final file = await _fileFor(item);
    if (await file.exists() &&
        voiceBytesMatch(await file.readAsBytes(), meta)) {
      return file.path;
    }
    final bytes = await _client.download(
      targetUid: item.targetUid,
      itemId: item.id,
    );
    if (!voiceBytesMatch(bytes, meta)) {
      throw const VoiceNoteFailure(
        "This voice note didn't arrive intact. Try again.",
      );
    }
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

final voiceNoteCacheDirProvider = Provider<Future<Directory> Function()>(
  (ref) => getApplicationSupportDirectory,
);

final voiceNoteCacheProvider = Provider<VoiceNoteCache>((ref) {
  return VoiceNoteCache(
    ref.watch(voiceNoteClientProvider),
    ref.watch(voiceNoteCacheDirProvider),
  );
});
