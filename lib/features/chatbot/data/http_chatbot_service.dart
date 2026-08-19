import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/chat_reply.dart';
import 'chatbot_endpoint_store.dart';
import 'chatbot_service.dart';

/// Today's implementation of the seam: the offline retrieval bot, reached over
/// the network as an HTTP service.
///
/// **Every address and transport concern in the feature is inside this class.**
/// The contract it speaks:
///
/// ```
/// POST {base}/chat   {"session_id": "...", "message": "..."}
///   -> {"reply_german": "...", "reply_english": "...",
///       "source_file": "...", "matched": true|false, "score": 0.0}
/// ```
///
/// `GET {base}/health` exists on the service but is deliberately not called:
/// it would only tell us what the next `/chat` is about to tell us anyway, and
/// a health concept has no meaning for the on-device engine that replaces this
/// class later.
///
/// The base URL is read from [ChatbotEndpointStore] **on every send**, not
/// captured once in the constructor. `SharedPreferences` caches in memory, so
/// the read is cheap, and it means editing the address in settings takes effect
/// on the very next message with no invalidation, no restart, and no listener
/// wiring between the settings screen and this object.
class HttpChatbotService implements ChatbotService {
  HttpChatbotService(this._endpoints, {http.Client? client})
      : _client = client ?? http.Client();

  final ChatbotEndpointStore _endpoints;
  final http.Client _client;

  /// Long enough for a first request that has to wake a sleeping Wi-Fi link,
  /// short enough that a wrong address does not look like a hang. A dead host
  /// usually fails much faster than this; the timeout is for the case that
  /// doesn't.
  static const _timeout = Duration(seconds: 20);

  @override
  Future<ChatReply> send({
    required String sessionId,
    required String message,
  }) async {
    final base = await _endpoints.baseUrl();
    final uri = Uri.parse('$base/chat');

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'session_id': sessionId, 'message': message}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw ChatbotFailure(
        "$base didn't answer in time. If the laptop just woke up, try again.",
      );
    } on SocketException {
      throw ChatbotFailure(_unreachable(base));
    } on http.ClientException {
      // What a dropped or refused connection surfaces as on Android, where the
      // underlying SocketException is wrapped rather than rethrown.
      throw ChatbotFailure(_unreachable(base));
    }

    if (response.statusCode != 200) {
      throw ChatbotFailure(
        'The practice service answered ${response.statusCode}. '
        'That address is reachable but is not the chatbot, or the chatbot is '
        'unhealthy.',
      );
    }

    return _parse(response, base);
  }

  ChatReply _parse(http.Response response, String base) {
    // Decoded as UTF-8 from the raw bytes, NOT `response.body`. `body` falls
    // back to latin1 unless the response names a charset, which turns every
    // umlaut and ß in a German reply into mojibake — the one encoding bug this
    // feature is guaranteed to hit if it is left to the default.
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      json = decoded;
    } on FormatException {
      throw ChatbotFailure(
        "$base answered, but not with anything this app understands. "
        'Check that it is the chatbot service.',
      );
    }

    final german = (json['reply_german'] as String?)?.trim() ?? '';
    final english = (json['reply_english'] as String?)?.trim() ?? '';
    if (german.isEmpty && english.isEmpty) {
      throw ChatbotFailure('The practice service replied with nothing.');
    }

    return ChatReply(
      // `matched` absent is read as a miss, not a hit: the quiet marker on a
      // reply that was actually fine is a far smaller harm than presenting an
      // unmatched fallback as if it were a real answer.
      matched: json['matched'] == true,
      german: german,
      english: english,
      sourceFile: (json['source_file'] as String?)?.trim(),
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }

  String _unreachable(String base) =>
      "Couldn't reach $base. Check the laptop is awake, on Tailscale, and "
      'running the service — or fix the address in settings.';

  /// Closes the shared connection pool. Called from the provider's `onDispose`;
  /// not part of [ChatbotService], because "close your sockets" is a fact about
  /// this implementation and not about the seam.
  void dispose() => _client.close();
}
