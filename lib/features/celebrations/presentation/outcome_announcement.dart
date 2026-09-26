import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../domain/completion_celebration.dart';

/// Only the PLANNER gets the pop-up, and only for someone else's item. The
/// target already saw "Updating {planner}…" (and confetti on Done).
bool showsPlannerAnnouncement(CompletionCelebration event, String? uid) =>
    uid != null && uid == event.plannerUid && event.targetUid != uid;

/// The pop-up's words (2026-09-26, user-directed). Done is celebratory; a
/// Skip keeps the same body shape with a plain heading and no confetti.
({String heading, String body, String action}) outcomeAnnouncementCopy({
  required CelebrationResult result,
  String? targetName,
  String? taskTitle,
}) {
  final who = (targetName ?? '').trim().isEmpty
      ? 'Someone'
      : targetName!.trim();
  final task = (taskTitle ?? '').trim().isEmpty
      ? 'your plan'
      : taskTitle!.trim();
  return switch (result) {
    CelebrationResult.done => (
      heading: 'Your planning skills are amazing!',
      body: '$who completed task: $task',
      action: 'Nice',
    ),
    CelebrationResult.skipped => (
      heading: 'Plan skipped',
      body: '$who skipped task: $task',
      action: 'OK',
    ),
  };
}

/// The planner's in-app outcome pop-up, drawn by [CompletionCelebrationHost]
/// above the app (it sits above the Navigator, so it is a dialog-styled
/// widget in the host's Stack, not a pushed route).
class OutcomeAnnouncementCard extends ConsumerWidget {
  const OutcomeAnnouncementCard({
    super.key,
    required this.event,
    required this.onDismiss,
  });

  static const cardKey = ValueKey('outcome-announcement');

  final CompletionCelebration event;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(profileByUidProvider(event.targetUid)).value?.name;
    final items = ref.watch(allItemsAsPlannerProvider).value ?? const [];
    String? title;
    for (final item in items) {
      if (item.id == event.itemId && item.targetUid == event.targetUid) {
        title = item.title;
        break;
      }
    }
    final copy = outcomeAnnouncementCopy(
      result: event.result,
      targetName: name,
      taskTitle: title,
    );
    final scrim = Theme.of(context).colorScheme.scrim.withValues(alpha: 0.5);

    return Stack(
      key: cardKey,
      children: [
        Positioned.fill(
          child: ModalBarrier(color: scrim, onDismiss: onDismiss),
        ),
        Center(
          child: Semantics(
            liveRegion: true,
            child: AlertDialog(
              title: Text(copy.heading),
              content: Text(copy.body),
              actions: [
                FilledButton(onPressed: onDismiss, child: Text(copy.action)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
