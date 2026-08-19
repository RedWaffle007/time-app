import 'package:flutter/foundation.dart';

import 'chat_reply.dart';

/// One row in the transcript.
///
/// Sealed so the screen's renderer must handle every kind: a new message type
/// added later is a compile error at the switch, not a row that silently draws
/// as nothing.
///
/// A failure is a transcript row rather than a banner over the screen on
/// purpose — it belongs *to the turn that failed*, next to the message it
/// failed to answer, and it carries the text needed to try that exact turn
/// again. A screen-level error bar would lose both facts.
@immutable
sealed class ChatMessage {
  const ChatMessage();
}

/// Something the user said.
final class UserMessage extends ChatMessage {
  const UserMessage(this.text);
  final String text;
}

/// Something the bot said, matched or not.
final class BotMessage extends ChatMessage {
  const BotMessage(this.reply);
  final ChatReply reply;
}

/// The turn never completed — the service was unreachable, timed out, or
/// answered with something unusable.
final class FailureMessage extends ChatMessage {
  const FailureMessage({required this.text, required this.retryOf});

  /// What went wrong, phrased for the person holding the phone.
  final String text;

  /// The user text this failed turn was answering, so Retry can re-send exactly
  /// that without the user re-typing it and without a duplicate user bubble.
  final String retryOf;
}
