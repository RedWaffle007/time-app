import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/timezone/tz_resolver.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/application/group_providers.dart';
import '../../groups/domain/planner_grant.dart';
import '../application/schedule_providers.dart';

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
  String? _groupId; // group the grant came from
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
    if (me == null || _targetUid == null || _groupId == null) return;

    final wall = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );

    setState(() => _saving = true);
    try {
      await ref.read(scheduleRepositoryProvider).createItem(
            targetUid: _targetUid!,
            createdByUid: me.uid,
            groupId: _groupId!,
            title: _titleController.text,
            note: _noteController.text,
            wall: wall,
            timezone: timezone,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item sent for approval.')),
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
      body: targetsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (grants) {
          if (grants.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  "No one has let you plan for them yet.\n\n"
                  "Ask a friend to turn on \"can plan for me\" for you in a "
                  "shared group.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _buildForm(grants);
        },
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
        // Target picker.
        const Text('Plan for', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
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
                "You're building in ${selectedProfile?.name ?? 'their'} local "
                "time — $timezone.",
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
                      : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.access_time),
                  label: Text(_time == null ? 'Pick time' : _time!.format(context)),
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
              'Fires at: ${_previewLocal(timezone)}  ($timezone)',
              style: const TextStyle(fontStyle: FontStyle.italic),
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

  Widget _targetTile(PlannerGrant grant) {
    final profile = ref.watch(profileByUidProvider(grant.targetUid)).value;
    final selected = _targetUid == grant.targetUid;
    return Card(
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: ListTile(
        leading: const Icon(Icons.person),
        title: Text(profile?.name ?? grant.targetUid),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(Icons.check) : null,
        onTap: () => setState(() {
          _targetUid = grant.targetUid;
          _groupId = grant.groupId;
        }),
      ),
    );
  }

  String _previewLocal(String timezone) {
    final wall = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );
    final utc = resolveWallTimeToUtc(wall, timezone);
    return formatInZone(utc, timezone);
  }
}
