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

/// The recorder's hard stop. The Worker allows 20.5 s for encoder slack.
const kMaxVoiceNote = Duration(seconds: 20);

/// The shortest note the Worker accepts (F5, `MIN_VOICE_MS`), so every note
/// falls in a replay band. Shorter recordings are discarded on the spot.
const kMinVoiceNote = Duration(seconds: 1);

/// How many times a note plays when the alarm rings (F5, user-directed
/// 2026-09-26): 15–20 s → 3, 10–15 s → 4, 5–10 s → 5, under 5 s → 6. An exact
/// boundary takes the LONGER band's count. Mirrors native
/// `VoiceAlarmPolicy.playsFor`, which decides at ring time.
int voicePlaysFor(Duration length) {
  final ms = length.inMilliseconds;
  if (ms >= 15000) return 3;
  if (ms >= 10000) return 4;
  if (ms >= 5000) return 5;
  return 6;
}

final voiceLibraryRepositoryProvider = Provider<VoiceLibraryRepository>(
  (ref) => FirestoreVoiceLibraryRepository(FirebaseFirestore.instance),
);

/// The signed-in planner's saved voice notes, newest first (item 32d).
final voiceLibraryProvider = StreamProvider<List<VoiceLibraryNote>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(voiceLibraryRepositoryProvider).watch(uid);
});
