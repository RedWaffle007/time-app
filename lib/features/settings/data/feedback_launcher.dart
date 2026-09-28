import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where feedback goes. **PLACEHOLDER** until the developer supplies the
/// real address (2026-09-28) — change it here and nowhere else.
const kFeedbackAddress = 'developer@example.com';

const kFeedbackSubject = 'RingaPop feedback';

/// The prefilled message: room to write, then the app version so a report
/// says which build it came from.
String feedbackEmailBody(String? version) =>
    '\n\n---\nApp version: ${version ?? 'unknown'}';

/// Opens the user's email app on a prefilled message (Settings → Send
/// feedback). The native side is `time_app/feedback` in MainActivity.
abstract interface class FeedbackLauncher {
  /// False when no email app could take it.
  Future<bool> compose({
    required String to,
    required String subject,
    required String body,
  });

  Future<String?> appVersion();
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

  @override
  Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('version');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final feedbackLauncherProvider = Provider<FeedbackLauncher>(
  (ref) => PlatformFeedbackLauncher(),
);
