import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/status_style.dart';
import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/missed_alarms.dart';

/// **🔔 Missed** (2026-10-05, UI-RULES §6.16a): at the far right of the Plan
/// header, always there, so the Missed pop-up can be reopened at will. The
/// number of alarms waiting for an answer rides on it; with none, a tap says
/// so instead of opening an empty pop-up.
class MissedButton extends ConsumerWidget {
  const MissedButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(missedAlarmServiceProvider);
    final uid = ref.watch(currentUidProvider);
    final items = ref.watch(allItemsAsTargetProvider).value ?? const [];
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final count = missedAlarms(
          items: items,
          uid: uid,
          nowUtc: DateTime.now().toUtc(),
          timedOutIds: {for (final r in service.reviews) r.item.id},
        ).count;
        return TextButton.icon(
          key: const ValueKey('missed-button'),
          onPressed: () {
            if (count == 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nothing missed')),
              );
              return;
            }
            ref.read(missedPopupTriggerProvider.notifier).open();
          },
          icon: PendingCountBadge(
            count: count,
            child: const Icon(AppIcons.missed),
          ),
          label: Text('Missed', style: context.text.labelLarge),
        );
      },
    );
  }
}
