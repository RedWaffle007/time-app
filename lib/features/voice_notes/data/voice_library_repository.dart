import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/voice_library_note.dart';

/// Reads the planner's voice library and renames entries (item 32d). Creating
/// and deleting are the Worker's (`VoiceNoteClient`), which keeps each entry
/// with its audio; the rules refuse both from here.
abstract interface class VoiceLibraryRepository {
  Stream<List<VoiceLibraryNote>> watch(String uid);

  /// [name] null (or blank) clears it back to the recording date.
  Future<void> rename(String uid, String noteId, String? name);
}

class FirestoreVoiceLibraryRepository implements VoiceLibraryRepository {
  FirestoreVoiceLibraryRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _notes(String uid) =>
      _db.collection('users').doc(uid).collection('voiceLibrary');

  @override
  Stream<List<VoiceLibraryNote>> watch(String uid) => _notes(uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map(
        (snap) => [
          for (final doc in snap.docs)
            ?VoiceLibraryNote.fromMap(doc.id, doc.data()),
        ],
      );

  @override
  Future<void> rename(String uid, String noteId, String? name) {
    final trimmed = name?.trim() ?? '';
    return _notes(uid).doc(noteId).update({
      'name': trimmed.isEmpty
          ? FieldValue.delete()
          : trimmed.substring(0, trimmed.length.clamp(0, kVoiceNoteNameMax)),
    });
  }
}
