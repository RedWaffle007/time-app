import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'speech_service.dart';

/// The [SpeechService] backed by the device's own recognizer and TTS.
///
/// `speech_to_text` uses the PLATFORM recognizer (Android `SpeechRecognizer`,
/// iOS `SFSpeechRecognizer`) — on-device where the OS ships offline models,
/// otherwise the OS's own free service. No API key, no billing, no network of
/// ours. It is also the only thing in the app that requests `RECORD_AUDIO`.
///
/// All plugin types are contained HERE. Nothing above the [SpeechService]
/// interface sees a `SpeechRecognitionResult`, a `LocaleName` or a `TtsState`.
class PlatformSpeechService implements SpeechService {
  PlatformSpeechService();

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _initialised = false;
  bool _available = false;

  @override
  Future<bool> ensureReady() async {
    // `initialize` is idempotent enough to call again, but doing so re-runs the
    // availability probe needlessly; latch the first successful init.
    if (_initialised && _available) return true;
    try {
      _available = await _stt.initialize(
        // Errors and status transitions are surfaced to the caller through the
        // listen callbacks, not here — this only decides availability.
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (_) {
      // A platform channel failure (no recognizer, an OEM without the service)
      // is the same outcome as "not available": the caller falls back to manual.
      _available = false;
    }
    _initialised = true;

    // TTS is prepared opportunistically; a failure here never blocks capture.
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}

    return _available;
  }

  @override
  Future<void> speak(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // The prompt is always on screen too, so a mute TTS is a non-event.
    }
  }

  @override
  Future<void> listen({
    required void Function(String transcript, bool isFinal) onResult,
    String? localeId,
  }) async {
    if (!_available) return;
    await _stt.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        // Dictation-style: keep the whole utterance, do not stop on the first
        // pause-shaped gap between "walking" and "thirty minutes".
        listenMode: ListenMode.dictation,
        localeId: localeId,
        // Tap-to-start / auto-stop-on-silence: the sheet only calls this once
        // the user taps Record, so these timers start on user intent, never
        // during their thinking time. `pauseFor` finalises after a post-speech
        // silence (the auto-stop); `listenFor` is a hard cap so a stuck session
        // ends.
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 30),
      ),
    );
  }

  @override
  Future<void> stop() async {
    if (_stt.isListening) await _stt.stop();
  }

  @override
  Future<void> cancel() async {
    if (_stt.isListening) await _stt.cancel();
  }

  @override
  Future<void> dispose() async {
    try {
      await _stt.cancel();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
