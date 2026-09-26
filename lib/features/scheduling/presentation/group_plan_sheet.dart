import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/conflict_disclosure.dart';
import '../application/group_plan_recipients.dart';
import '../application/schedule_providers.dart';
import '../application/target_schedule_providers.dart';
import '../domain/schedule_item.dart';
import 'conflict_warning_dialog.dart';

/// One eligible group-plan recipient: a member the planner selected, plus
/// whether it is the planner themselves (self items skip the queue).
typedef GroupPlanCandidate = ({String uid, bool isSelf});

/// **Plan one item for a whole group at once** — the group capability pairwise
/// friendships cannot offer. Opened from the group detail screen with the set
/// of members the planner already holds a grant over (plus themselves).
///
/// Each member gets the item in THEIR OWN home timezone, resolved at send time;
/// the sheet just collects the shared title/day/time/note. The fan-out itself
/// (and its per-member past-guard and best-effort semantics) lives in
/// `ScheduleRepository.planForGroup`.
Future<void> showGroupPlanSheet(
  BuildContext context,
  WidgetRef ref, {
  required String groupId,
  required String groupName,
  required List<GroupPlanCandidate> candidates,
  // Other members who gave ME their emergency permission (item 15). Non-empty
  // shows the Emergency switch.
  Set<String> emergencyUids = const {},
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GroupPlanSheet(
      groupId: groupId,
      groupName: groupName,
      candidates: candidates,
      emergencyUids: emergencyUids,
    ),
  );
}

class _GroupPlanSheet extends ConsumerStatefulWidget {
  const _GroupPlanSheet({
    required this.groupId,
    required this.groupName,
    required this.candidates,
    required this.emergencyUids,
  });

  final String groupId;
  final String groupName;
  final List<GroupPlanCandidate> candidates;
  final Set<String> emergencyUids;

  @override
  ConsumerState<_GroupPlanSheet> createState() => _GroupPlanSheetState();
}

