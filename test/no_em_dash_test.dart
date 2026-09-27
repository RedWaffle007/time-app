import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Batch H4 (2026-09-27, user-directed): **no em dashes in any in-app text.**
///
/// Scans every STRING LITERAL the app can show or send: Dart under `lib/`, the
/// Worker's push copy under `worker/src/`, and the native Kotlin. Code
/// comments are out of scope (they are not app text), so the scanner skips
/// them. Log messages are held to the same rule: it keeps this check strict
/// and simple, with no allow-list to rot.
void main() {
  const dash = '—';

  test('no em dash in any Dart string literal under lib/', () {
    final hits = <String>[];
    for (final file in _files('lib', '.dart')) {
      final source = file.readAsStringSync();
      for (final (line, text) in _dartStringLiterals(source)) {
        if (text.contains(dash)) hits.add('${file.path}:$line  $text');
      }
    }
    expect(hits, isEmpty, reason: 'Rewrite with a comma, colon or period.');
  });

  test('no em dash in Worker push copy or native Kotlin strings', () {
    final hits = <String>[];
    for (final file in [
      ..._files('worker/src', '.js'),
      ..._files('android/app/src/main/kotlin', '.kt'),
    ]) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = _stripLineComment(lines[i]);
        if (code.contains(dash)) hits.add('${file.path}:${i + 1}');
      }
    }
    expect(hits, isEmpty);
  });

  test('the scanner itself finds literals and skips comments', () {
    const sample =
        "// a comment — fine\n"
        "final a = 'plain';\n"
        "/* block — fine */\n"
        "final b = 'bad — dash';\n"
        "final c = '''multi\n— line''';\n"
        "final d = r'raw \\—';\n";
    final found = _dartStringLiterals(
      sample,
    ).where((l) => l.$2.contains(dash)).map((l) => l.$1).toList();
    expect(found, [4, 5, 7]); // the triple-quoted literal spans 5–6
  });
}

Iterable<File> _files(String root, String extension) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(extension));

/// Drops a trailing `//` comment and whole comment lines (`*`, `/*`).
String _stripLineComment(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//') ||
      trimmed.startsWith('*') ||
      trimmed.startsWith('/*')) {
    return '';
  }
  final at = line.indexOf(' // ');
  return at < 0 ? line : line.substring(0, at);
}

/// (line, contents) for every string literal in [src], skipping comments.
/// Handles '…', "…", triple-quoted and raw strings; escapes are skipped in
/// non-raw strings. Interpolated text stays part of the literal, which is the
/// safe direction for this check.
List<(int, String)> _dartStringLiterals(String src) {
  final out = <(int, String)>[];
  var i = 0;
  int lineAt(int index) => '\n'.allMatches(src.substring(0, index)).length + 1;
  while (i < src.length) {
    if (src.startsWith('//', i)) {
      final end = src.indexOf('\n', i);
      i = end < 0 ? src.length : end;
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    final c = src[i];
    if (c == "'" || c == '"') {
      final raw = i > 0 && src[i - 1] == 'r';
      final triple = src.startsWith(c * 3, i);
      final quote = triple ? c * 3 : c;
      final start = i + quote.length;
      var j = start;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += (!raw && src[j] == r'\') ? 2 : 1;
      }
      out.add((lineAt(i), src.substring(start, j.clamp(start, src.length))));
      i = j + quote.length;
      continue;
    }
    i++;
  }
  return out;
}
