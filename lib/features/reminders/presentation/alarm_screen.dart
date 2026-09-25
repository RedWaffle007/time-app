import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../plan/application/plan_intent.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../auth/domain/user_profile.dart';
import '../application/alarm_timeline_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/reminder_policy.dart';
import '../application/reminder_providers.dart';
import '../data/alarm_lifecycle_store.dart';

/// The full-screen alarm surface a reminder lands on.
///
/// **Why it exists.** The reminder's notification is a full-screen intent: while
/// the screen is locked or off, Android launches the app straight onto this
/// screen; while the app is running, a tap on the heads-up brings it here. Both
/// arrive through the ONE tap route (`NotificationRouter.openItem`), which points
/// at `Routes.alarm` — a single place that decides where a reminder goes.
///
/// **The sound lives in a native service, not here.** On mount this screen
/// claims `AlarmSoundService` (a foreground service holding a wake lock) and
/// cancels the fired notification so its one-shot fallback tone does not double
/// up. The service is what keeps ringing with the screen off; every way off this
/// screen stops it. The notification's own tone still covers the case where
/// native delivery is delayed.
///
/// It is deliberately thin: it shows what is due and hands off to My Schedule,
/// where Done and Skip already live. It never marks an outcome itself.
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.itemId});

  /// The due item's id — the whole payload a reminder carries.
  final String itemId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  bool _dismissing = false;
  AlarmKeyEvents? _keyEvents;

  /// The sentence the native alarm was delivered with. Shown until the live
  /// item + planner name resolve, so the first frames never show a placeholder
  /// ("Reminder" / "Planner") that then changes — a device-reported flash.
  String? _deliveredHeadline;

  @override
  void initState() {
    super.initState();
    // Claim the wake-lock-backed tone FIRST, then cancel the redundant silent
    // scheduled notification. Deferred a frame: `ref` must not be used during
    // initState's synchronous build, and a platform call has no place there.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final keyEvents = ref.read(alarmKeyEventsProvider);
      _keyEvents = keyEvents;
      keyEvents.listen(_leave);
      final sound = ref.read(alarmSoundProvider);
      final delivered = await sound.headline(widget.itemId);
      if (!mounted) return;
      if (delivered != null && delivered.trim().isNotEmpty) {
        setState(() => _deliveredHeadline = delivered.trim());
      }
      // The UI ownership claim must reach the native service before cancelling
      // the scheduled notification releases its native-delivery owner. These
      // used to race as two unawaited platform calls, briefly stopping and
      // restarting playback on an unlocked/full-screen launch.
      // The UI-fallback start carries the sentence too, for the heads-up of an
      // alarm whose native delivery did not run first.
      await sound.start(widget.itemId, headline: _headlineNow() ?? '');
      if (!mounted) return;
      final uid = ref.read(currentUidProvider);
      if (uid != null) {
        unawaited(
          ref
              .read(alarmTimelineServiceProvider)
              .recordRangFallback(uid, widget.itemId),
        );
      }
      // `dismiss` here means "cancel the OS notification for this item" — it
      // removes the redundant scheduled surface now that the foreground
      // service owns sound and its actionable notification. It does not
      // navigate; that is `_leave`.
      await ref.read(reminderServiceProvider).dismiss(widget.itemId);
    });
  }

  @override
  void dispose() {
    _keyEvents?.listen(null);
    super.dispose();
  }

  /// The best sentence available right now, or null when nothing trustworthy
  /// is known yet (render nothing rather than a placeholder).
  String? _headlineNow() {
    final item = ref
        .read(allItemsAsTargetProvider)
        .maybeWhen(data: _find, orElse: () => null);
    if (item == null) return _deliveredHeadline;
    final planner = ref.read(profileByUidProvider(item.createdByUid));
    return _resolveHeadline(item, planner);
  }

  String? _resolveHeadline(
    ScheduleItem item,
    AsyncValue<UserProfile?> planner,
  ) {
    final isSelf = item.createdByUid == item.targetUid;
    // The live sentence wins once the planner's name is settled (or not
    // needed); until then the delivered one is already correct.
    if (isSelf || planner.hasValue) {
      return alarmHeadline(item, plannerName: planner.value?.name);
    }
    return _deliveredHeadline;
  }

  ScheduleItem? _find(List<ScheduleItem> items) {
    for (final item in items) {
      if (item.id == widget.itemId) return item;
    }
    return null;
  }

  /// Stop the alarm, then land on My Schedule with this item singled out — the
  /// existing deep link, where Done/Skip are. Guarded so a double tap (or a Back
  /// racing the button) cannot fire two navigations.
  Future<void> _leave() async {
    if (_dismissing) return;
    _dismissing = true;
    await ref.read(alarmSoundProvider).stop(widget.itemId);
    final uid = ref.read(currentUidProvider);
    if (uid != null) {
      // Navigation must not wait on Firestore: Dismiss has to work offline.
      unawaited(
        ref
            .read(alarmTimelineServiceProvider)
            .recordDismissed(uid, widget.itemId),
      );
    }
    if (!mounted) return;
    if (widget.itemId.isNotEmpty) {
      // Set the highlight intent BEFORE navigating — the deterministic signal
      // the Plan shell listens to (query params were unreliable on the cached
      // branch page).
      ref.read(planIntentProvider.notifier).highlightItem(widget.itemId);
    }
    context.go(Routes.plan);
  }

  @override
  Widget build(BuildContext context) {
    // The item comes from the same record stream the reminder was armed off, so
    // on a cold full-screen launch it may still be loading — the alarm is real
    // regardless, so this renders and rings with a generic title until the
    // stream resolves rather than blocking on it.
    final item = ref
        .watch(allItemsAsTargetProvider)
        .maybeWhen(data: _find, orElse: () => null);
    final headline = item == null
        ? _deliveredHeadline
        : _resolveHeadline(
            item,
            ref.watch(profileByUidProvider(item.createdByUid)),
          );

    // Back / gesture-dismiss must also stop the tone, never leave it ringing.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: Space.screenForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Icon(
                  AppIcons.reminders,
                  size: Sizes.emptyStateIcon,
                  color: context.attention,
                ),
                const SizedBox(height: Space.xl),
                // ONE sentence, centered and bold: "{planner} planned {task} for
                // you" (device-directed copy, 2026-09-25). Nothing — not a
                // placeholder — until a trustworthy sentence is known.
                Text(
                  headline ?? '',
                  key: const ValueKey('alarm-headline'),
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (item != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    formatInstant(
                      context,
                      item.scheduledInstantUtc,
                      item.timezone,
                    ),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (item?.note != null && item!.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    item.note!.trim(),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium,
                  ),
                ],
                const Spacer(),
                FilledButton(
                  onPressed: _leave,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.sm),
                    child: Text('Dismiss'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
