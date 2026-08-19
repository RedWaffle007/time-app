import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/chatbot/data/ondevice/embedding_index.dart';
import 'package:time_app/features/chatbot/data/ondevice/npz_reader.dart';
import 'package:time_app/features/chatbot/data/ondevice/retrieval_policy.dart';
import 'package:time_app/features/chatbot/data/ondevice/unigram_tokenizer.dart';

/// The on-device engine, minus the one piece a test cannot run.
///
/// The ONNX session needs a device and 143MB of downloaded files, so it is
/// verified on the phone. **Everything either side of it is pure Dart and is
/// verified here**: reading the index NumPy wrote, ranking against it, and the
/// retrieval decisions that have to agree with `backend/app.py` — the threshold,
/// which line gets served, the decline wording, the rounding. Those are exactly
/// the things that would disagree with the server silently.
void main() {
  group('NpzArchive', () {
    test('reads the matrix NumPy wrote, shape and values intact', () async {
      final archive = NpzArchive.open(
          File('test/fixtures/index_fixture.npz').readAsBytesSync());
      final matrix = archive.matrix('embeddings');

      expect(matrix.rows, 4);
      expect(matrix.columns, 4);
      expect(matrix.values, hasLength(16));
      // Row 0 is the unit vector along the first axis.
      expect(matrix.values[0], closeTo(1.0, 1e-6));
      expect(matrix.values[1], closeTo(0.0, 1e-6));
      // Row 2 is [0.6, 0.8, 0, 0] — proving the rows are not transposed, which
      // a column-major misread would produce without any error.
      expect(matrix.values[8], closeTo(0.6, 1e-6));
      expect(matrix.values[9], closeTo(0.8, 1e-6));
    });

    test('carries the stamp that says which model built the index', () async {
      // The stamp exists so a mismatched index can be detected rather than
      // quietly retrieving worse lines forever.
      final archive = NpzArchive.open(
          File('test/fixtures/index_fixture.npz').readAsBytesSync());
      expect(archive.scalarString('model_sha256_16'), '0123456789abcdef');
    });

    test('says so plainly when the file is not a zip at all', () {
      expect(() => NpzArchive.open(Uint8List.fromList(List.filled(64, 7))),
          throwsA(isA<FormatException>()));
    });
  });

  group('EmbeddingIndex', () {
    Future<EmbeddingIndex> load({bool english = true}) => EmbeddingIndex.load(
          index: File('test/fixtures/index_fixture.npz'),
          meta: File('test/fixtures/index_meta_fixture.json'),
          english:
              english ? File('test/fixtures/index_en_fixture.json') : null,
        );

    test('loads vectors, corpus and glosses as one aligned whole', () async {
      final index = await load();
      expect(index.length, 4);
      expect(index.dimension, 4);
      expect(index.line(0).text, 'Erste Zeile');
      expect(index.line(0).sourceFile, 'A.srt');
      expect(index.line(0).english, 'First line');
      expect(index.line(3).english, 'Fourth line');
    });

    test('works without the gloss file, in German only', () async {
      // A build that reaches a phone before the gloss asset does should still
      // answer, not refuse to start.
      final index = await load(english: false);
      expect(index.line(0).text, 'Erste Zeile');
      expect(index.line(0).english, isEmpty);
    });

    test('ranks by cosine, best first', () async {
      final index = await load();
      final results = index.search(Float32List.fromList([1, 0, 0, 0]));

      expect(results.first.row, 0);
      expect(results.first.score, closeTo(1.0, 1e-6));
      expect(results[1].row, 2);
      expect(results[1].score, closeTo(0.6, 1e-6));
      // Four rows, so four neighbours — never a padded ten.
      expect(results, hasLength(4));
    });

    test('refuses a query of the wrong width', () async {
      // A dimension mismatch means the index and the model disagree, and the
      // dot product would happily produce a number anyway.
      final index = await load();
      expect(() => index.search(Float32List.fromList([1, 0])),
          throwsA(isA<ArgumentError>()));
    });

    test('refuses an index and a corpus that are not the same build', () async {
      // 4 vectors against 4 lines is the fixture; pointing it at a longer
      // corpus must fail rather than silently mis-index every reply.
      final wrongMeta = File('${Directory.systemTemp.createTempSync().path}/m.json')
        ..writeAsStringSync('[{"text":"a","source_file":"x"}]');
      addTearDown(() => wrongMeta.parent.deleteSync(recursive: true));

      expect(
        () => EmbeddingIndex.load(
            index: File('test/fixtures/index_fixture.npz'), meta: wrongMeta),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('RetrievalPolicy', () {
    CorpusLine lineAt(int row) => CorpusLine(
          text: 'Zeile $row',
          sourceFile: 'file$row.srt',
          english: 'Line $row',
        );

    test('serves the best line when it clears the threshold', () {
      final reply = RetrievalPolicy().decide(
        neighbours: const [Neighbour(row: 7, score: 0.87)],
        lineAt: lineAt,
        sessionId: 's',
      );

      expect(reply.matched, isTrue);
      expect(reply.german, 'Zeile 7');
      expect(reply.english, 'Line 7');
      expect(reply.sourceFile, 'file7.srt');
      expect(reply.score, 0.87);
    });

    test('declines below 0.55, in the words the server uses', () {
      final reply = RetrievalPolicy().decide(
        neighbours: const [Neighbour(row: 1, score: 0.4552)],
        lineAt: lineAt,
        sessionId: 's',
      );

      // A miss is a normal reply carrying usable German, not a failure.
      expect(reply.matched, isFalse);
      expect(reply.german, RetrievalPolicy.noMatchGerman);
      expect(reply.english, RetrievalPolicy.noMatchEnglish);
      expect(reply.sourceFile, isNull);
      expect(reply.score, 0.4552);
    });

    test('the threshold is inclusive at exactly 0.55', () {
      // `app.py` declines on `< threshold`, so the boundary value is served.
      final reply = RetrievalPolicy().decide(
        neighbours: const [Neighbour(row: 2, score: 0.55)],
        lineAt: lineAt,
        sessionId: 's',
      );
      expect(reply.matched, isTrue);
    });

    test('does not serve the same line twice in a row in one session', () {
      final policy = RetrievalPolicy();
      const neighbours = [
        Neighbour(row: 4, score: 0.9),
        Neighbour(row: 9, score: 0.8),
      ];

      expect(policy.decide(
              neighbours: neighbours, lineAt: lineAt, sessionId: 's')
          .german, 'Zeile 4');
      // Same query again: the top hit is unchanged, so the second-best is served
      // and its own score comes with it.
      final second =
          policy.decide(neighbours: neighbours, lineAt: lineAt, sessionId: 's');
      expect(second.german, 'Zeile 9');
      expect(second.score, 0.8);
    });

    test('the anti-repeat rule is per session, not global', () {
      final policy = RetrievalPolicy();
      const neighbours = [
        Neighbour(row: 4, score: 0.9),
        Neighbour(row: 9, score: 0.8),
      ];

      policy.decide(neighbours: neighbours, lineAt: lineAt, sessionId: 'one');
      // A different chat session has heard nothing yet and gets the best line.
      final other = policy.decide(
          neighbours: neighbours, lineAt: lineAt, sessionId: 'two');
      expect(other.german, 'Zeile 4');
    });

    test('repeats rather than serving nothing when there is no alternative', () {
      final policy = RetrievalPolicy();
      const only = [Neighbour(row: 4, score: 0.9)];

      policy.decide(neighbours: only, lineAt: lineAt, sessionId: 's');
      expect(
          policy.decide(neighbours: only, lineAt: lineAt, sessionId: 's').german,
          'Zeile 4');
    });

    test('a decline does not count as a line served', () {
      // The server only records a served line on the match path, so a decline
      // must not consume the anti-repeat slot.
      final policy = RetrievalPolicy();
      const good = [Neighbour(row: 4, score: 0.9), Neighbour(row: 9, score: 0.8)];

      policy.decide(neighbours: good, lineAt: lineAt, sessionId: 's');
      policy.decide(
          neighbours: const [Neighbour(row: 4, score: 0.1)],
          lineAt: lineAt,
          sessionId: 's');
      // Still remembers row 4 from the match, so it moves on to row 9.
      expect(
          policy.decide(neighbours: good, lineAt: lineAt, sessionId: 's').german,
          'Zeile 9');
    });

    test('rounds the score to four places, as the server does', () {
      final reply = RetrievalPolicy().decide(
        neighbours: const [Neighbour(row: 1, score: 0.876543210)],
        lineAt: lineAt,
        sessionId: 's',
      );
      expect(reply.score, 0.8765);
    });

    test('a line with no source file reports none rather than an empty one', () {
      final reply = RetrievalPolicy().decide(
        neighbours: const [Neighbour(row: 0, score: 0.9)],
        lineAt: (_) =>
            const CorpusLine(text: 'x', sourceFile: '', english: ''),
        sessionId: 's',
      );
      expect(reply.sourceFile, isNull);
    });
  });

  group('isolate loading', () {
    test('a parsed tokenizer survives being built off the main isolate',
        () async {
      // The real tokenizer is 17MB of JSON and the index 8MB of vectors; parsing
      // either on the UI isolate freezes the frame that opened the chat. That is
      // only an option if the parsed result can cross an isolate boundary, which
      // is a property of what the object holds — so it is asserted, not assumed.
      final tokenizer = await Isolate.run(() =>
          UnigramTokenizer.load(File('test/fixtures/tokenizer_fixture.json')));

      expect(tokenizer.encode('Hallo').length, greaterThan(2));
      expect(tokenizer.encode('Hallo').first, tokenizer.bosId);
    });

    test('a loaded index survives being built off the main isolate', () async {
      final index = await Isolate.run(() => EmbeddingIndex.load(
            index: File('test/fixtures/index_fixture.npz'),
            meta: File('test/fixtures/index_meta_fixture.json'),
            english: File('test/fixtures/index_en_fixture.json'),
          ));

      expect(index.length, 4);
      expect(index.search(Float32List.fromList([1, 0, 0, 0])).first.row, 0);
    });
  });
}
