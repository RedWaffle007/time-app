import 'package:flutter/material.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/conflict_disclosure.dart';

/// One informational, privacy-minimal warning. It never returns a save decision:
/// acknowledging or dismissing it leaves the form and its save action intact.
Future<void> showConflictWarningDialog(
  BuildContext context, {
  required List<ConflictDisclosureGroup> groups,
  Map<String, String> readErrors = const {},
}) {
  assert(groups.isNotEmpty || readErrors.isNotEmpty);
  final sortedErrorNames = readErrors.values.toSet().toList()..sort();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(AppIcons.warning),
      title: const Text('Schedule heads-up'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (groups.isNotEmpty) ...[
              Text(
                'Plans already exist at these times. You can still save.',
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: Space.md),
              for (final group in groups) ...[
                Text(group.name, style: context.text.titleSmall),
                const SizedBox(height: Space.xs),
                for (final instant in group.instantsUtc)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Text(
                      '${formatInstant(context, instant, group.timezone)} '
                      '(${group.timezone})',
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: Space.sm),
              ],
            ],
            if (readErrors.isNotEmpty) ...[
              if (groups.isNotEmpty) const Divider(),
              Text(
                'Could not check:',
                style: context.text.titleSmall?.copyWith(
                  color: context.colors.error,
                ),
              ),
              const SizedBox(height: Space.xs),
              for (final name in sortedErrorNames)
                Text(
                  name,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.error,
                  ),
                ),
              const SizedBox(height: Space.sm),
              Text(
                'The schedule may have changed. You can still save.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
