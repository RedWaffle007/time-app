import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/voice_library_repository.dart';
import '../domain/voice_library_note.dart';

import '../data/voice_note_client.dart';
import '../data/voice_player.dart';
import '../data/voice_recorder.dart';

/// A fresh recorder per builder visit (it holds the microphone).
final voiceRecorderFactoryProvider = Provider<VoiceRecorder Function()>(
  (ref) => RecordPackageVoiceRecorder.new,
);

final voicePlayerProvider = Provider<VoicePlayer>((ref) {
  final player = PlatformVoicePlayer();
  ref.onDispose(player.stop);
  return player;
});

final voiceNoteClientProvider = Provider<VoiceNoteClient>(
  (ref) => HttpVoiceNoteClient(),
);

/// The recorder's hard stop (2026-10-05: 25 seconds, so two plays plus the
/// pause fit in a 1-minute ring). The Worker and the rules allow 25.5 s for
/// encoder slack.
const kMaxVoiceNote = Duration(seconds: 25);

/// When the recorder actually stops itself, timed from BEFORE the microphone
/// opens. The half second under [kMaxVoiceNote] absorbs the start/stop
/// latency the phone adds to the file, which could push a full-length note
/// past the Worker's 25.5 s and fail it at Send (device report 2026-09-28).
const kVoiceAutoStopAt = Duration(milliseconds: 24500);

/// The shortest note the Worker accepts (F5, `MIN_VOICE_MS`). Shorter
/// recordings are discarded on the spot.
const kMinVoiceNote = Duration(seconds: 1);

final voiceLibraryRepositoryProvider = Provider<VoiceLibraryRepository>(
  (ref) => FirestoreVoiceLibraryRepository(FirebaseFirestore.instance),
);

/// The signed-in planner's saved voice notes, newest first (item 32d).
final voiceLibraryProvider = StreamProvider<List<VoiceLibraryNote>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(voiceLibraryRepositoryProvider).watch(uid);
});