class _GroupPlanSheetState extends ConsumerState<_GroupPlanSheet> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _saving = false;
  bool _emergency = false;
  String? _error;

  ({List<GroupPlanCandidate> recipients, List<String> skippedUids}) get _plan =>
      groupPlanRecipients(
        candidates: widget.candidates,
        emergencyUids: widget.emergencyUids,
        emergency: _emergency,
      );
  final _shownConflictFingerprints = <String>{};
  String? _queuedConflictFingerprint;
  String? _activeConflictFingerprint;
  bool _conflictDialogOpen = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _canSend =>
      _title.text.trim().isNotEmpty &&
      _date != null &&
      _time != null &&
      !_saving;

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

  DateTime _wall() => DateTime.utc(
    _date!.year,
    _date!.month,
    _date!.day,
    _time!.hour,
    _time!.minute,
  );

  void _queueConflictDisclosure({
    required String fingerprint,
    required List<ConflictDisclosureGroup> groups,
    required Map<String, String> readErrors,
  }) {
    if (_shownConflictFingerprints.contains(fingerprint) ||
        _queuedConflictFingerprint == fingerprint) {
      return;
    }
    _queuedConflictFingerprint = fingerprint;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_queuedConflictFingerprint != fingerprint ||
          _activeConflictFingerprint != fingerprint) {
        if (_queuedConflictFingerprint == fingerprint) {
          _queuedConflictFingerprint = null;
        }
        return;
      }
      if (_conflictDialogOpen) {
        _queuedConflictFingerprint = null;
        return;
      }
      _shownConflictFingerprints.add(fingerprint);
      _queuedConflictFingerprint = null;
      _conflictDialogOpen = true;
      await showConflictWarningDialog(
        context,
        groups: groups,
        readErrors: readErrors,
      );
      _conflictDialogOpen = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _send() async {
    final me = ref.read(currentUidProvider);
    if (me == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Resolve each candidate's home timezone now — a member with no profile
      // or no zone is dropped rather than planned in a wrong one.
      // Resolve every member's home timezone in PARALLEL via a one-shot
      // `Stream.first` on the repository, each bounded by a timeout. This
      // replaces `ref.read(profileByUidProvider(uid).future)`, which stalls: a
      // bare read of a StreamProvider.family instance nothing else keeps alive
      // never resolves its `.future`, hanging the whole send. A member we can't
      // resolve is skipped, never a freeze.
      final repo = ref.read(profileRepositoryProvider);
      final resolved = await Future.wait(
        _plan.recipients.map((c) async {
          try {
            final p = await repo
                .watchProfile(c.uid)
                .first
                .timeout(const Duration(seconds: 8));
            final tz = p?.homeTimezone;
            if (tz == null || tz.isEmpty) return null;
            return (uid: c.uid, timezone: tz, isSelf: c.isSelf);
          } catch (_) {
            return null;
          }
        }),
      );
      final targets = <({String uid, String timezone, bool isSelf})>[
        for (final t in resolved) ?t,
      ];

      final result = await ref
          .read(scheduleRepositoryProvider)
          .planForGroup(
            groupId: widget.groupId,
            createdByUid: me,
            targets: targets,
            title: _title.text,
            note: _note.text,
            wall: _wall(),
            tier: _emergency ? ItemTier.emergency : ItemTier.normal,
          );

      // Tell each non-self recipient a plan was created for them — best-effort
      // and DELIBERATELY NOT awaited. `notify()` refreshes the auth token
      // (`getIdToken()`), which has no timeout and hangs on a degraded network;
      // awaiting N of them sequentially would freeze the sheet on something the
      // Firestore writes above already made durable. Fire and forget.
      final notifier = ref.read(notificationEventNotifierProvider);
      for (final s in result.sent) {
        if (!s.isSelf) {
          unawaited(
            notifier.notify(
              event: NotifyEvent.created,
              targetUid: s.uid,
              itemId: s.itemId,
            ),
          );
        }
      }

      if (!mounted) return;
      final n = result.sent.length;
      final skipped =
          result.skippedPast + result.skippedOther + _plan.skippedUids.length;
      final String message;
      if (n == 0 && result.skippedPast > 0 && result.skippedOther == 0) {
        // The single most common miss: a time already gone. Say so, rather than
        // the useless "no one could be planned for".
        message = 'That time has already passed. Pick a later time.';
      } else if (n == 0) {
        message = 'No one could be planned for right now.';
      } else {
        message =
            '${_emergency ? 'Emergency planned' : 'Planned'} for $n '
            '${n == 1 ? 'member' : 'members'}'
            '${skipped > 0 ? ' · $skipped skipped' : ''}.';
      }
      messenger.showSnackBar(SnackBar(content: Text(message)));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not plan: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final plan = _plan;
    final count = plan.recipients.length;
    final canEmergency = widget.emergencyUids.isNotEmpty;
    _activeConflictFingerprint = null;

    // Wait for every candidate's profile + authorized schedule read so the
    // group flow emits ONE consolidated, name-grouped popup—not a procession of
    // per-member dialogs. A read failure is part of that same popup.
    if (_date != null && plan.recipients.isNotEmpty) {
      var allSettled = true;
      final groups = <ConflictDisclosureGroup>[];
      final readErrors = <String, String>{};
      final errorKeys = <String>[];
      for (final candidate in plan.recipients) {
        final profile = ref.watch(profileByUidProvider(candidate.uid));
        if (profile.isLoading && !profile.hasValue) {
          allSettled = false;
          continue;
        }
        final person = profile.value;
        final name = person?.name ?? 'Group member';
        final timezone = person?.homeTimezone;
        if (profile.hasError || timezone == null || timezone.isEmpty) {
          readErrors[candidate.uid] = name;
          errorKeys.add(
            '${candidate.uid}:profile:${profile.error.runtimeType}',
          );
          continue;
        }

        final schedule = ref.watch(targetScheduleProvider(candidate.uid));
        if (schedule.isLoading && !schedule.hasValue && !schedule.hasError) {
          allSettled = false;
          continue;
        }
        if (schedule.hasError) {
          readErrors[candidate.uid] = name;
          errorKeys.add(
            '${candidate.uid}:schedule:${schedule.error.runtimeType}',
          );
          continue;
        }
        final items = schedule.value;
        if (items == null) {
          allSettled = false;
          continue;
        }
        final instants = conflictInstantsForLocalDay(
          localDay: _date!,
          timezone: timezone,
          items: items,
        );
        if (instants.isNotEmpty) {
          groups.add(
            ConflictDisclosureGroup(
              uid: candidate.uid,
              name: name,
              timezone: timezone,
              instantsUtc: instants,
            ),
          );
        }
      }
      if (allSettled && (groups.isNotEmpty || readErrors.isNotEmpty)) {
        groups.sort((a, b) => a.name.compareTo(b.name));
        final fingerprint = conflictDisclosureFingerprint(
          localDay: _date!,
          groups: groups,
          errorUids: errorKeys,
        );
        _activeConflictFingerprint = fingerprint;
        _queueConflictDisclosure(
          fingerprint: fingerprint,
          groups: groups,
          readErrors: readErrors,
        );
      }
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Space.xl,
        Space.sm,
        Space.xl,
        Space.xl + bottomInset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Plan for ${widget.groupName}',
              style: context.text.titleLarge,
            ),
            const SizedBox(height: Space.xs),
            Text(
              count == 0
                  ? "You can't plan for anyone in this group yet — members grant "
                        'you permission first.'
                  : _emergency
                  ? 'Emergency for $count ${count == 1 ? 'member' : 'members'} '
                        '(you included), each at this time in their own local '
                        'zone. It skips approval and rings at the time.'
                  : 'Goes to $count ${count == 1 ? 'member' : 'members'}, each at '
                        'this time in their own local zone. Everyone still approves '
                        'it (you added yourself directly).',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (canEmergency) ...[
              const SizedBox(height: Space.sm),
              SwitchListTile(
                key: const ValueKey('group-plan-emergency'),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(AppIcons.emergency),
                title: const Text('Emergency'),
                subtitle: const Text(
                  'Only members who gave you emergency permission.',
                ),
                value: _emergency,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _emergency = v),
              ),
            ],
            if (plan.skippedUids.isNotEmpty) ...[
              const SizedBox(height: Space.xs),
              _SkippedMembers(uids: plan.skippedUids),
            ],
            const SizedBox(height: Space.lg),
            TextField(
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title (what to do)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            Wrap(
              spacing: Space.md,
              runSpacing: Space.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(AppIcons.date),
                  label: Text(
                    _date == null
                        ? 'Pick date'
                        : formatWallDate(context, _date!),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(AppIcons.time),
                  label: Text(
                    _time == null
                        ? 'Pick time'
                        : formatTimeOfDay(context, _time!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.md),
              Text(
                _error!,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.error,
                ),
              ),
            ],
            const SizedBox(height: Space.xl),
            FilledButton(
              onPressed: (_canSend && count > 0) ? _send : null,
              child: _saving
                  ? const SizedBox(
                      height: Sizes.buttonSpinner,
                      width: Sizes.buttonSpinner,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _emergency
                          ? 'Plan emergency for the group'
                          : 'Plan for the group',
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Members an emergency group plan will NOT reach, by name, so nobody is
/// silently left out (item 15).
class _SkippedMembers extends ConsumerWidget {
  const _SkippedMembers({required this.uids});

  final List<String> uids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = [
      for (final uid in uids)
        ref.watch(profileByUidProvider(uid)).value?.name ?? kProfileNameLoading,
    ];
    return Text(
      "Won't reach ${names.join(', ')} — no emergency permission.",
      key: const ValueKey('group-plan-skipped'),
      style: context.text.bodySmall?.copyWith(
        color: context.colors.onSurfaceVariant,
      ),
    );
  }
}
