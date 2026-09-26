import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';

/// The clash warning (Batch G1): shown only when a person already has a live
/// plan at the exact minute being planned. Privacy-minimal — it names people
/// and the time, never a title, note or status. Informational only: dismissing
/// it leaves the form and its Send action intact.
///
/// [timeLabel] is already localized by the caller (the one format helper).
Future<void> showClashWarningDialog(
  BuildContext context, {
  required List<String> names,
  required String timeLabel,
}) {
  assert(names.isNotEmpty);
  final sorted = [...names]..sort();
  final message = sorted.length == 1
      ? '${sorted.single} already has a plan at $timeLabel. '
            'You can still send.'
      : 'Already busy at this time ($timeLabel): ${sorted.join(', ')}. '
            'You can still send.';
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(AppIcons.warning),
      title: const Text('Schedule heads-up'),
      content: Text(message, style: context.text.bodyMedium),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
