import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/section_header.dart';
import '../application/reminder_providers.dart';
import '../domain/reminder.dart';

/// The readout for the fire-timing audit — dev-only, and the whole reason the
/// spike's CSV machinery was carried into the product.
///
/// Three things, in the order you need them when a reminder did not arrive:
///
///   1. **Permissions.** On this Redmi, SCHEDULE_EXACT_ALARM is revoked by every
///      reinstall (spike README trap 1), and a POST_NOTIFICATIONS denial made a
///      *perfect* spike run read as a total failure (trap 3). Both are checked
///      here first, because both look identical from the outside: nothing
///      happens.
///   2. **The mirror** — what the app believes it armed.
///   3. **The CSV** — what the OS actually did, written natively at fire time,
///      including the device's Doze / power-save / battery-optimisation / screen
///      state at the moment of delivery. A 40-minute delay means nothing without
///      that last part.
///
/// The log is written in release builds too; this screen is just the convenient
/// way to read it. Without a dev menu, `adb pull` the path shown at the bottom.
class ReminderDiagnosticsScreen extends ConsumerStatefulWidget {
  const ReminderDiagnosticsScreen({super.key});

  @override
  ConsumerState<ReminderDiagnosticsScreen> createState() =>
      _ReminderDiagnosticsScreenState();
}

class _ReminderDiagnosticsScreenState
    extends ConsumerState<ReminderDiagnosticsScreen> {
  String _csv = '';
  String _path = '';
  List<ScheduledReminder> _mirror = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final audit = ref.read(reminderAuditLogProvider);
    final csv = await audit.read();
    final path = await audit.path();
    final mirror = await ref.read(reminderServiceProvider).debugMirror();
    if (!mounted) return;
    setState(() {
      _csv = csv;
      _path = path;
      _mirror = mirror;
      _loading = false;
    });
    ref.invalidate(reminderPermissionStateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(reminderPermissionStateProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminder audit'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(AppIcons.retry),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Copy CSV',
            icon: const Icon(AppIcons.copy),
            onPressed: _csv.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(AppIcons.clearLog),
            onPressed: _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: Space.screenListSafe(context),
              children: [
                const SectionHeader('Permissions'),
                if (permissions == null)
                  const Text('Reading…')
                else ...[
                  _flag(
                    'Notifications (POST_NOTIFICATIONS)',
                    permissions.notificationsEnabled,
                    'A reminder fires and posts nothing at all.',
                  ),
                  _flag(
                    'Exact alarms (SCHEDULE_EXACT_ALARM)',
                    permissions.exactAlarmsAllowed,
                    'Reminders are downgraded to whenever the phone next wakes.',
                  ),
                ],
                const SectionHeader('Armed (what the app believes)'),
                if (_mirror.isEmpty)
                  Text(
                    'Nothing armed.',
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  )
                else
                  for (final r in _mirror)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.xs),
                      child: Text(
                        '#${r.notificationId}  ${r.itemId}\n'
                        '    ${r.fireAtUtc.toIso8601String()}',
                        style: context.codeDisplay,
                      ),
                    ),
                const SectionHeader('Fire log (written natively, at fire time)'),
                if (_csv.isEmpty)
                  Text(
                    'Empty. Rows appear once a reminder is armed.',
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  )
                else
                  // Horizontal scroll of its own: CSV rows are wide, and a
                  // wrapped row is unreadable.
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(_csv, style: context.codeDisplay),
                  ),
                const SectionHeader('File'),
                SelectableText(_path, style: context.codeDisplay),
              ],
            ),
    );
  }

  Widget _flag(String label, bool ok, String consequence) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? AppIcons.approved : AppIcons.rejected,
            size: Sizes.inlineIcon,
            color: ok ? context.colors.primary : context.colors.error,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.text.bodyMedium),
                if (!ok)
                  Text(
                    consequence,
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('CSV copied')));
  }

  Future<void> _clear() async {
    await ref.read(reminderAuditLogProvider).clear();
    await _load();
  }
}
