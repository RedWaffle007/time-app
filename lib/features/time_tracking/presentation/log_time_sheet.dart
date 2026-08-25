import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../application/time_tracking_providers.dart';
import '../domain/tracked_entry.dart';

/// The canonical Track log sheet (UI-RULES.md §6.13) — the manual, free-form
/// entry point that did not exist before S1, and the shape the Done→track prompt
/// and (later) the voice flow converge on.
///
/// Creates when [existing] is null, edits it otherwise. Manual entries pass no
/// [sourceItemId] — the soft link is present only on Done-hook entries. Writes
/// through the existing [TrackedTimeRepository]; the one-day cap (1..1440) and
/// the minutes-are-the-unit rule are enforced here and in the rules.
///
/// Returns true if something was written.
Future<bool> showLogTimeSheet(
  BuildContext context,
  WidgetRef ref, {
  TrackedEntry? existing,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LogTimeSheet(existing: existing),
  );
  return result ?? false;
}

class _LogTimeSheet extends ConsumerStatefulWidget {
  const _LogTimeSheet({this.existing});
  final TrackedEntry? existing;

  @override
  ConsumerState<_LogTimeSheet> createState() => _LogTimeSheetState();
}

class _LogTimeSheetState extends ConsumerState<_LogTimeSheet> {
  static const _quickAdds = [15, 30, 45, 60];

  late final TextEditingController _task =
      TextEditingController(text: widget.existing?.taskName ?? '');
  late final TextEditingController _minutes = TextEditingController(
      text: widget.existing?.durationMinutes.toString() ?? '');

  late bool _rangeOn = widget.existing?.hasRange ?? false;
  // Only the START is user-set; the end is derived from start + duration.
  late TimeOfDay? _start = _parse(widget.existing?.startLocal);

  String? _error;

  bool get _isEditing => widget.existing != null;

  @override
  void dispose() {
    _task.dispose();
    _minutes.dispose();
    super.dispose();
  }

  static TimeOfDay? _parse(String? hhmm) {
    if (hhmm == null) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _start ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _start = picked);
  }

  /// The derived end for the current start + the minutes typed so far, or null
  /// when either is missing — drives the read-only preview.
  TimeOfDay? get _derivedEnd {
    final start = _start;
    final minutes = int.tryParse(_minutes.text.trim());
    if (start == null || minutes == null || minutes < 1) return null;
    final end = (start.hour * 60 + start.minute + minutes) % (24 * 60);
    return TimeOfDay(hour: end ~/ 60, minute: end % 60);
  }

  /// The derived end fell on the next day (start + duration ≥ 24h from start).
  bool _wrapsMidnight(TimeOfDay end) {
    final start = _start;
    if (start == null) return false;
    final endMin = end.hour * 60 + end.minute;
    final startMin = start.hour * 60 + start.minute;
    return endMin <= startMin;
  }

  Future<void> _save() async {
    final task = _task.text.trim();
    final minutes = int.tryParse(_minutes.text.trim());
    if (task.isEmpty) {
      setState(() => _error = 'Give the task a name.');
      return;
    }
    if (minutes == null || minutes < 1 || minutes > kMaxEntryMinutes) {
      setState(() =>
          _error = 'Enter minutes between 1 and $kMaxEntryMinutes (one day).');
      return;
    }
    // Range is optional and structurally both-or-neither: it exists iff a start
    // is set, and the end is always derived from start + duration.
    final keepRange = _rangeOn && _start != null;
    final startStr = keepRange ? _fmt(_start!) : null;
    final endStr = keepRange ? deriveEndLocal(startStr!, minutes) : null;

    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    final repo = ref.read(trackedTimeRepositoryProvider);

    if (_isEditing) {
      final e = widget.existing!;
      await repo.update(
        uid,
        TrackedEntry(
          id: e.id,
          taskName: task,
          durationMinutes: minutes,
          logDate: e.logDate, // editing never moves the day it belongs to
          startLocal: startStr,
          endLocal: endStr,
          sourceItemId: e.sourceItemId, // provenance is preserved on edit
          createdAt: e.createdAt,
        ),
      );
    } else {
      // A manual log is for today, in the user's home zone. No sourceItemId.
      final tz = ref.read(profileProvider).value?.homeTimezone ?? '';
      await repo.log(
        uid,
        TrackedEntry(
          id: '',
          taskName: task,
          durationMinutes: minutes,
          logDate: logDateFor(DateTime.now().toUtc(), tz),
          startLocal: startStr,
          endLocal: endStr,
        ),
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    // Lift the sheet above the keyboard.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          Space.xl, Space.sm, Space.xl, Space.xl + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_isEditing ? 'Edit entry' : 'Log time',
              style: context.text.titleLarge),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _task,
            autofocus: !_isEditing,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What were you doing?',
              hintText: 'e.g. walking, German practice',
            ),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _minutes,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Minutes spent',
              hintText: 'e.g. 30',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: Space.sm),
          // Sage quick-add chips (§6.13): they SET the minutes field, never
          // submit. primaryContainer tint keeps them clear of the §2.7 firewall.
          Wrap(
            spacing: Space.sm,
            children: [
              for (final m in _quickAdds)
                ChoiceChip(
                  label: Text('$m min'),
                  selected: int.tryParse(_minutes.text.trim()) == m,
                  onSelected: (_) => setState(() {
                    _minutes.text = '$m';
                    _error = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: Space.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add a start time'),
            subtitle: const Text('Optional — the end is set by the duration'),
            value: _rangeOn,
            onChanged: (v) => setState(() => _rangeOn = v),
          ),
          if (_rangeOn) ...[
            OutlinedButton.icon(
              onPressed: _pickStart,
              icon: const Icon(AppIcons.time),
              label: Text(_start == null
                  ? 'Start time'
                  : formatTimeOfDay(context, _start!)),
            ),
            // The end is derived, shown read-only. It follows the duration, so
            // the two can never disagree; a wrap past midnight is marked.
            if (_derivedEnd case final end?)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  'Ends ${formatTimeOfDay(context, end)}'
                  '${_wrapsMidnight(end) ? ' (+1d)' : ''}',
                  style: context.text.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
          ],
          const SizedBox(height: Space.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Space.sm),
              FilledButton(
                onPressed: _save,
                child: Text(_isEditing ? 'Save' : 'Log'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
