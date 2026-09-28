import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where feedback goes.
const kFeedbackAddress = 'mjqsoftware.inc@gmail.com';

const kFeedbackSubject = 'Mind Time feedback';

/// Opens the user's email app on a prefilled message (Settings → Send
/// feedback). The native side is `time_app/feedback` in MainActivity.
abstract interface class FeedbackLauncher {
  /// False when no email app could take it.
  Future<bool> compose({
    required String to,
    required String subject,
    required String body,
  });
}

class PlatformFeedbackLauncher implements FeedbackLauncher {
  static const _channel = MethodChannel('time_app/feedback');

  @override
  Future<bool> compose({
    required String to,
    required String subject,
    required String body,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('compose', {
            'to': to,
            'subject': subject,
            'body': body,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

final feedbackLauncherProvider = Provider<FeedbackLauncher>(
  (ref) => PlatformFeedbackLauncher(),
);
