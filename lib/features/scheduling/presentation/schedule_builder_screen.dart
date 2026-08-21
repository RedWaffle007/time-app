import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/quiet_hours.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/warning_panel.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/application/group_providers.dart';
import '../../groups/domain/planner_grant.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/schedule_providers.dart';
import '../domain/schedule_item.dart';

/// Planner picks a target they may plan for and creates a timetable item IN THE
/// TARGET'S LOCAL TIME.
class ScheduleBuilderScreen extends ConsumerStatefulWidget {
  const ScheduleBuilderScreen({super.key, this.initialDate});

  /// A date to open with, seeded by the calendar when a user plans from a
  /// tapped day (`Routes.calendarNew`). Null everywhere else, and null behaves
  /// exactly as this screen always has — no date chosen until the user picks
  /// one.
  ///
  /// **The date only.** Not a time: a date is what the user actually indicated
  /// by tapping a cell, and pre-filling a time they never chose would let an
  /// item be sent for approval at an hour nobody selected. `_canSave` still
  /// requires a time, so the form cannot be submitted straight through.
  ///
  /// This one optional parameter is the whole of the calendar's integration
  /// with the builder. The calendar deliberately has no create flow of its own.
  final DateTime? initialDate;

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
  void initState() {
    super.initState();
    _date = widget.initialDate;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    var firstDate = now.subtract(const Duration(days: 1));
    var lastDate = now.add(const Duration(days: 365));

    // A date seeded from the calendar can sit outside that window — the grid
    // pages years either way. `showDatePicker` ASSERTS that initialDate is in
    // range, so a user who tapped last March and then opened the picker would
    // crash the screen rather than see a clamped date. Widen the window to
    // contain whatever is already selected; the ordinary case is untouched.
    final selected = _date;
    if (selected != null) {
      if (selected.isBefore(firstDate)) firstDate = selected;
      if (selected.isAfter(lastDate)) lastDate = selected;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: selected ?? now,
      firstDate: firstDate,
      lastDate: lastDate,
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
      padding: Space.screenList,
      children: [
        // Target picker. "Myself" is always first, then anyone who granted you.
        const SectionHeader('Plan for'),
        _selfTile(),
        for (final grant in grants) _targetTile(grant),
        const Divider(height: Space.xxl),

        if (_targetUid != null) ...[
          if (timezone != null)
            // Neutral, not a doctrine colour: this is orientation, neither an
            // action (green) nor something waiting on you (orange).
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: context.colors.surfaceContainer,
                borderRadius: Radii.sm,
              ),
              child: Text(
                _isSelf
                    ? "You're building in your local time — $timezone."
                    : "You're building in ${selectedProfile?.name ?? 'their'} "
                        "local time — $timezone.",
                style: context.text.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title (what to do)'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(AppIcons.date),
                  label: Text(_date == null
                      ? 'Pick date'
                      : formatWallDate(context, _date!)),
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(AppIcons.time),
                  label: Text(_time == null
                      ? 'Pick time'
                      : formatTimeOfDay(context, _time!)),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          if (timezone != null && _date != null && _time != null) ...[
            const SizedBox(height: Space.lg),
            Text(
              'Fires at: ${_previewLocal(context, timezone)}  ($timezone)',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            _dstBanner(timezone),
            _warningBanner(
              timezone,
              selectedProfile?.quietHoursStartMinutes,
              selectedProfile?.quietHoursEndMinutes,
            ),
          ],
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: (_canSave && timezone != null) ? () => _save(timezone) : null,
            child: _saving
                ? const SizedBox(
                    height: Sizes.buttonSpinner,
                    width: Sizes.buttonSpinner,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isSelf ? 'Add to my schedule' : 'Send for approval'),
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
        leading: const Icon(AppIcons.person),
        // Your own NAME plus the marker, not the bare word "Myself" — a member
        // genuinely called "Myself Self" exists in test data, and against a
        // list of other people's names a label that never shows your own is
        // unresolvable the moment two of you share a name. Falls back to the
        // bare marker only while the profile is still loading.
        title: Text(profile == null ? 'Myself' : '${profile.name} (myself)'),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(AppIcons.selected) : null,
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
        leading: const Icon(AppIcons.person),
        title: Text(profile?.name ?? grant.targetUid),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(AppIcons.selected) : null,
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
  /// or the fixed 11pm–6am band. Warning-only — the save button still works;
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
        '${_isSelf ? 'your' : 'their'} quiet hours '
            '(${formatMinutesOfDayLocalized(context, quietStart)}'
            '–${formatMinutesOfDayLocalized(context, quietEnd)})',
      if (warnings.lateNight) 'late night (11pm–6am)',
    ];

    return WarningPanel(
      'This falls in ${reasons.join(' and ')}. '
      '${_isSelf ? 'You can still add it.' : 'You can still send it — they approve every item.'}',
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
    return text == null ? const SizedBox.shrink() : WarningPanel(text);
  }
}
