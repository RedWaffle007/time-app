import 'package:flutter_riverpod/flutter_riverpod.dart';

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
