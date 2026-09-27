import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/group_plan_reporter.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/schedule_providers.dart';

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
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GroupPlanSheet(
      groupId: groupId,
      groupName: groupName,
      candidates: candidates,
    ),
  );
}

class _GroupPlanSheet extends ConsumerStatefulWidget {
  const _GroupPlanSheet({
    required this.groupId,
    required this.groupName,
    required this.candidates,
  });

  final String groupId;
  final String groupName;
  final List<GroupPlanCandidate> candidates;

  @override
  ConsumerState<_GroupPlanSheet> createState() => _GroupPlanSheetState();
}

class _GroupPlanSheetState extends ConsumerState<_GroupPlanSheet> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _saving = false;
  String? _error;

  /// Everyone who gave me either permission, plus me (F2: one permission).
  List<GroupPlanCandidate> get _recipients => widget.candidates;

  /// The member-times pop-up opens by itself once, on the first date or time
  /// pick (item 4); "Everyone's time" reopens it.
  bool _shownMemberTimes = false;

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

  /// Every member's current local date and time, one line each (item 4), so
  /// the planner can see what the chosen wall time means for everyone.
  Future<void> _showMemberTimes() {
    _shownMemberTimes = true;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) => AlertDialog(
          title: const Text("Everyone's time now"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in _recipients)
                  Builder(
                    builder: (context) {
                      final p = dialogRef
                          .watch(profileByUidProvider(c.uid))
                          .value;
                      final zone = p?.homeTimezone;
                      final name = c.isSelf ? 'You' : (p?.name ?? 'Loading…');
                      final now = zone == null || zone.isEmpty
                          ? null
                          : wallNowIn(zone);
                      return Padding(
                        key: ValueKey('member-time-${c.uid}'),
                        padding: const EdgeInsets.symmetric(vertical: Space.xs),
                        child: Text(
                          now == null
                              ? '$name: time unknown'
                              : '$name: ${formatWallDate(context, now)}, '
                                    '${formatWallTimeOfDay(context, now)}',
                          style: context.text.bodyMedium,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    if (!_shownMemberTimes) {
      await _showMemberTimes();
      if (!mounted) return;
    }
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
    if (!_shownMemberTimes) {
      await _showMemberTimes();
      if (!mounted) return;
    }
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
      final names = <String, String>{};
      final resolved = await Future.wait(
        _recipients.map((c) async {
          try {
            final p = await repo
                .watchProfile(c.uid)
                .first
                .timeout(const Duration(seconds: 8));
            final tz = p?.homeTimezone;
            if (tz == null || tz.isEmpty) return null;
            names[c.uid] = p?.name ?? 'A member';
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

      // Members whose minute was already taken got no alarm (item 4). The
      // Worker verifies who was really busy, tells each of them and sends the
      // summary; its answer is what names them here.
      Set<String>? verifiedBusy;
      if (result.failed.isNotEmpty) {
        verifiedBusy = await ref
            .read(groupPlanReporterProvider)
            .reportBusy(
              groupId: widget.groupId,
              title: _title.text.trim(),
              setCount: result.sent.length,
              failed: result.failed,
            );
      }

      if (!mounted) return;
      final n = result.sent.length;
      final skipped = result.skippedPast + result.skippedOther;
      final busyNames = [
        for (final f in result.failed)
          if (verifiedBusy?.contains(f.uid) ?? false)
            names[f.uid] ?? 'A member',
      ];
      final String message;
      if (n == 0 && result.skippedPast > 0 && result.skippedOther == 0) {
        // The single most common miss: a time already gone. Say so, rather than
        // the useless "no one could be planned for".
        message = 'That time has already passed. Pick a later time.';
      } else if (busyNames.isNotEmpty) {
        message =
            'Alarm set for $n ${n == 1 ? 'member' : 'members'}. '
            'Busy at that time: ${busyNames.join(', ')}.';
      } else if (n == 0) {
        message = 'No one could be planned for right now.';
      } else {
        message =
            'Alarm set for $n '
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
    final recipients = _recipients;
    final count = recipients.length;

    // Keep every member's profile warm, so the member-times pop-up has names
    // and zones on its first frame.
    for (final c in recipients) {
      ref.watch(profileByUidProvider(c.uid));
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
                  ? "You can't plan for anyone in this group yet."
                  : 'Rings for $count ${count == 1 ? 'member' : 'members'} '
                        '(you included), each at this time in their own local '
                        'zone.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
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
                TextButton.icon(
                  key: const ValueKey('everyones-time'),
                  onPressed: _showMemberTimes,
                  icon: const Icon(AppIcons.time),
                  label: const Text("Everyone's time"),
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
                  : const Text('Send to the group'),
            ),
          ],
        ),
      ),
    );
  }
}
