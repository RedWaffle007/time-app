import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Turns token ids into the 384-dimensional sentence vector, on the phone.
///
/// **Mean pooling is inside the graph, not here.** `tools/export_onnx.py`
/// exported the encoder *and* the attention-masked mean pooling as one model
/// whose single output is `sentence_embedding`, precisely so a mobile caller
/// would not have to reimplement pooling and get it subtly wrong. What is left
/// on this side is what the Python pipeline also left outside the graph: the L2
/// normalization (`normalize_output: false` in the exporter's `pooling.json`).
///
/// The graph is dynamic on batch and sequence, so a query is run as a batch of
/// one at its own natural length — no padding, and therefore an attention mask
/// that is all ones.
class OnnxEmbedder {
  OnnxEmbedder._(this._session);

  final OrtSession _session;

  /// The output the exporter named. Asked for by name rather than by position
  /// so a graph with a different signature fails loudly instead of embedding
  /// whatever tensor happened to come first.
  static const String _outputName = 'sentence_embedding';

  static Future<OnnxEmbedder> load(String modelPath) async {
    final session = await OnnxRuntime().createSession(modelPath);
    return OnnxEmbedder._(session);
  }

  /// The L2-normalized sentence vector for [tokenIds].
  Future<Float32List> embed(Int64List tokenIds) async {
    final length = tokenIds.length;
    final shape = [1, length];

    // Every token is real — this is a batch of one, so nothing is padded and
    // the mask cannot mask anything out. It is still required: the pooling
    // inside the graph divides by the mask's sum.
    final mask = Int64List(length)..fillRange(0, length, 1);

    final ids = await OrtValue.fromList(tokenIds, shape);
    final attention = await OrtValue.fromList(mask, shape);

    Map<String, OrtValue>? outputs;
    try {
      outputs = await _session.run({
        'input_ids': ids,
        'attention_mask': attention,
      });

      final output = outputs[_outputName];
      if (output == null) {
        throw StateError(
            'the model produced no "$_outputName" output; it is not the '
            'embedder this build expects');
      }

      final flat = await output.asFlattenedList();
      return _normalize(flat);
    } finally {
      // Native tensors are not garbage collected with their Dart handles. A
      // message every few seconds that leaks two of them is a slow crash, so
      // the release happens on the failure path too.
      await ids.dispose();
      await attention.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  /// L2-normalize, matching `search.py`'s `q / (norm + 1e-12)`.
  ///
  /// The epsilon is carried across rather than replaced with a zero check: it is
  /// what the corpus side did, and on a zero vector the two differ.
  static Float32List _normalize(List<dynamic> flat) {
    final vector = Float32List(flat.length);
    var sum = 0.0;
    for (var i = 0; i < flat.length; i++) {
      final value = (flat[i] as num).toDouble();
      vector[i] = value;
      sum += value * value;
    }

    final norm = math.sqrt(sum) + 1e-12;
    for (var i = 0; i < vector.length; i++) {
      vector[i] = vector[i] / norm;
    }
    return vector;
  }

  Future<void> dispose() => _session.close();
}
