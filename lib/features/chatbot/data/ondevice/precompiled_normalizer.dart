import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

/// SentencePiece's `precompiled_charsmap` normalizer, reimplemented.
///
/// **Why this exists at all.** The corpus index was built by the Python
/// pipeline, whose tokenizer normalizes text before it ever reaches the model.
/// The query has to travel the identical road or it lands somewhere else in the
/// embedding space — quietly, with no error, just worse answers. Dart has no
/// Unicode normalization in its SDK and NFKC would not be enough anyway: this
/// map also folds tabs, newlines, zero-width spaces and the BOM to a plain
/// space, which NFKC leaves untouched. 289 of the 5,275 corpus lines are
/// changed by it, so it is emphatically not a no-op.
///
/// **This is a port, not a design.** It follows HuggingFace's `spm_precompiled`
/// exactly, including the parts that look wrong, because matching the reference
/// bit-for-bit is the entire requirement. The grapheme-then-char fallback in
/// [normalize] is the clearest example: it is strange, and it is what the
/// reference does.
///
/// The blob's format, which is not documented anywhere but the source:
///
/// ```
/// [u32 little-endian: trie byte length][trie: u32 units][normalized: bytes]
/// ```
///
/// The trie is a darts-clone double array whose values are byte offsets into
/// the trailing blob, where each replacement is a NUL-terminated UTF-8 string.
class PrecompiledNormalizer {
  PrecompiledNormalizer._(this._trie, this._normalized);

  /// Parse the base64 `precompiled_charsmap` straight out of `tokenizer.json`.
  factory PrecompiledNormalizer.fromBase64(String charsmap) =>
      PrecompiledNormalizer.fromBytes(base64.decode(charsmap));

  factory PrecompiledNormalizer.fromBytes(Uint8List blob) {
    if (blob.length < 4) {
      throw const FormatException('precompiled_charsmap is too short');
    }
    final view = ByteData.sublistView(blob);
    final trieBytes = view.getUint32(0, Endian.little);
    if (trieBytes + 4 > blob.length) {
      throw const FormatException('precompiled_charsmap trie overruns the blob');
    }

    // The units are u32 little-endian. Copied into a Uint32List rather than
    // read through a ByteData on every lookup: the traversal below indexes this
    // array once per input byte, and it is the hot path of every query.
    final units = Uint32List(trieBytes ~/ 4);
    for (var i = 0; i < units.length; i++) {
      units[i] = view.getUint32(4 + i * 4, Endian.little);
    }

    return PrecompiledNormalizer._(
      units,
      Uint8List.sublistView(blob, 4 + trieBytes),
    );
  }

  final Uint32List _trie;

  /// Replacement strings, NUL-separated. Kept as bytes and decoded on demand:
  /// decoding the whole blob up front would build a ~200KB string that is
  /// almost entirely never read.
  final Uint8List _normalized;

  /// Cache keyed by the input chunk. The same handful of characters recur
  /// constantly within one message and across messages, and a hit skips both
  /// the trie walk and the UTF-8 round trip.
  final Map<String, String?> _cache = {};

  /// Normalize [input] the way the Python tokenizer did before embedding.
  ///
  /// The two-level walk is the reference's, verbatim: try to rewrite a whole
  /// grapheme cluster first (but only when it is under 6 bytes), and otherwise
  /// fall back to rewriting each character in it individually. Combining marks
  /// are why the first level exists — `e` + U+0301 is one grapheme with its own
  /// rewrite rule that neither character has alone.
  String normalize(String input) {
    if (input.isEmpty) return input;

    final out = StringBuffer();
    for (final grapheme in input.characters) {
      // `< 6` counts UTF-8 bytes, not characters — a bound from the reference,
      // where it guards a fixed stack buffer. It is load-bearing: it decides
      // which graphemes get the whole-cluster rule at all.
      if (_utf8Length(grapheme) < 6) {
        final whole = _transform(grapheme);
        if (whole != null) {
          out.write(whole);
          continue;
        }
      }
      for (final rune in grapheme.runes) {
        final single = String.fromCharCode(rune);
        out.write(_transform(single) ?? single);
      }
    }
    return out.toString();
  }

  /// The rewrite for [chunk], or null when the trie has no rule for it.
  String? _transform(String chunk) {
    final cached = _cache[chunk];
    if (cached != null || _cache.containsKey(chunk)) return cached;
    final result = _lookup(chunk);
    _cache[chunk] = result;
    return result;
  }

  String? _lookup(String chunk) {
    final key = utf8.encode(chunk);
    final offset = _firstCommonPrefix(key);
    if (offset < 0) return null;

    // The replacement runs to the next NUL. An empty result is legitimate and
    // means "delete this" — a soft hyphen, for instance.
    var end = offset;
    while (end < _normalized.length && _normalized[end] != 0) {
      end++;
    }
    return utf8.decode(
      Uint8List.sublistView(_normalized, offset, end),
      allowMalformed: true,
    );
  }

  /// darts-clone common-prefix search, returning the **first** hit only.
  ///
  /// The reference collects every prefix match and then takes `results[0]` —
  /// the shortest — so the rest are never looked at. Returning early is the
  /// same answer without the allocation.
  ///
  /// Returns -1 for no match.
  int _firstCommonPrefix(List<int> key) {
    if (_trie.isEmpty) return -1;

    var nodePos = 0;
    var unit = _trie[nodePos];
    nodePos ^= _offset(unit);

    for (final byte in key) {
      // A NUL byte terminates the key in the reference's C heritage. UTF-8 from
      // a Dart string cannot contain one, but the check is free and keeps this
      // a faithful port.
      if (byte == 0) break;

      nodePos ^= byte;
      // A well-formed charsmap never indexes past its own array. A corrupt
      // download could, and a RangeError inside a keystroke handler is a worse
      // outcome than an unnormalized character.
      if (nodePos < 0 || nodePos >= _trie.length) return -1;
      unit = _trie[nodePos];
      if (_label(unit) != byte) return -1;

      nodePos ^= _offset(unit);
      if (_hasLeaf(unit)) {
        if (nodePos < 0 || nodePos >= _trie.length) return -1;
        return _value(_trie[nodePos]);
      }
    }
    return -1;
  }

  // The darts-clone unit encoding. Four bit-twiddles that are meaningless in
  // isolation and are simply the format.
  static bool _hasLeaf(int unit) => ((unit >> 8) & 1) == 1;
  static int _value(int unit) => unit & 0x7FFFFFFF;
  static int _label(int unit) => unit & (0x80000000 | 0xFF);
  static int _offset(int unit) => (unit >> 10) << ((unit & 0x200) >> 6);

  /// UTF-8 byte length without building the encoded list.
  static int _utf8Length(String s) {
    var total = 0;
    for (final rune in s.runes) {
      if (rune < 0x80) {
        total += 1;
      } else if (rune < 0x800) {
        total += 2;
      } else if (rune < 0x10000) {
        total += 3;
      } else {
        total += 4;
      }
    }
    return total;
  }
}
