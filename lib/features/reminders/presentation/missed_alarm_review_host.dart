import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../applock/application/app_lock_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/missed_alarm_service.dart';

/// App-wide review surface for alarms that exhausted the one-minute ring cap.
class MissedAlarmReviewHost extends ConsumerWidget {
  const MissedAlarmReviewHost({
    super.key,
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(missedAlarmServiceProvider);
    final lock = ref.watch(appLockControllerProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([service, lock]),
      builder: (context, _) {
        final reviews = service.reviews;
        final visible = enabled && !lock.isLocked && reviews.isNotEmpty;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              excluding: visible,
              child: IgnorePointer(ignoring: visible, child: child),
            ),
            if (visible)
              Positioned.fill(
                child: ColoredBox(
                  color: context.colors.scrim.withValues(alpha: 0.55),
                  child: SafeArea(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: Sizes.modalMaxWidth,
                          maxHeight:
                              MediaQuery.sizeOf(context).height *
                              Sizes.modalMaxHeightFraction,
                        ),
                        child: Card(
                          margin: Space.screenForm,
                          child: Padding(
                            padding: Space.cardPadding,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Icon(
                                  AppIcons.skipped,
                                  size: Sizes.emptyStateIcon,
                                ),
                                const SizedBox(height: Space.md),
                                Text(
                                  reviews.length == 1
                                      ? 'Missed alarm'
                                      : '${reviews.length} missed alarms',
                                  style: context.text.titleLarge,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: Space.sm),
                                Text(
                                  'These alarms rang for one minute and were '
                                  'marked Skipped: $kMissedAlarmSkipReason.',
                                  style: context.text.bodyMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: Space.lg),
                                Flexible(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      children: [
                                        for (final review in reviews)
                                          ListTile(
                                            contentPadding: EdgeInsets.zero,
                                            leading: const Icon(
                                              AppIcons.reminders,
                                            ),
                                            title: Text(review.item.title),
                                            subtitle: Text(
                                              formatInstant(
                                                context,
                                                review.event.occurredAtUtc,
                                                review.item.timezone,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: Space.lg),
                                FilledButton(
                                  onPressed: () =>
                                      unawaited(service.markAllReviewed()),
                                  child: const Text('Mark reviewed'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
