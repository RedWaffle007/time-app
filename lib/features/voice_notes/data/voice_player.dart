import 'dart:async';

import 'package:flutter/services.dart';

/// Plays a voice note for preview (the planner after recording, the target
/// before approving). Native MediaPlayer on the MEDIA stream behind the
/// `time_app/voice_player` channel — ring-time playback is the alarm
/// service's job, not this.
abstract interface class VoicePlayer {
  Future<void> play(String path);
  Future<void> stop();

  /// Fires when playback reaches the end on its own.
  Stream<void> get completed;
}

class PlatformVoicePlayer implements VoicePlayer {
  PlatformVoicePlayer() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'completed') _completed.add(null);
    });
  }

  static const channelName = 'time_app/voice_player';
  static const _channel = MethodChannel(channelName);
  final _completed = StreamController<void>.broadcast();

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> play(String path) =>
      _channel.invokeMethod<void>('play', {'path': path});

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No native side (tests / other platforms): nothing is playing.
    }
  }
}
