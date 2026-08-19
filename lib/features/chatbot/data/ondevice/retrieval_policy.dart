import '../../domain/chat_reply.dart';
import 'embedding_index.dart';

/// What to do with the ten nearest lines: serve one, or decline.
///
/// **Separated from the engine so it can be tested without one.** Everything
/// upstream of here — tokenizer, ONNX session, 8MB of vectors — needs a real
/// device and 143MB of files. This part needs neither, and it is the part
/// carrying the parity requirements: the threshold, which line gets served, the
/// exact decline wording, and the rounding. Those are the things that would
/// silently disagree with the server, so they are the things with tests on them.
///
/// It reproduces `backend/app.py`'s `/chat` handler together with
/// `backend/search.py`'s session bookkeeping.
class RetrievalPolicy {
  /// Cosine below which the corpus has nothing worth serving.
  ///
  /// **0.55, matching the deployed service** (`MATCH_THRESHOLD` in `app.py`).
  /// Not a guess: CHATBOT_INVENTORY.md §7 measured the worst genuine query at
  /// 0.6893 and the best meaningful off-topic query at 0.4552, and 0.55 sits in
  /// the empty band between them. It leans low on purpose — this is a practice
  /// tool, people type broken German, and a false "didn't catch that" on a real
  /// question is the worse failure.
  ///
  /// Its known limit, from the same measurements: keyboard mash is *not* caught.
  /// `qqqqqqqqqq` scores 0.7867 and sails past any cutoff that keeps real
  /// queries. That is an input-validation problem, not a similarity one, and it
  /// is unsolved on both sides.
  static const double matchThreshold = 0.55;

  /// The decline, word for word as the server sends it.
  ///
  /// A miss is a **normal reply**, not an error: the user gets a usable German
  /// sentence and the UI marks it quietly. Treating it as a failure would train
  /// people to distrust a service that is working exactly as designed.
  static const String noMatchGerman =
      'Das habe ich nicht ganz verstanden. Kannst du das anders sagen?';
  static const String noMatchEnglish =
      "I didn't quite catch that. Could you rephrase?";

  /// The last line served in each session, so the same one is not served twice
  /// in a row. `search.py` keeps exactly this, keyed the same way.
  ///
  /// In memory and session-scoped: a `session_id` is minted per chat screen and
  /// never persisted, so this dies with the process just as the server's does.
  final Map<String, int> _lastServed = {};

  /// The reply for [neighbours], best first.
  ///
  /// [lineAt] resolves a row to its corpus line — a function rather than the
  /// [EmbeddingIndex] itself, so a test can supply four lines instead of 5,275
  /// vectors.
  ChatReply decide({
    required List<Neighbour> neighbours,
    required CorpusLine Function(int row) lineAt,
    required String sessionId,
  }) {
    if (neighbours.isEmpty) {
      throw StateError('decide() needs at least one neighbour');
    }

    // Thresholded on the BEST score, never on the score of the line finally
    // served: `app.py` asks "is this query answerable at all?" *before* the
    // anti-repeat rule is allowed to move the answer to a lower-scoring line.
    // Thresholding after would let the repeat rule turn an answerable query
    // into a decline.
    final best = neighbours.first;
    if (best.score < matchThreshold) {
      return ChatReply(
        matched: false,
        german: noMatchGerman,
        english: noMatchEnglish,
        score: round4(best.score),
      );
    }

    final chosen = _chooseWithoutRepeating(neighbours, sessionId);
    final line = lineAt(chosen.row);

    return ChatReply(
      matched: true,
      german: line.text,
      // Empty when the gloss file is not installed. A German-only reply is a
      // degraded reply, not a broken one.
      english: line.english,
      sourceFile: line.sourceFile.isEmpty ? null : line.sourceFile,
      score: round4(chosen.score),
    );
  }

  /// The best neighbour that is not the one this session just heard.
  ///
  /// `search.py`'s rule exactly, including its fallback: if every candidate is
  /// the last line — which needs an index of one row — it serves it again rather
  /// than serving nothing.
  Neighbour _chooseWithoutRepeating(
      List<Neighbour> neighbours, String sessionId) {
    final last = _lastServed[sessionId];
    var chosen = neighbours.first;

    if (last != null && chosen.row == last) {
      for (final candidate in neighbours) {
        if (candidate.row != last) {
          chosen = candidate;
          break;
        }
      }
    }

    _lastServed[sessionId] = chosen.row;
    return chosen;
  }

  /// Matches the server's `round(score, 4)`. The value is diagnostic, but a
  /// diagnostic that disagrees with the service it was copied from is worse
  /// than none.
  static double round4(double value) => (value * 10000).round() / 10000;
}
