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
import '../../outcomes/presentation/reply_note.dart';
import '../../voice_notes/application/voice_note_cache.dart';
import '../../voice_notes/application/voice_note_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/missed_alarm_service.dart';
import '../application/reminder_policy.dart';
import '../../scheduling/domain/schedule_item.dart';

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

  /// A missed voice note's Play is fetching/starting the note (R2,
  /// 2026-10-02). Set on the FIRST tap, before any await, so repeated taps
  /// cannot start a second fetch, play or "heard" write.
  bool _preparingVoice = false;

  /// Reviews whose note was just sent (R6). The review holds an item
  /// snapshot, so the button is hidden here rather than waiting for a resync.
  final _noteSent = <String>{};

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

  /// A missed VOICE note (2026-09-28): Play and Already heard both close it
  /// as heard late (Done under the hood, "Heard (Late)" on screen) and tell
  /// the planner "{Y} heard your voice note late." Play also plays it; if the
  /// note cannot be loaded, nothing is recorded and the popup stays.
  Future<void> _actVoice(
    MissedAlarmService service,
    MissedAlarmReview review, {
    required bool play,
  }) async {
    if (_acting || _preparingVoice) return;
    if (play) {
      setState(() => _preparingVoice = true);
      try {
        final path = await ref.read(voiceNoteCacheProvider).ensure(review.item);
        await ref.read(voicePlayerProvider).play(path);
      } catch (_) {
        if (mounted) {
          setState(() => _preparingVoice = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Couldn't load the voice note. Try again."),
            ),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _preparingVoice = false;
      _acting = true;
      _answering = review;
    });
    try {
      await atLeast(service.markDone(review));
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
        final selfPlanned =
            review != null && review.item.createdByUid == review.item.targetUid;
        final plannerProfile = review == null || selfPlanned
            ? null
            : ref.watch(profileByUidProvider(review.item.createdByUid));
        final plannerName = plannerProfile?.value?.name;
        // R3 (2026-10-02): the popup names the planner, so it waits for the
        // profile while it is still loading (normally cached already). A
        // failed or missing profile still shows, with "Someone".
        final nameLoading =
            plannerProfile != null &&
            plannerProfile.isLoading &&
            plannerName == null;
        final updatingLabel = review == null
            ? ''
            : updatingPlannerLabel(
                selfPlanned: selfPlanned,
                plannerName: plannerName,
              );
        final voice = review?.item.isVoiceAlarm ?? false;
        final visible =
            widget.enabled && !lock.isLocked && review != null && !nameLoading;
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
                                    voice
                                        ? 'Missed voice note'
                                        : 'Missed alarm',
                                    style: context.text.titleLarge,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: Space.sm),
                                  // The "permanently recorded" line was
                                  // removed on request (2026-09-25).
                                  Text(
                                    missedPopupMessage(
                                      review.item,
                                      plannerName: plannerName,
                                    ),
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
                                  else if (voice)
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            key: const ValueKey(
                                              'missed-voice-already-heard',
                                            ),
                                            onPressed: _preparingVoice
                                                ? null
                                                : () => unawaited(
                                                    _actVoice(
                                                      service,
                                                      review,
                                                      play: false,
                                                    ),
                                                  ),
                                            child: const Text('Already heard'),
                                          ),
                                        ),
                                        const SizedBox(width: Space.sm),
                                        Expanded(
                                          child: FilledButton.icon(
                                            key: const ValueKey(
                                              'missed-voice-play',
                                            ),
                                            onPressed: _preparingVoice
                                                ? null
                                                : () => unawaited(
                                                    _actVoice(
                                                      service,
                                                      review,
                                                      play: true,
                                                    ),
                                                  ),
                                            icon: const Icon(
                                              AppIcons.voiceNotePlay,
                                            ),
                                            label: Text(
                                              _preparingVoice
                                                  ? 'Loading…'
                                                  : 'Play',
                                            ),
                                          ),
                                        ),
                                      ],
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
                                  // R6: the optional note, with the
                                  // answers. Answering directly sends none.
                                  if (!_acting &&
                                      review.item.canSendReply &&
                                      !_noteSent.contains(review.event.key))
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: Space.sm,
                                      ),
                                      child: Center(
                                        child: SendNoteButton(
                                          item: review.item,
                                          enabled: !_preparingVoice,
                                          onSent: () => setState(
                                            () =>
                                                _noteSent.add(review.event.key),
                                          ),
                                        ),
                                      ),
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

/// The missed popup's message (R3, 2026-10-02): always says who planned it.
/// A voice note keeps its question; a Default Alarm leads with the one alarm
/// sentence ([alarmHeadline]) so the planner's name is there too.
String missedPopupMessage(ScheduleItem item, {String? plannerName}) {
  if (item.isVoiceAlarm) {
    final name = plannerName?.trim();
    final who = name == null || name.isEmpty ? 'Someone' : name;
    return '$who sent you a voice note. Listen now?';
  }
  return '${alarmHeadline(item, plannerName: plannerName)}. '
      'It rang for 25 minutes with no response.';
}
