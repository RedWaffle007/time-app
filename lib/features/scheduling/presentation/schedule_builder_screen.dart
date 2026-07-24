import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/timezone/quiet_hours.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/application/group_providers.dart';
import '../../groups/domain/planner_grant.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/schedule_providers.dart';
import '../domain/schedule_item.dart';

/// Planner picks a target they may plan for and creates a timetable item IN THE
/// TARGET'S LOCAL TIME.
class ScheduleBuilderScreen extends ConsumerStatefulWidget {
  const ScheduleBuilderScreen({super.key});

  @override
  ConsumerState<ScheduleBuilderScreen> createState() =>
      _ScheduleBuilderScreenState();
}

class _ScheduleBuilderScreenState extends ConsumerState<ScheduleBuilderScreen> {
  String? _targetUid; // selected target
  String? _groupId; // group the grant came from (null when planning for self)
  bool _isSelf = false; // selected target is me → skip queue, no group
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _time = picked);
  }

  bool get _canSave =>
      _targetUid != null &&
      _date != null &&
      _time != null &&
      _titleController.text.trim().isNotEmpty &&
      !_saving;

  Future<void> _save(String timezone) async {
    final me = ref.read(authRepositoryProvider).currentUser;
    if (me == null || _targetUid == null) return;
    if (!_isSelf && _groupId == null) return; // planning for others needs a group

    final wall = _wall();

    setState(() => _saving = true);
    try {
      // Self-authored items are born approved (skip the queue); planner items
      // stay pending for the target to approve.
      final itemId = await ref.read(scheduleRepositoryProvider).createItem(
            targetUid: _targetUid!,
            createdByUid: me.uid,
            groupId: _isSelf ? null : _groupId,
            title: _titleController.text,
            note: _noteController.text,
            wall: wall,
            timezone: timezone,
            status: _isSelf
                ? ScheduleItemStatus.approved
                : ScheduleItemStatus.pending,
          );
      // Notify the target that a plan was created for them. Self-planned items
      // have no one else to tell (the Worker would skip them anyway).
      if (!_isSelf) {
        await ref.read(notificationEventNotifierProvider).notify(
              event: NotifyEvent.created,
              targetUid: _targetUid!,
              itemId: itemId,
            );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isSelf
              ? 'Added to your schedule.'
              : 'Item sent for approval.'),
        ),
      );
      // Reset for the next item, keep the same target.
      setState(() {
        _titleController.clear();
        _noteController.clear();
        _date = null;
        _time = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetsAsync = ref.watch(myPlanningTargetsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule Builder')),
      // No empty-state: "Myself" is always an available target, so the form
      // always renders — a solo user with zero grants can still plan.
      body: AsyncView<List<PlannerGrant>>(
        value: targetsAsync,
        onRetry: () => ref.invalidate(myPlanningTargetsProvider),
        builder: (context, grants) => _buildForm(grants),
      ),
    );
  }

  Widget _buildForm(List<PlannerGrant> grants) {
    // Resolve the selected target's profile (name + timezone).
    final selectedProfile =
        _targetUid == null ? null : ref.watch(profileByUidProvider(_targetUid!)).value;
    final timezone = selectedProfile?.homeTimezone;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Target picker. "Myself" is always first, then anyone who granted you.
        const Text('Plan for', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _selfTile(),
        for (final grant in grants) _targetTile(grant),
        const Divider(height: 32),

        if (_targetUid != null) ...[
          if (timezone != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _isSelf
                    ? "You're building in your local time — $timezone."
                    : "You're building in ${selectedProfile?.name ?? 'their'} "
                        "local time — $timezone.",
                style: const TextStyle(fontSize: 13),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title (what to do)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today),
                  label: Text(_date == null
                      ? 'Pick date'
                      : formatWallDate(context, _date!)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.access_time),
                  label: Text(_time == null
                      ? 'Pick time'
                      : formatTimeOfDay(context, _time!)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          if (timezone != null && _date != null && _time != null) ...[
            const SizedBox(height: 16),
            Text(
              'Fires at: ${_previewLocal(context, timezone)}  ($timezone)',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            _dstBanner(timezone),
            _warningBanner(
              timezone,
              selectedProfile?.quietHoursStartMinutes,
              selectedProfile?.quietHoursEndMinutes,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_canSave && timezone != null) ? () => _save(timezone) : null,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send for approval'),
          ),
        ],
      ],
    );
  }

  /// Always-present "Myself" target — self-planning, no grant/group required.
  Widget _selfTile() {
    final me = ref.read(authRepositoryProvider).currentUser;
    if (me == null) return const SizedBox.shrink();
    final profile = ref.watch(profileByUidProvider(me.uid)).value;
    final selected = _isSelf;
    return Card(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: const Icon(Icons.person_outline),
        title: const Text('Myself'),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(Icons.check) : null,
        onTap: () => setState(() {
          _isSelf = true;
          _targetUid = me.uid;
          _groupId = null;
        }),
      ),
    );
  }

  Widget _targetTile(PlannerGrant grant) {
    final profile = ref.watch(profileByUidProvider(grant.targetUid)).value;
    final selected = !_isSelf && _targetUid == grant.targetUid;
    return Card(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: const Icon(Icons.person),
        title: Text(profile?.name ?? grant.targetUid),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(Icons.check) : null,
        onTap: () => setState(() {
          _isSelf = false;
          _targetUid = grant.targetUid;
          _groupId = grant.groupId;
        }),
      ),
    );
  }

  String _previewLocal(BuildContext context, String timezone) {
    final utc = resolveWallTimeToUtc(_wall(), timezone);
    return formatInstant(context, utc, timezone);
  }

  // The entered wall-clock is timezone-agnostic — just the fields the planner
  // typed, to be interpreted in the TARGET's zone. It MUST be built as a
  // UTC-kind DateTime (a pure field carrier): a local `DateTime(...)` would be
  // silently normalized by the PLANNER's device zone if those fields land in a
  // DST gap there, corrupting the time before it ever reaches the resolver.
  DateTime _wall() => DateTime.utc(
        _date!.year,
        _date!.month,
        _date!.day,
        _time!.hour,
        _time!.minute,
      );

  /// Non-blocking warning if the chosen time lands in the target's quiet hours
  /// or the fixed 11pm–6am band. Warning-only — "Send for approval" still works;
  /// enforcement arrives with the alarm layer.
  Widget _warningBanner(String timezone, int? quietStart, int? quietEnd) {
    final utc = resolveWallTimeToUtc(_wall(), timezone);
    final warnings = warningsForInstant(
      utc,
      timezone,
      quietStartMinutes: quietStart,
      quietEndMinutes: quietEnd,
    );
    if (!warnings.any) return const SizedBox.shrink();

    final reasons = <String>[
      if (warnings.quietHours && quietStart != null && quietEnd != null)
        'their quiet hours (${formatMinutesOfDayLocalized(context, quietStart)}'
            '–${formatMinutesOfDayLocalized(context, quietEnd)})',
      if (warnings.lateNight) 'late night (11pm–6am)',
    ];

    return _amberNote(
      'This falls in ${reasons.join(' and ')}. '
      'You can still send it — they approve every item.',
    );
  }

  /// Non-blocking notice when the chosen wall time is a DST gap/overlap in the
  /// target's zone, so the planner knows which instant will actually be used.
  Widget _dstBanner(String timezone) {
    final res = resolveWall(_wall(), timezone);
    final actual = formatInstant(context, res.utc, timezone);
    final text = switch (res.anomaly) {
      DstAnomaly.none => null,
      DstAnomaly.skipped => "That clock time doesn't exist on this date — "
          "clocks spring forward. It'll fire at $actual instead.",
      DstAnomaly.ambiguous => 'That clock time happens twice on this date — '
          'clocks fall back. It\'ll use the first: $actual.',
    };
    return text == null ? const SizedBox.shrink() : _amberNote(text);
  }

  Widget _amberNote(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
