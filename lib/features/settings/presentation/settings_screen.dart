import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/nav_tile.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../../applock/presentation/app_lock_tile.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/messaging_service.dart';
import '../../splash/presentation/startup_sound_tile.dart';
import '../../theme/application/theme_mode_controller.dart';
import '../data/feedback_launcher.dart';

/// **Settings** (Batch H2, DECISIONS.md "You = your profile; Settings holds
/// the rest"). Everything that is not your public identity: reminders, quiet
/// hours, this device's options, help and sign out. Reached from the gear on
/// your own profile; pushed top-level so it covers the bar.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: Space.screenListSafe(context),
        children: [
          const SectionHeader('Reminders'),
          NavTile(
            icon: AppIcons.permissions,
            label: 'Reminders & permissions',
            onTap: () => context.push(Routes.permissions),
          ),
          const QuietHoursTile(),
          const SectionHeader('This device'),
          const AppLockTile(),
          const StartupSoundTile(),
          const _ThemeModeTile(),
          const SectionHeader('Help'),
          NavTile(
            icon: AppIcons.walkthrough,
            label: 'How this app works',
            onTap: () => context.push(Routes.howItWorks),
          ),
          // Near the bottom, off the main tabs (2026-09-28).
          NavTile(
            key: const ValueKey('send-feedback'),
            icon: AppIcons.feedback,
            label: 'Send feedback',
            subtitle:
                'Ideas, bugs or anything else. It goes straight to the '
                'developer.',
            onTap: () => sendFeedback(context, ref),
          ),
          if (kDebugMode)
            NavTile(
              icon: AppIcons.devMenu,
              label: 'Dev menu (debug)',
              onTap: () => context.push(Routes.devMenu),
            ),
          const SizedBox(height: Space.md),
          NavTile(
            icon: AppIcons.signOut,
            label: 'Sign out',
            showChevron: false,
            onTap: () => signOutWithTokenCleanup(ref),
          ),
        ],
      ),
    );
  }
}

/// Opens the email app on a prefilled message to [kFeedbackAddress]. With
/// no email app installed, shows the address with a Copy button instead.
Future<void> sendFeedback(BuildContext context, WidgetRef ref) async {
  final launcher = ref.read(feedbackLauncherProvider);
  final version = await launcher.appVersion();
  final opened = await launcher.compose(
    to: kFeedbackAddress,
    subject: kFeedbackSubject,
    body: feedbackEmailBody(version),
  );
  if (opened || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Send feedback'),
      content: Text(
        'No email app opened. Write to the developer at $kFeedbackAddress.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('feedback-copy-address'),
          onPressed: () async {
            await Clipboard.setData(
              const ClipboardData(text: kFeedbackAddress),
            );
            if (ctx.mounted) Navigator.pop(ctx);
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Address copied.')));
            }
          },
          icon: const Icon(AppIcons.copy),
          label: const Text('Copy address'),
        ),
      ],
    ),
  );
}

/// Quiet hours: a window planners are warned about, in your home timezone.
/// Saves the moment it changes ([ProfileRepository.updateQuietHours]); it is
/// not part of any form (moved out of Edit profile in Batch H2).
class QuietHoursTile extends ConsumerStatefulWidget {
  const QuietHoursTile({super.key});

  @override
  ConsumerState<QuietHoursTile> createState() => _QuietHoursTileState();
}

class _QuietHoursTileState extends ConsumerState<QuietHoursTile> {
  static const _defaultStart = TimeOfDay(hour: 22, minute: 0);
  static const _defaultEnd = TimeOfDay(hour: 7, minute: 0);

  bool _saving = false;

  static TimeOfDay _time(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

  static int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _write({TimeOfDay? start, TimeOfDay? end}) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateQuietHours(
            uid: uid,
            startMinutes: start == null ? null : _minutes(start),
            endMinutes: end == null ? null : _minutes(end),
          );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Could not save quiet hours.')),
          );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick(
    TimeOfDay start,
    TimeOfDay end, {
    required bool isStart,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? start : end,
    );
    if (picked == null) return;
    await _write(start: isStart ? picked : start, end: isStart ? end : picked);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    final enabled = profile?.hasQuietHours ?? false;
    final start = enabled
        ? _time(profile!.quietHoursStartMinutes!)
        : _defaultStart;
    final end = enabled ? _time(profile!.quietHoursEndMinutes!) : _defaultEnd;

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('quiet-hours-switch'),
              secondary: Icon(
                AppIcons.quietHoursStart,
                color: context.colors.onSurfaceVariant,
              ),
              title: Text('Quiet hours', style: context.text.titleMedium),
              subtitle: const Text(
                'People planning for you are warned before they pick a time '
                'in this window.',
              ),
              value: enabled,
              onChanged: profile == null || _saving
                  ? null
                  : (on) => on
                        ? _write(start: _defaultStart, end: _defaultEnd)
                        : _write(),
            ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                child: Wrap(
                  spacing: Space.md,
                  runSpacing: Space.sm,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _pick(start, end, isStart: true),
                      icon: const Icon(AppIcons.quietHoursStart),
                      label: Text('From ${formatTimeOfDay(context, start)}'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _pick(start, end, isStart: false),
                      icon: const Icon(AppIcons.quietHoursEnd),
                      label: Text('To ${formatTimeOfDay(context, end)}'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The device-local appearance preference. System remains the default, while
/// light and dark let a person deliberately override it from Settings.
class _ThemeModeTile extends ConsumerWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: Icon(
                AppIcons.themeSystem,
                color: context.colors.onSurfaceVariant,
              ),
              title: Text('Theme', style: context.text.titleMedium),
              subtitle: Text(
                switch (mode) {
                  ThemeMode.light => 'Light',
                  ThemeMode.dark => 'Dark',
                  ThemeMode.system => 'System default',
                },
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              child: SegmentedButton<ThemeMode>(
                expandedInsets: EdgeInsets.zero,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    tooltip: 'Light theme',
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    tooltip: 'Dark theme',
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    tooltip: 'Use system theme',
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (selection) {
                  ref.read(themeModeProvider.notifier).setMode(selection.first);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
