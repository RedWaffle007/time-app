/// **The swap seam for voice capture.** Everything the voice UI knows about how
/// speech becomes text — and how a prompt is spoken — is this one interface.
///
/// Today there is one implementation, [PlatformSpeechService], which wraps the
/// device's own recognizer (`speech_to_text`) and TTS (`flutter_tts`). An
/// on-device custom engine, or iOS-specific behaviour, would land as a second
/// implementation behind this same interface, swapped at the single line in
/// `speechServiceProvider`, with no screen change. That is the whole point of
/// keeping this to a handful of methods with no OS vocabulary in their
/// signatures.
///
/// Rules that keep the seam a seam:
///  - **No plugin type crosses it.** No `SpeechRecognitionResult`, no
///    `LocaleName`, no `TtsState`. Only `String`/`bool` move across.
///  - **A denied microphone is not an exception.** [ensureReady] returns
///    `false`; the caller then falls back to the identical manual flow. Nothing
///    here throws for the ordinary "user said no" or "no recognizer" cases.
abstract interface class SpeechService {
  /// Initialise the recognizer and, on first use, trigger the OS microphone
  /// prompt. Returns whether recognition is available AND permitted.
  ///
  /// The caller MUST have shown the on-screen rationale before calling this —
  /// this is the method that fires the raw OS prompt, and the doctrine is that
  /// no raw prompt fires before an explanation.
  Future<bool> ensureReady();

  /// Speak [text] aloud through the platform TTS and complete when it has
  /// finished. Best-effort: a device with no TTS voice resolves silently rather
  /// than throwing, because the same text is always on screen too.
  Future<void> speak(String text);

  /// Listen for one utterance. [onResult] is called repeatedly with the growing
  /// partial transcript and a final flag; the final call has `isFinal == true`.
  /// The stream of callbacks ends on silence, on [stop], or on [cancel].
  Future<void> listen({
    required void Function(String transcript, bool isFinal) onResult,
    String? localeId,
  });

  /// Stop listening and let the recognizer emit its final result — the "I'm
  /// done talking" button.
  Future<void> stop();

  /// Abandon the current listen with no final result — dismissal / cancel.
  Future<void> cancel();

  /// Release native resources. Called from the provider's `onDispose`.
  Future<void> dispose();
}
