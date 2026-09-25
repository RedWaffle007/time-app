import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/outcome_feedback.dart';

/// Shows "Updating {planner}…" while [work] saves an outcome, for no less than
/// [kPlannerUpdateDuration], then closes and returns [work]'s result.
///
/// A dialog, not a label on the card: the card leaves My Schedule the instant
/// the outcome lands, which would cut the message short. Not dismissible — it
/// is a pause with a stated reason, not a choice.
Future<T> showUpdatingPlanner<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function() work,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        PopScope(canPop: false, child: _UpdatingPlannerDialog(label: label)),
  );
  navigator.push(route);
  try {
    return await atLeast(work());
  } finally {
    if (route.isActive) navigator.removeRoute(route);
  }
}

class _UpdatingPlannerDialog extends StatelessWidget {
  const _UpdatingPlannerDialog({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('updating-planner'),
    content: Row(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(width: Space.lg),
        Expanded(child: Text(label, style: context.text.titleMedium)),
      ],
    ),
  );
}
