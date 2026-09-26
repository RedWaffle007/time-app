import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/voice_note_client.dart';
import '../domain/voice_library_note.dart';
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

  Future<Directory> _folder() async {
    final dir = Directory('${(await _dir()).path}/voice-notes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _fileFor(ScheduleItem item) async =>
      File('${(await _folder()).path}/${item.id}.m4a');

  /// Where [itemId]'s verified copy lives (whether or not it is there yet) —
  /// the path the alarm is armed with, so it never needs re-arming (32c-2).
  Future<String> pathFor(String itemId) async =>
      '${(await _folder()).path}/$itemId.m4a';

  /// Whether a copy that matches [item]'s note is already on this phone.
  Future<bool> hasVerified(ScheduleItem item) async {
    final meta = item.voiceNote;
    if (meta == null) return false;
    final file = await _fileFor(item);
    return await file.exists() &&
        voiceBytesMatch(await file.readAsBytes(), meta);
  }

  /// Delete every local copy whose id is not in [keepIds]. Returns how many.
  Future<int> prune(Set<String> keepIds) async {
    var removed = 0;
    await for (final entity in (await _folder()).list()) {
      if (entity is! File || !entity.path.endsWith('.m4a')) continue;
      final name = entity.uri.pathSegments.last;
      final id = name.substring(0, name.length - '.m4a'.length);
      if (keepIds.contains(id)) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
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

  /// A verified local copy of one of your library notes (32d), in its own
  /// folder so the alarm copies' [prune] never touches it.
  Future<String> ensureLibrary(VoiceLibraryNote note) async {
    final dir = Directory('${(await _dir()).path}/voice-library');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/${note.id}.m4a');
    if (await file.exists() &&
        voiceBytesMatch(await file.readAsBytes(), note.meta)) {
      return file.path;
    }
    final bytes = await _client.downloadLibrary(note.id);
    if (!voiceBytesMatch(bytes, note.meta)) {
      throw const VoiceNoteFailure(
        "This voice note didn't arrive intact. Try again.",
      );
    }
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Drop a deleted library note's local copy.
  Future<void> forgetLibrary(String noteId) async {
    try {
      await File('${(await _dir()).path}/voice-library/$noteId.m4a').delete();
    } catch (_) {}
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
