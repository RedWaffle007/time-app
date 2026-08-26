import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/platform_speech_service.dart';
import '../data/speech_service.dart';

/// The one line that chooses the voice engine. Swapping [PlatformSpeechService]
/// for an on-device or iOS-specific implementation is a change HERE and nowhere
/// else — the seam ([SpeechService]) keeps every screen ignorant of the plugin.
final speechServiceProvider = Provider<SpeechService>((ref) {
  final service = PlatformSpeechService();
  ref.onDispose(service.dispose);
  return service;
});
