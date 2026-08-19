import '../domain/chat_reply.dart';

/// **The swap seam.** Everything the chat UI knows about where replies come
/// from is this one method.
///
/// Today there is one implementation, [HttpChatbotService], which POSTs to the
/// offline retrieval service running on a laptop. The long-term direction is an
/// **on-device** implementation with no server at all: when that lands it
/// implements this same interface, `chatbotServiceProvider` returns it instead,
/// and no screen changes. That is the whole point of keeping this to one
/// method with no transport in its signature.
///
/// Rules that keep the seam a seam:
///  - **No HTTP vocabulary crosses it.** No URLs, no status codes, no headers,
///    no JSON. `/health` is not modelled here either — it is an HTTP-only
///    diagnostic and an on-device engine has no such concept.
///  - **A low-confidence match is not a failure.** It comes back as a normal
///    [ChatReply] with `matched: false`. Only a turn that produced no usable
///    reply at all throws.
///  - **The only thing that may be thrown is [ChatbotFailure].** An
///    implementation translates its own errors — socket, timeout, model load,
///    whatever it has — into one message a user can act on.
abstract interface class ChatbotService {
  /// Send [message] and get the reply for it.
  ///
  /// [sessionId] identifies one continuous conversation, so an implementation
  /// that keeps context can. It is generated per chat-screen session; nothing
  /// about it is persisted.
  ///
  /// Throws [ChatbotFailure] — and nothing else — when the turn cannot be
  /// completed.
  Future<ChatReply> send({
    required String sessionId,
    required String message,
  });
}

/// A turn that could not be completed, already phrased for the user.
///
/// The [message] is what the chat screen renders verbatim, so it is written as
/// a sentence with a next step in it ("is the laptop awake?"), not as a
/// diagnostic string. The implementation is the only layer that knows *why*
/// something failed, so it is the only layer that can say it usefully.
class ChatbotFailure implements Exception {
  const ChatbotFailure(this.message);

  final String message;

  @override
  String toString() => 'ChatbotFailure: $message';
}
