import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../domain/chat_reply.dart';
import 'chatbot_service.dart';
import 'model_manifest.dart';
import 'model_store.dart';
import 'ondevice/embedding_index.dart';
import 'ondevice/onnx_embedder.dart';
import 'ondevice/retrieval_policy.dart';
import 'ondevice/unigram_tokenizer.dart';

/// The seam's on-device implementation: the whole chatbot, running on the phone.
///
/// **This is the point of the entire feature.** With this in
/// `chatbotServiceProvider`, a reply needs no laptop, no Tailscale, no Worker
/// and no internet — the phone can be in airplane mode. Nothing here opens a
/// socket, and there is no address to configure, which is why
/// [ChatbotEndpointStore] and the settings screen die with the HTTP
/// implementation rather than with this one.
///
/// **It reproduces `backend/app.py` and `backend/search.py`, deliberately, step
/// for step**, because the numbers it produces are compared against a threshold
/// calibrated on the server's numbers:
///
/// ```
/// normalize -> tokenize (XLM-R Unigram, 128) -> ONNX MiniLM (mean pooled)
///   -> L2 normalize -> cosine vs the index -> top 10
///   -> best < 0.55 ? decline : serve, skipping a repeat of the last line
/// ```
///
/// The one deliberate divergence is the English gloss, and it is a divergence in
/// *when*, not in *what*: the server calls Argos per request, and this reads the
/// answer Argos already gave for that same line. Retrieval can only ever return
/// one of the 5,275 corpus lines, so the runtime translator was a function over
/// a finite known domain (DECISIONS.md, 2026-08-19).
class OnDeviceChatbotService implements ChatbotService {
  OnDeviceChatbotService(this._store);

  final ModelStore _store;

  /// The loaded engine, or the load in flight.
  ///
  /// Held as the Future rather than the result so two messages sent before the
  /// first load finishes **join** it instead of each parsing 17MB of tokenizer
  /// and opening a second ONNX session.
  Future<_Engine>? _engine;

  /// The threshold, the decline wording and the anti-repeat rule — the parity
  /// surface, kept where it can be tested without a phone.
  final RetrievalPolicy _policy = RetrievalPolicy();

  @override
  Future<ChatReply> send({
    required String sessionId,
    required String message,
  }) async {
    final engine = await _load();

    final List<Neighbour> neighbours;
    try {
      final tokens = engine.tokenizer.encode(message);
      final vector = await engine.embedder.embed(tokens);
      neighbours = engine.index.search(vector);
      if (neighbours.isEmpty) {
        throw const ChatbotFailure(
            'The phrase index came back empty. Re-downloading the offline '
            'model from the chat menu should fix it.');
      }
    } on ChatbotFailure {
      rethrow;
    } catch (_) {
      // Anything the runtime throws mid-inference: an ORT session that died
      // with the app in the background is the realistic one.
      throw const ChatbotFailure(
          "The offline model couldn't answer that one. Try again, or reopen "
          'the chat if it keeps happening.');
    }

    return _policy.decide(
      neighbours: neighbours,
      lineAt: engine.index.line,
      sessionId: sessionId,
    );
  }

  /// Load the tokenizer, the index and the ONNX session, once.
  Future<_Engine> _load() => _engine ??= _build().onError((error, stack) {
        // A failed load must not be cached, or the app is stuck with it until
        // it is killed — the model may simply not have finished downloading.
        _engine = null;
        throw error is ChatbotFailure
            ? error
            : const ChatbotFailure(
                "The offline model couldn't be loaded. Check it finished "
                'downloading under Offline model, then try again.');
      });

  Future<_Engine> _build() async {
    // Captured as a plain String, not a Directory: the closures below cross an
    // isolate boundary, and a String is unambiguously sendable.
    final root = (await _store.directory()).path + Platform.pathSeparator;

    final modelFile = File('$root$kOnnxModelFile');
    if (!modelFile.existsSync()) {
      throw const ChatbotFailure(
          'The offline model is not on this phone yet. Download it from '
          'Offline model in the chat menu.');
    }

    // Parsed off the UI isolate. The tokenizer is 17MB of JSON and the index is
    // 8MB of compressed vectors; doing either on the main isolate freezes the
    // frame that opened the chat. Both are plain data with no platform handles
    // in them, which is what makes them sendable.
    final tokenizer = await Isolate.run(
        () => UnigramTokenizer.load(File('$root$kTokenizerFile')));

    final index = await Isolate.run(() => EmbeddingIndex.load(
          index: File('$root$kEmbeddingsFile'),
          meta: File('$root$kMetaFile'),
          english: File('$root$kEnglishFile'),
        ));

    // The ONNX session must be created here, not in the isolate: it is a
    // platform-channel handle and does not survive being sent.
    final embedder = await OnnxEmbedder.load(modelFile.path);

    return _Engine(tokenizer: tokenizer, index: index, embedder: embedder);
  }

  /// Releases the ONNX session. Registered on the provider's `onDispose`, the
  /// same way `HttpChatbotService.dispose` is, and for the same reason: closing
  /// a native handle is a fact about this implementation, not about the seam.
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await (await engine).embedder.dispose();
    } catch (_) {
      // A session that already failed to load has nothing to close, and a
      // teardown that throws would take the provider container with it.
    }
  }
}

/// The three loaded pieces, kept together so they are replaced together.
class _Engine {
  const _Engine({
    required this.tokenizer,
    required this.index,
    required this.embedder,
  });

  final UnigramTokenizer tokenizer;
  final EmbeddingIndex index;
  final OnnxEmbedder embedder;
}
