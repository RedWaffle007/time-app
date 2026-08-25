import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../routing/app_router.dart';
import '../../plan/application/plan_intent.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/reminder_providers.dart';

/// The full-screen alarm surface a reminder lands on.
///
/// **Why it exists.** The reminder's notification is a full-screen intent: while
/// the screen is locked or off, Android launches the app straight onto this
/// screen; while the app is running, a tap on the heads-up brings it here. Both
/// arrive through the ONE tap route (`NotificationRouter.openItem`), which points
/// at `Routes.alarm` — a single place that decides where a reminder goes.
///
/// **The sound lives in a native service, not here.** On mount this screen
/// starts `AlarmSoundService` (a foreground service holding a wake lock) and
/// cancels the fired notification so its insistent tone does not double up. The
/// service is what keeps ringing with the screen off; every way off this screen
/// stops it. The notification's own tone still covers the foreground-app case,
/// where this screen never opens.
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

  @override
  void initState() {
    super.initState();
    // Start the wake-lock-backed tone FIRST so there is no gap, then cancel the
    // notification's insistent tone so the two do not overlap for more than an
    // instant. Deferred a frame: `ref` must not be used during initState's
    // synchronous build, and a platform call has no place there either.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(alarmSoundProvider).start();
      // `dismiss` here means "cancel the OS notification for this item" — it
      // stops the insistent notification tone now that the service owns the
      // sound. It does not navigate; that is `_leave`.
      ref.read(reminderServiceProvider).dismiss(widget.itemId);
    });
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
    await ref.read(alarmSoundProvider).stop();
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
    final item = ref.watch(allItemsAsTargetProvider).maybeWhen(
          data: _find,
          orElse: () => null,
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
                Icon(AppIcons.reminders,
                    size: Sizes.emptyStateIcon, color: context.attention),
                const SizedBox(height: Space.xl),
                Text(
                  item?.title ?? 'Reminder',
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall,
                ),
                if (item != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    formatInstant(
                        context, item.scheduledInstantUtc, item.timezone),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium
                        ?.copyWith(color: context.colors.onSurfaceVariant),
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
