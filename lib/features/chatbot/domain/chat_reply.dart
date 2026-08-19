import 'package:flutter/foundation.dart';

/// One answer from the practice bot, in the shape the UI needs — never the
/// shape the wire happens to use today.
///
/// This is the **return type of the seam** (`ChatbotService`), so it is
/// deliberately free of anything transport-specific: no status code, no URL, no
/// JSON. The on-device implementation that replaces the HTTP one later has to
/// be able to fill this in without pretending to be a server.
///
/// [sourceFile] and [score] are carried because the offline index exposes them
/// and they are cheap to keep; the chat UI does not render them today. They are
/// diagnostic, not product.
@immutable
class ChatReply {
  const ChatReply({
    required this.german,
    required this.english,
    required this.matched,
    this.sourceFile,
    this.score = 0,
  });

  /// The reply itself. This is the thing being practised, so it leads.
  final String german;

  /// The gloss. Secondary by design — reading it should be a choice, not the
  /// first thing the eye lands on.
  final String english;

  /// False when the retrieval index had nothing above its confidence
  /// threshold. **Not an error**: the service still returns a usable, graceful
  /// reply ("say that another way"), and the UI shows it as a normal turn with
  /// a quiet marker. Treating a miss as a failure would train the user to
  /// distrust a working service.
  final bool matched;

  /// Which corpus file the match came from, when there was one.
  final String? sourceFile;

  /// Match confidence, 0–1. Meaningless when [matched] is false.
  final double score;
}
