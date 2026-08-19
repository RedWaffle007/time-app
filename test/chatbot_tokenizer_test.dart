import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/chatbot/data/ondevice/precompiled_normalizer.dart';
import 'package:time_app/features/chatbot/data/ondevice/unigram_tokenizer.dart';

/// The on-device tokenizer, checked against the tokenizer that built the index.
///
/// **Why goldens and not hand-written expectations.** "Correct" here has exactly
/// one definition: whatever HuggingFace's fast tokenizer did when the corpus was
/// embedded. A query tokenized even slightly differently produces no error —
/// just an embedding that lands somewhere else and retrieves a worse line. So
/// every expectation in this file was produced by running the real tokenizer,
/// and the Dart implementation is measured against it rather than against
/// anyone's idea of what XLM-R ought to do.
///
/// The fixture is the real `tokenizer.json` with its **real** Precompiled
/// charsmap and a vocabulary cut down to what these texts need — the 17MB
/// original is a downloaded model asset and cannot live in the repo, but the
/// normalizer is the part that cannot be approximated, so it is carried whole.
void main() {
  late Map<String, dynamic> fixture;
  late List<dynamic> golden;
  late UnigramTokenizer tokenizer;

  setUpAll(() {
    fixture = jsonDecode(File('test/fixtures/tokenizer_fixture.json')
        .readAsStringSync(encoding: utf8)) as Map<String, dynamic>;
    golden = jsonDecode(File('test/fixtures/tokenizer_golden.json')
        .readAsStringSync(encoding: utf8)) as List<dynamic>;
    tokenizer = UnigramTokenizer.fromJson(fixture);
  });

  group('PrecompiledNormalizer', () {
    test('reproduces the reference normalization for every golden text', () {
      final normalizer = PrecompiledNormalizer.fromBase64(
          (fixture['normalizer'] as Map)['precompiled_charsmap'] as String);

      for (final row in golden) {
        final text = row['text'] as String;
        expect(normalizer.normalize(text), row['normalized'] as String,
            reason: 'normalizing ${jsonEncode(text)}');
      }
    });

    test('folds exactly the things NFKC would miss', () {
      // The cases that prove this is a charsmap and not a stand-in: NFKC leaves
      // a tab, a newline and a zero-width space alone, and this map does not.
      final normalizer = PrecompiledNormalizer.fromBase64(
          (fixture['normalizer'] as Map)['precompiled_charsmap'] as String);

      expect(normalizer.normalize('x\ty'), 'x y');
      expect(normalizer.normalize('line\nbreak'), 'line break');
      expect(normalizer.normalize('​zero'), ' zero');
      expect(normalizer.normalize('﻿1'), ' 1');
      expect(normalizer.normalize(' nbsp'), ' nbsp');
      // ...while leaving German alone, which is the far more common case.
      expect(normalizer.normalize('Grüße aus München!'), 'Grüße aus München!');
    });

    test('an empty string survives', () {
      final normalizer = PrecompiledNormalizer.fromBase64(
          (fixture['normalizer'] as Map)['precompiled_charsmap'] as String);
      expect(normalizer.normalize(''), '');
    });
  });

  group('UnigramTokenizer', () {
    test('reproduces the reference token ids for every golden text', () {
      for (final row in golden) {
        final text = row['text'] as String;
        final expected = (row['ids'] as List).cast<int>();
        expect(tokenizer.encode(text).toList(), expected,
            reason: 'encoding ${jsonEncode(text)}');
      }
    });

    test('a long input truncates to 128 ids and still closes with </s>', () {
      // The index was built at max_length=128 with the specials counted inside
      // it. A sequence that ran past that, or lost its closing token to the
      // cut, would be a different input to the model than the corpus saw.
      final ids = tokenizer.encode('Zeit ' * 300);
      expect(ids, hasLength(UnigramTokenizer.maxSequenceLength));
      expect(ids.first, tokenizer.bosId);
      expect(ids.last, tokenizer.eosId);
    });

    test('empty and whitespace-only input is just the specials', () {
      expect(tokenizer.encode('').toList(), [tokenizer.bosId, tokenizer.eosId]);
      expect(
          tokenizer.encode('   ').toList(), [tokenizer.bosId, tokenizer.eosId]);
    });

    test('adjacent unknown characters fuse into one <unk>', () {
      // The reference fuses them; two ids where the corpus side produced one is
      // a different sequence and a different embedding.
      final ids = tokenizer.encode('🎉🎉').toList();
      expect(ids.where((id) => id == tokenizer.unkId), hasLength(1));
    });

    test('refuses a tokenizer.json it cannot run', () {
      // Mis-tokenizing every query in silence is a far worse failure than not
      // starting, so the parser is strict about what it recognises.
      expect(
        () => UnigramTokenizer.fromJson({
          'model': {'type': 'BPE', 'vocab': {}},
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UnigramTokenizer.fromJson({
          'normalizer': {'type': 'NFKC'},
          'model': {
            'type': 'Unigram',
            'unk_id': 3,
            'vocab': [
              ['<unk>', 0.0]
            ],
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
