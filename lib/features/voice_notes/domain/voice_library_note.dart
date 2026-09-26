import 'package:cloud_firestore/cloud_firestore.dart';

import '../../scheduling/domain/schedule_item.dart';

/// One saved voice note in the planner's library (item 32d): every voice note
/// they send is kept, newest 20. Written by the Worker; only [name] is theirs
/// to change.
class VoiceLibraryNote {
  const VoiceLibraryNote({
    required this.id,
    required this.sha256,
    required this.durationMs,
    required this.sizeBytes,
    required this.createdAt,
    this.name,
  });

  final String id;
  final String sha256;
  final int durationMs;
  final int sizeBytes;
  final DateTime createdAt;

  /// The owner's name for it; null shows its localized recording date.
  final String? name;

  Duration get length => Duration(milliseconds: durationMs);

  VoiceNoteMeta get meta => VoiceNoteMeta(
    durationMs: durationMs,
    sha256: sha256,
    sizeBytes: sizeBytes,
  );

  /// Null for anything malformed — it is simply not listed.
  static VoiceLibraryNote? fromMap(String id, Map<String, dynamic> d) {
    final sha = d['sha256'];
    final duration = d['durationMs'];
    final size = d['sizeBytes'];
    final created = d['createdAt'];
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    if (duration is! int || duration <= 0 || size is! int || size <= 0) {
      return null;
    }
    final at = created is Timestamp
        ? created.toDate().toUtc()
        : created is DateTime
        ? created.toUtc()
        : null;
    if (at == null) return null;
    final name = d['name'];
    return VoiceLibraryNote(
      id: id,
      sha256: sha,
      durationMs: duration,
      sizeBytes: size,
      createdAt: at,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
    );
  }
}

/// A month's worth of notes, newest first. [monthStart] is null when the
/// whole library falls in one month — headings appear only once there are
/// two (32d).
class VoiceLibraryGroup {
  const VoiceLibraryGroup(this.monthStart, this.notes);
  final DateTime? monthStart;
  final List<VoiceLibraryNote> notes;
}

/// Newest first, grouped by the LOCAL month they were recorded in; a single
/// month is one untitled group. [toLocal] is injectable for tests.
List<VoiceLibraryGroup> groupVoiceLibrary(
  List<VoiceLibraryNote> notes, {
  DateTime Function(DateTime utc)? toLocal,
}) {
  final local = toLocal ?? (DateTime utc) => utc.toLocal();
  final sorted = [...notes]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final groups = <DateTime, List<VoiceLibraryNote>>{};
  for (final note in sorted) {
    final at = local(note.createdAt);
    groups.putIfAbsent(DateTime(at.year, at.month), () => []).add(note);
  }
  if (groups.length < 2) {
    return sorted.isEmpty ? const [] : [VoiceLibraryGroup(null, sorted)];
  }
  return [
    for (final entry in groups.entries)
      VoiceLibraryGroup(entry.key, entry.value),
  ];
}

/// The longest name the rules accept.
const kVoiceNoteNameMax = 60;
