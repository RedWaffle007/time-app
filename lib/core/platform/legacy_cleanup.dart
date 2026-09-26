import 'dart:io';

import 'package:flutter/foundation.dart';

/// The removed language-practice chatbot downloaded ~143 MB of model files into
/// `support/chatbot_model` (commit 8b0b3e6 removed the feature but not the
/// files). Delete them once; a no-op when absent. Best-effort, never blocks
/// startup, never throws (item F6, 2026-09-26).
const kLegacyChatbotModelFolder = 'chatbot_model';

Future<bool> removeLegacyChatbotModel(Directory support) async {
  try {
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}$kLegacyChatbotModelFolder',
    );
    if (!await dir.exists()) return false;
    await dir.delete(recursive: true);
    return true;
  } catch (e) {
    debugPrint('Legacy chatbot model cleanup failed: $e');
    return false;
  }
}
