import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Mechanical enforcement of UI-RULES.md §1.
///
/// A rule that lives only in a document is not a rule — this is the same lesson
/// as the Firestore-rules incident. The design system is enforced by scanning
/// the source, not by remembering to conform.
///
/// (An analyzer lint would need the `custom_lint` package to ban identifiers;
/// this needs no new dependency and runs under `flutter test`.)
void main() {
  /// Files still awaiting migration. **This list only ever shrinks.** Deleting
  /// the last entry deletes the concept — do not add to it.
  const pendingMigration = <String>{};

  final banned = <_Rule>[
    _Rule(
      name: 'raw Material colours',
      pattern: RegExp(r'\bColors\.[a-zA-Z]'),
      fix: 'use a colorScheme role or context.attention',
    ),
    _Rule(
      name: 'hardcoded Color literal',
      pattern: RegExp(r'\bColor\(0x'),
      fix: 'add the value to app_colors.dart',
    ),
    _Rule(
      name: 'inline font size',
      pattern: RegExp(r'\bfontSize\s*:'),
      fix: 'use a textTheme token',
    ),
    _Rule(
      name: 'literal spacing in EdgeInsets',
      pattern: RegExp(r'EdgeInsets\.\w+\((?:[^)]*?[:(]\s*)?\d'),
      fix: 'use Space.*',
    ),
    _Rule(
      name: 'literal SizedBox gap',
      pattern: RegExp(r'SizedBox\(\s*(?:height|width)\s*:\s*\d'),
      fix: 'use Space.*',
    ),
    _Rule(
      name: 'literal border radius',
      pattern: RegExp(r'BorderRadius\.circular\(\s*\d'),
      fix: 'use Radii.*',
    ),
    _Rule(
      name: 'literal elevation',
      pattern: RegExp(r'\belevation\s*:\s*\d'),
      fix: 'use Elevations.* — and see §5, flat by default',
    ),
    _Rule(
      name: 'emoji used as status',
      pattern: RegExp(r'[\u{2705}\u{23ED}\u{274C}\u{26A0}\u{1F7E0}\u{1F7E2}]',
          unicode: true),
      fix: 'use an Icon from status_style.dart',
    ),
  ];

  test('screens use design tokens, never raw values (UI-RULES.md §1)', () {
    final governed = <FileSystemEntity>[
      // Everything that renders UI. `lib/core/theme` is exempt: it is where the
      // raw values are DEFINED.
      File('lib/app.dart'),
      ...[
        Directory('lib/features'),
        Directory('lib/core/widgets'),
        Directory('lib/dev'),
      ].expand((d) => d.existsSync() ? d.listSync(recursive: true) : const []),
    ]
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    expect(governed, isNotEmpty, reason: 'lint found no files to check');

    final violations = <String>[];
    for (final file in governed) {
      final relative = file.path.replaceAll(r'\', '/');
      if (pendingMigration.contains(relative)) continue;

      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Comments explain the rules; they don't violate them.
        final code = line.split('//').first;
        for (final rule in banned) {
          if (rule.pattern.hasMatch(code)) {
            violations.add(
              '$relative:${i + 1}  ${rule.name} — ${rule.fix}\n'
              '    ${line.trim()}',
            );
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'UI-RULES.md §1 violations:\n\n${violations.join('\n')}\n',
    );
  });

  test('the migration backlog is empty', () {
    expect(
      pendingMigration,
      isEmpty,
      reason: 'still unmigrated: ${pendingMigration.join(', ')}',
    );
  });
}

class _Rule {
  const _Rule({required this.name, required this.pattern, required this.fix});
  final String name;
  final RegExp pattern;
  final String fix;
}
