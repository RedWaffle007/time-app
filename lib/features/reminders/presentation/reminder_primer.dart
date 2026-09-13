import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/reminder_providers.dart';
import '../data/reminder_scheduler.dart';

/// Dismissed for this app session only.
///
/// Deliberately not persisted. The card is not an advert — it is the app saying
/// "the reminders you approved will not arrive", which stays true until the
/// permission is granted, so silencing it forever would leave a user quietly
/// unreminded with nothing on screen to explain why. A session-scoped dismissal
/// gets the card out of the way now without lying later. It also costs no new
/// stored state, which is the right price for a nag.
final _primerDismissedProvider =
    NotifierProvider<_PrimerDismissed, bool>(_PrimerDismissed.new);

class _PrimerDismissed extends Notifier<bool> {
  @override
  bool build() => false;

  void dismiss() => state = true;
}

/// **The contextual primer** — the deliberate ask for POST_NOTIFICATIONS.
///
/// It appears on My Schedule, and only when BOTH are true:
///
///   * the user has at least one approved item still ahead of them, so there is
///     something concrete to be reminded about; and
///   * the OS will not currently deliver that reminder.
///
/// That is the whole design. **It is never shown at launch**, which is what the
/// old behaviour amounted to: `MessagingService` called
/// `FirebaseMessaging.requestPermission()` during token registration on first
/// sign-in, so the system prompt landed on a user who had not yet seen a single
/// screen of the app and had no idea what they were being asked about. Android
/// gives that prompt out roughly once, and a "deny" is effectively final — the
/// OS will not ask again and the only route back is Settings. Spending it on a
/// cold launch is spending it badly. That call is now gone, and this is the one
/// place the app asks (DECISIONS.md → "Reminder layer, Part 1").
///
/// It asks for the two permissions SEPARATELY and in order of consequence.
/// POST_NOTIFICATIONS decides whether a reminder appears at all;
/// SCHEDULE_EXACT_ALARM decides whether it appears on time. Bundling them into
/// one "allow notifications?" would make the second invisible, and the second is
/// the one the spike measured as the difference between +0.6s and +110s.
class ReminderPrimerCard extends ConsumerWidget {
  const ReminderPrimerCard({super.key, required this.hasUpcomingItems});

  /// Whether there is anything to be reminded about. The card is meaningless —
  /// and reads as a nag — without it.
  final bool hasUpcomingItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasUpcomingItems) return const SizedBox.shrink();
    if (ref.watch(_primerDismissedProvider)) return const SizedBox.shrink();

    // While the read is in flight, or if it failed, show nothing. A card that
    // flickers in and out on every rebuild would be worse than a late one.
    final state = ref.watch(reminderPermissionStateProvider).value;
    if (state == null || state.isFullyReady) return const SizedBox.shrink();

    final copy = _copyFor(state);

    return Card(
      // Line work, not a fill. An orange filled surface means "a schedule item
      // is waiting on you" (UI-RULES.md §2.7) and that signal only stays
      // trustworthy if nothing else spends it.
      shape: RoundedRectangleBorder(
        borderRadius: Radii.md,
        side: BorderSide(color: context.attention, width: Sizes.hairline),
      ),
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(copy.icon,
                    color: context.attention, size: Sizes.inlineIcon),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(copy.title, style: context.text.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              copy.body,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Space.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      ref.read(_primerDismissedProvider.notifier).dismiss(),
                  child: const Text('Not now'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: () => runReminderPrimer(context, ref),
                  child: Text(copy.action),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  _PrimerCopy _copyFor(ReminderPermissionState state) {
    if (!state.notificationsEnabled) {
      return const _PrimerCopy(
        icon: AppIcons.reminders,
        title: 'Reminders are off',
        body: "You've approved items with a time, but this phone won't notify "
            "you when they're due.",
        action: 'Turn on',
      );
    }
    if (!state.exactAlarmsAllowed) {
      return const _PrimerCopy(
        icon: AppIcons.exactTiming,
        title: 'Reminders may arrive late',
        body: 'One more permission lets the app wake your phone at the exact '
            'time. Without it, reminders can be late — much later while asleep.',
        action: 'Fix timing',
      );
    }
    return const _PrimerCopy(
      icon: AppIcons.reminders,
      title: 'Reminders won’t ring over other apps',
      body: 'One more permission lets a reminder ring like an alarm even while '
          "you're using another app.",
      action: 'Allow',
    );
  }
}

class _PrimerCopy {
  const _PrimerCopy({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String body;
  final String action;
}

/// Explains, then asks. Handles whichever permission is missing, most
/// consequential first, and re-reads the OS afterwards so the card updates
/// itself.
///
/// **The explanation comes before the system prompt, always.** Once Android's
/// dialog is on screen the app cannot say anything more, and a "Deny" there is
/// close to permanent. This is the only chance to give the user a reason.
Future<void> runReminderPrimer(BuildContext context, WidgetRef ref) async {
  final permissions = ref.read(reminderPermissionsProvider);
  final state = await permissions.read();
  if (!context.mounted) return;

  if (!state.notificationsEnabled) {
    final agreed = await _explain(
      context,
      title: 'Get reminded when it’s time',
      body: 'Shows a notification when an approved item comes due. That’s all '
          'it’s used for, and it never leaves your device.',
      confirm: 'Continue',
    );
    if (agreed != true || !context.mounted) return;

    final granted = await permissions.requestNotifications();
    if (!context.mounted) return;

    if (!granted) {
      // Android will not show its prompt a second time, so there is exactly one
      // route left and the user has to be told what it is. Saying nothing here
      // is how an app ends up permanently silent with no explanation.
      final toSettings = await _explain(
        context,
        title: 'Notifications are blocked',
        body: 'Android won’t ask again from inside the app. You can turn '
            'notifications on for Checkmate in system settings.',
        confirm: 'Open settings',
      );
      if (toSettings == true) await permissions.openSystemSettings();
    }
  } else if (!state.exactAlarmsAllowed) {
    final agreed = await _explain(
      context,
      title: 'Remind me on time',
      body: 'Lets the app wake your phone at the exact time. Without it, '
          'reminders can be late — sometimes hours overnight. Opens Android’s '
          'settings.',
      confirm: 'Open settings',
    );
    if (agreed != true) return;
    await permissions.requestExactAlarms();
  } else if (!state.fullScreenIntentAllowed) {
    final agreed = await _explain(
      context,
      title: 'Ring over other apps',
      body: 'Lets a reminder ring like an alarm, over other apps and on the '
          'lock screen. Opens Android’s settings.',
      confirm: 'Open settings',
    );
    if (agreed != true) return;
    await permissions.requestFullScreenIntent();
  }

  // Whatever happened, the OS is the authority — re-read rather than assume.
  ref.invalidate(reminderPermissionStateProvider);
}

Future<bool?> _explain(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
}
