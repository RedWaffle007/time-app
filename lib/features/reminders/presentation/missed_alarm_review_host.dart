import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../applock/application/app_lock_providers.dart';
import '../../celebrations/application/celebration_providers.dart';
import '../../celebrations/domain/completion_celebration.dart';
import '../../auth/application/auth_providers.dart';
import '../../outcomes/application/outcome_feedback.dart';
import '../application/missed_alarm_providers.dart';
import '../application/missed_alarm_service.dart';

/// App-wide review surface for alarms that exhausted the one-minute ring cap.
class MissedAlarmReviewHost extends ConsumerStatefulWidget {
  const MissedAlarmReviewHost({
    super.key,
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  ConsumerState<MissedAlarmReviewHost> createState() =>
      _MissedAlarmReviewHostState();
}

class _MissedAlarmReviewHostState extends ConsumerState<MissedAlarmReviewHost> {
  bool _acting = false;

  /// The review being answered. The service drops it from its list at once,
  /// so it is held here to keep "Updating {planner}…" on screen for the full
  /// [kPlannerUpdateDuration] (directed 2026-09-25).
  MissedAlarmReview? _answering;

  Future<void> _act(
    MissedAlarmService service,
    MissedAlarmReview review, {
    required bool done,
  }) async {
    if (_acting) return;
    setState(() {
      _acting = true;
      _answering = review;
    });
    try {
      if (done) {
        final committed = await atLeast(service.markDone(review));
        if (committed) {
          ref
              .read(committedCelebrationProvider.notifier)
              .celebrate(
                CompletionCelebration.committed(
                  targetUid: review.item.targetUid,
                  itemId: review.item.id,
                  plannerUid: review.item.createdByUid,
                ),
              );
        }
      } else {
        await atLeast(service.markSkipped(review));
      }
    } catch (_) {
      unawaited(service.resync());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not finish syncing. It will retry.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _acting = false;
          _answering = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(missedAlarmServiceProvider);
    final lock = ref.watch(appLockControllerProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([service, lock]),
      builder: (context, _) {
        final reviews = service.reviews;
        final review = _answering ?? reviews.firstOrNull;
        final visible = widget.enabled && !lock.isLocked && review != null;
        final updatingLabel = review == null
            ? ''
            : updatingPlannerLabel(
                selfPlanned: review.item.createdByUid == review.item.targetUid,
                plannerName: ref
                    .watch(profileByUidProvider(review.item.createdByUid))
                    .value
                    ?.name,
              );
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              excluding: visible,
              child: IgnorePointer(ignoring: visible, child: widget.child),
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
                            child: SingleChildScrollView(
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
                                    'Missed alarm',
                                    style: context.text.titleLarge,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: Space.sm),
                                  // The "permanently recorded" line was
                                  // removed on request (2026-09-25).
                                  Text(
                                    'This alarm rang for one minute with no '
                                    'response.',
                                    style: context.text.bodyMedium,
                                    textAlign: TextAlign.center,
                                  ),
                                  if (reviews.length > 1) ...[
                                    const SizedBox(height: Space.xs),
                                    Text(
                                      '${reviews.length} missed alarms need '
                                      'review. Showing one at a time.',
                                      style: context.text.bodySmall?.copyWith(
                                        color: context.colors.onSurfaceVariant,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                  const SizedBox(height: Space.lg),
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(AppIcons.reminders),
                                    title: Text(review.item.title),
                                    subtitle: Text(
                                      formatInstant(
                                        context,
                                        review.event.occurredAtUtc,
                                        review.item.timezone,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: Space.lg),
                                  if (_acting)
                                    Text(
                                      updatingLabel,
                                      key: const ValueKey(
                                        'missed-alarm-updating',
                                      ),
                                      style: context.text.titleMedium,
                                      textAlign: TextAlign.center,
                                    )
                                  else
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: _acting
                                                ? null
                                                : () => unawaited(
                                                    _act(
                                                      service,
                                                      review,
                                                      done: false,
                                                    ),
                                                  ),
                                            child: const Text(
                                              'Mark as Skipped',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: Space.sm),
                                        Expanded(
                                          child: FilledButton(
                                            onPressed: _acting
                                                ? null
                                                : () => unawaited(
                                                    _act(
                                                      service,
                                                      review,
                                                      done: true,
                                                    ),
                                                  ),
                                            child: const Text('Mark as Done'),
                                          ),
                                        ),
                                      ],
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
              ),
          ],
        );
      },
    );
  }
}
