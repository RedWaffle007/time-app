import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'npz_reader.dart';

/// One line of the German corpus, and where it came from.
class CorpusLine {
  const CorpusLine({
    required this.text,
    required this.sourceFile,
    required this.english,
  });

  final String text;
  final String sourceFile;

  /// The gloss, precomputed by the same Argos de→en model the server calls at
  /// request time.
  ///
  /// Precomputed rather than translated on the phone because retrieval can only
  /// ever return one of these lines: the runtime translator was a function over
  /// a finite, known domain, so evaluating it ahead of time is not an
  /// approximation of it — it is the same answer, without shipping a 159MB
  /// translation model to every phone.
  ///
  /// Empty when the gloss file is absent, which is a degraded-but-working state,
  /// not a failure.
  final String english;
}

/// The corpus, its vectors, and the nearest-neighbour search over them.
///
/// **Reproduces `backend/search.py` exactly**, which matters more than it
/// sounds: the numbers this returns are compared against a threshold calibrated
/// on the server's numbers. Specifically —
///
///  - vectors are L2-normalized on both sides, so **cosine similarity is a dot
///    product** and nothing else needs computing;
///  - the server ranks with `NearestNeighbors(metric="euclidean")` over those
///    same unit vectors, which orders identically to cosine (‖a−b‖² = 2 − 2a·b
///    is monotonically decreasing in a·b), so ranking by dot product here is
///    the same ranking, not an approximation of it;
///  - ten neighbours are kept, because the anti-repeat rule needs somewhere to
///    go when the best line was the last one served.
class EmbeddingIndex {
  EmbeddingIndex._({
    required this._vectors,
    required this.dimension,
    required this.modelStamp,
    required this._lines,
  });

  /// How many neighbours the server asks for, and therefore how many this must.
  static const int neighbours = 10;

  final Float32List _vectors;
  final List<CorpusLine> _lines;

  final int dimension;

  /// The first 16 hex characters of the sha256 of the ONNX model that built this
  /// index, stamped in by the build script so a mismatch can be *detected*
  /// rather than silently retrieving worse lines forever.
  final String? modelStamp;

  int get length => _lines.length;

  CorpusLine line(int row) => _lines[row];

  /// Load the index, the corpus metadata, and the glosses if they are present.
  ///
  /// [english] is optional on purpose: the gloss file is a separate release
  /// asset, and a build that reaches a device before it does should still
  /// answer in German rather than refuse to start.
  static Future<EmbeddingIndex> load({
    required File index,
    required File meta,
    File? english,
  }) async {
    final archive = NpzArchive.open(await index.readAsBytes());
    final matrix = archive.matrix('embeddings');

    final metaJson = jsonDecode(await meta.readAsString(encoding: utf8));
    if (metaJson is! List) {
      throw const FormatException('subs_meta.json is not a list');
    }

    List<dynamic>? glosses;
    if (english != null && english.existsSync()) {
      final decoded = jsonDecode(await english.readAsString(encoding: utf8));
      if (decoded is List && decoded.length == metaJson.length) {
        glosses = decoded;
      }
      // A gloss file of the wrong length is ignored rather than zipped up to
      // the shorter of the two: row i must mean the same line in both files, and
      // a length mismatch means it does not.
    }

    if (matrix.rows != metaJson.length) {
      throw FormatException(
          'the index has ${matrix.rows} vectors but the corpus has '
          '${metaJson.length} lines — they are not the same build');
    }

    final lines = <CorpusLine>[];
    for (var i = 0; i < metaJson.length; i++) {
      final entry = metaJson[i] as Map<String, dynamic>;
      lines.add(CorpusLine(
        text: (entry['text'] as String?) ?? '',
        sourceFile: (entry['source_file'] as String?) ?? '',
        english: glosses == null ? '' : (glosses[i] as String?) ?? '',
      ));
    }

    return EmbeddingIndex._(
      vectors: matrix.values,
      dimension: matrix.columns,
      modelStamp: archive.scalarString('model_sha256_16'),
      lines: lines,
    );
  }

  /// The [neighbours] best-matching rows for [query], best first.
  ///
  /// [query] must already be L2-normalized — the caller normalizes because it
  /// is the side that just produced the vector, and normalizing twice would be
  /// a silent no-op that hides a caller which forgot.
  List<Neighbour> search(Float32List query) {
    if (query.length != dimension) {
      throw ArgumentError(
          'query has ${query.length} dimensions, index has $dimension');
    }

    // A fixed-size insertion sort over the top ten. Sorting all 5,275 scores
    // would cost more than the dot products that produced them.
    final bestRows = List<int>.filled(neighbours, -1);
    final bestScores = List<double>.filled(neighbours, double.negativeInfinity);

    for (var row = 0; row < _lines.length; row++) {
      final base = row * dimension;
      var dot = 0.0;
      for (var d = 0; d < dimension; d++) {
        dot += _vectors[base + d] * query[d];
      }

      if (dot <= bestScores[neighbours - 1]) continue;
      var slot = neighbours - 1;
      while (slot > 0 && bestScores[slot - 1] < dot) {
        bestScores[slot] = bestScores[slot - 1];
        bestRows[slot] = bestRows[slot - 1];
        slot--;
      }
      bestScores[slot] = dot;
      bestRows[slot] = row;
    }

    final results = <Neighbour>[];
    for (var i = 0; i < neighbours; i++) {
      if (bestRows[i] < 0) break;
      results.add(Neighbour(row: bestRows[i], score: bestScores[i]));
    }
    return results;
  }
}

/// One retrieved row and its cosine similarity to the query.
class Neighbour {
  const Neighbour({required this.row, required this.score});

  final int row;
  final double score;
}
