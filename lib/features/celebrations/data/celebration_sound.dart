import 'package:flutter/services.dart';

abstract interface class CelebrationSound {
  Future<void> play();
  Future<void> stop();
}

class PlatformCelebrationSound implements CelebrationSound {
  const PlatformCelebrationSound();

  static const _channel = MethodChannel('time_app/celebration_sound');

  @override
  Future<void> play() async {
    try {
      await _channel.invokeMethod<void>('play');
    } on MissingPluginException {
      // Android-only feature for now. A missing implementation must not prevent
      // the visual celebration or its durable acknowledgement.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Expected outside Android.
    }
  }
}
