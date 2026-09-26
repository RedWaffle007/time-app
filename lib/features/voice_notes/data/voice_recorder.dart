import 'package:record/record.dart';

/// Records the planner's voice note (item 32b). A seam so the builder can be
/// tested without a microphone; only this file knows the `record` package.
abstract interface class VoiceRecorder {
  /// Whether the microphone may be used. With [request] the OS prompt is
  /// shown — callers explain first (never a raw prompt).
  Future<bool> hasPermission({bool request = false});

  /// Start recording AAC into an .m4a at [path].
  Future<void> start(String path);

  /// Stop; the finished file's path (null if nothing was recorded).
  Future<String?> stop();

  /// Stop and throw the recording away.
  Future<void> cancel();

  Future<void> dispose();
}

/// The one format the Worker accepts: AAC-LC in an MPEG-4 container, mono,
/// ~64 kbps — a 20 s note is ~160 KB, under the 256 KB cap.
const kVoiceRecordConfig = RecordConfig(
  encoder: AudioEncoder.aacLc,
  bitRate: 64000,
  sampleRate: 44100,
  numChannels: 1,
);

class RecordPackageVoiceRecorder implements VoiceRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission({bool request = false}) =>
      _recorder.hasPermission(request: request);

  @override
  Future<void> start(String path) =>
      _recorder.start(kVoiceRecordConfig, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}
