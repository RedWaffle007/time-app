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
    final governed = _governedFiles();

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

  /// UI-RULES.md §2.7 — the filled-vs-line firewall.
  ///
  /// A filled shape is STATE; line work and text are STRUCTURE. "An orange
  /// filled pill or panel means something is waiting on me" is the one colour
  /// signal a user learns to trust, and it only stays true if nothing else
  /// fills with orange.
  ///
  /// The rule falls straight out of the role names: a `*Container` role IS a
  /// fill — that is what the M3 slot means — so the two container roles may only
  /// appear in the two widgets that own state. `attention` itself is the
  /// line-and-text role and is free everywhere: section rules, icons, counts.
  ///
  /// If you need a new orange fill, you have a new STATE. Add it to
  /// `status_style.dart` rather than inlining it at a call site.
  test('orange fills only exist inside the two state widgets (§2.7)', () {
    const owners = <String>{
      'lib/core/theme/status_style.dart',
      'lib/core/widgets/warning_panel.dart',
    };
    // `tertiary*` is the Material alias for the same two roles (§2.2) — banning
    // one spelling and not the other would be a firewall with a door in it.
    final fillRole = RegExp(
      r'\b(attentionContainer|attentionContainerStrong'
      r'|tertiaryContainer|onTertiaryContainer)\b',
    );

    final violations = <String>[];
    for (final file in _governedFiles()) {
      final relative = file.path.replaceAll(r'\', '/');
      if (owners.contains(relative)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (fillRole.hasMatch(code)) {
          violations.add(
            '$relative:${i + 1}  orange fill outside a state widget — '
            'use `context.attention` for line work, or add the state to '
            'status_style.dart\n    ${lines[i].trim()}',
          );
        }
      }
    }
    expect(violations, isEmpty,
        reason: 'UI-RULES.md §2.7 violations:\n\n${violations.join('\n')}\n');
  });

  test('the migration backlog is empty', () {
    expect(
      pendingMigration,
      isEmpty,
      reason: 'still unmigrated: ${pendingMigration.join(', ')}',
    );
  });
}

/// Everything that renders UI. `lib/core/theme` is exempt from §1: it is where
/// the raw values are DEFINED. It is NOT exempt from §2.7 — `status_style.dart`
/// is listed there by name, so a new file added to that directory is still
/// governed by the firewall.
List<File> _governedFiles() {
  final files = <FileSystemEntity>[
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

  expect(files, isNotEmpty, reason: 'lint found no files to check');
  return files;
}

class _Rule {
  const _Rule({required this.name, required this.pattern, required this.fix});
  final String name;
  final RegExp pattern;
  final String fix;
}
