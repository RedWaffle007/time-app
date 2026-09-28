import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/field_glow.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/group_plan_reporter.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../voice_notes/application/group_voice_attacher.dart';
import '../../voice_notes/application/voice_note_providers.dart';
import '../../voice_notes/data/voice_note_client.dart';
import '../../voice_notes/domain/voice_library_note.dart';
import '../../voice_notes/presentation/library_note_choice.dart';
import '../../voice_notes/presentation/voice_library_picker.dart';
import '../../voice_notes/presentation/voice_note_recorder.dart';
import '../application/group_member_times.dart';
import '../application/schedule_providers.dart';
import 'schedule_builder_screen.dart'
    show
        AlarmKind,
        kDefaultAlarmEmoji,
        kTaskNameRequired,
        kVoiceAlarmTitle,
        kVoiceNoteEmoji,
        kVoiceNoteRequired;

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

  /// The same two alarm kinds as a plan for one friend (F4), always offered.
  AlarmKind _kind = AlarmKind.defaultAlarm;
  RecordedVoiceNote? _voiceDraft;
  VoiceLibraryNote? _libraryNote;
  bool _nameError = false;
  bool _voiceError = false;

  /// Before-Send preview (2026-09-27): members the Worker verified busy at the
  /// chosen minute. Null = not checked yet, or the Worker could not answer.
  Set<String>? _busy;
  bool _checking = false;
  int _checkGen = 0;

  /// The member-times pop-up opens by itself once, on the first date or time
  /// pick (item 4); "Everyone's time" reopens it.
  bool _shownMemberTimes = false;

  bool get _isVoice => _kind == AlarmKind.voiceNote;

  /// Who this plan is for. A voice note is the planner's own voice, and a
  /// self-plan can never carry one (F4), so a voice plan goes to the OTHER
  /// members only; a default alarm includes the planner, as before.
  List<GroupPlanCandidate> get _recipients => [
    for (final c in widget.candidates)
      if (!(_isVoice && c.isSelf)) c,
  ];

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _canSend => _date != null && _time != null && !_saving;

  String _nameOf(GroupPlanCandidate c) => c.isSelf
      ? 'You'
      : (ref.read(profileByUidProvider(c.uid)).value?.name ?? 'A member');

  String? _zoneOf(String uid) =>
      ref.read(profileByUidProvider(uid)).value?.homeTimezone;

  /// Ask the Worker who is busy at the chosen minute (each member's instant
  /// is the same wall time in THEIR zone). Stale answers are dropped.
  Future<void> _checkAvailability() async {
    if (_date == null || _time == null) return;
    final gen = ++_checkGen;
    final wall = _wall();
    final members = <({String uid, DateTime instantUtc})>[
      for (final c in widget.candidates)
        if (!c.isSelf)
          if (_zoneOf(c.uid) case final zone? when zone.isNotEmpty)
            (uid: c.uid, instantUtc: resolveWallTimeToUtc(wall, zone)),
    ];
    if (members.isEmpty) {
      setState(() => _busy = <String>{});
      return;
    }
    setState(() => _checking = true);
    final busy = await ref
        .read(groupPlanReporterProvider)
        .availability(groupId: widget.groupId, members: members);
    if (!mounted || gen != _checkGen) return;
    setState(() {
      _busy = busy;
      _checking = false;
    });
  }

  /// **Everyone's time**, grouped by timezone so it stays readable at any
  /// group size: one section per zone with its current time; busy members
  /// are tagged once a time is picked.
  Future<void> _showMemberTimes() {
    _shownMemberTimes = true;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) {
          final groups = groupMembersByZone([
            for (final c in widget.candidates)
              (
                uid: c.uid,
                name: c.isSelf
                    ? 'You'
                    : (dialogRef
                              .watch(profileByUidProvider(c.uid))
                              .value
                              ?.name ??
                          'Loading…'),
                isSelf: c.isSelf,
                zone: dialogRef
                    .watch(profileByUidProvider(c.uid))
                    .value
                    ?.homeTimezone,
                busy: _busy?.contains(c.uid) ?? false,
              ),
          ]);
          final maxHeight =
              MediaQuery.sizeOf(context).height * Sizes.modalMaxHeightFraction;
          return AlertDialog(
            title: const Text("Everyone's time now"),
            content: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final g in groups) _ZoneSection(group: g)],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Continue'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _chooseFromLibrary() async {
    final picked = await showVoiceLibraryPicker(context);
    if (picked == null || !mounted) return;
    setState(() {
      _libraryNote = picked;
      _voiceError = false;
    });
  }

  Future<void> _send() async {
    final me = ref.read(currentUidProvider);
    if (me == null) return;
    // Validate on tap, in red, like the Plan screen (F4).
    final nameMissing = !_isVoice && _title.text.trim().isEmpty;
    final voiceMissing =
        _isVoice && _voiceDraft == null && _libraryNote == null;
    if (nameMissing || voiceMissing) {
      setState(() {
        _nameError = nameMissing;
        _voiceError = voiceMissing;
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Resolve every recipient's home timezone in PARALLEL via a one-shot
      // `Stream.first` on the repository, each bounded by a timeout. A bare
      // read of a StreamProvider.family instance nothing keeps alive never
      // resolves its `.future` and hung the send. An unresolvable member is
      // skipped, never a freeze, and never planned in a wrong zone.
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

      // Voice: the planner's device uploads ONCE (or attaches the library
      // note); every other member gets a server-side copy (/voice/copy).
      final draft = _isVoice ? _voiceDraft : null;
      final library = _isVoice && draft == null ? _libraryNote : null;
      final bytes = draft == null ? null : await File(draft.path).readAsBytes();
      final attach = _isVoice
          ? GroupVoiceAttacher(
              client: ref.read(voiceNoteClientProvider),
              groupId: widget.groupId,
              recording: bytes,
              libraryNoteId: bytes == null ? library?.id : null,
            )
          : null;

      final title = _isVoice ? kVoiceAlarmTitle : _title.text;
      final result = await ref
          .read(scheduleRepositoryProvider)
          .planForGroup(
            groupId: widget.groupId,
            createdByUid: me,
            targets: targets,
            title: title,
            note: _note.text,
            wall: _wall(),
            attachVoice: attach?.call,
            knownBusy: _busy ?? const {},
          );
      if (draft != null) unawaited(_deleteQuietly(draft.path));

      // Tell each non-self recipient a plan was created for them — best-effort
      // and DELIBERATELY NOT awaited (a degraded network must not freeze the
      // sheet on something the Firestore writes above already made durable).
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
      // Worker verifies who was really busy and tells each of them. NOT
      // awaited (2026-09-28): the planner's answer is shown NOW, from what
      // the preview already verified, never after a network round trip.
      if (result.failed.isNotEmpty) {
        unawaited(
          ref
              .read(groupPlanReporterProvider)
              .reportBusy(
                groupId: widget.groupId,
                title: title.trim(),
                setCount: result.sent.length,
                failed: result.failed,
              ),
        );
      }

      if (!mounted) return;
      final message = groupPlanSentMessage(
        setCount: result.sent.length,
        skippedPast: result.skippedPast,
        skippedOther: result.skippedOther,
        busyNames: [
          for (final f in result.failed)
            if (_busy?.contains(f.uid) ?? false) names[f.uid] ?? 'A member',
        ],
        notSetNames: [
          for (final f in result.failed)
            if (!(_busy?.contains(f.uid) ?? false)) names[f.uid] ?? 'A member',
        ],
      );
      messenger.showSnackBar(SnackBar(content: Text(message)));
      Navigator.pop(context);
    } on VoiceNoteFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not plan: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
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
    if (picked != null) {
      setState(() => _date = picked);
      unawaited(_checkAvailability());
    }
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
    if (picked != null) {
      setState(() => _time = picked);
      unawaited(_checkAvailability());
    }
  }

  DateTime _wall() => DateTime.utc(
    _date!.year,
    _date!.month,
    _date!.day,
    _time!.hour,
    _time!.minute,
  );

  /// The Plan screen's glowing pill picker (F4), shared look.
  Widget _pickerButton({
    required Key key,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
  }) {
    return FieldGlow(
      borderRadius: Radii.pill,
      child: OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(Sizes.pickerButton),
          textStyle: context.text.titleMedium,
          side: BorderSide(color: context.colors.primary),
        ),
        icon: Icon(icon),
        label: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  InputBorder? _errorBorder() =>
      Theme.of(context).inputDecorationTheme.errorBorder;

  Widget _errorLine(String message) => Padding(
    padding: const EdgeInsets.only(top: Space.sm, left: Space.md),
    child: Text(
      message,
      key: ValueKey('error-$message'),
      style: context.text.bodySmall?.copyWith(color: context.colors.error),
    ),
  );

  /// Who gets it and who doesn't, once a date and time are picked.
  Widget _whoGetsIt(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    if (_date == null || _time == null) return const SizedBox.shrink();
    if (_checking) {
      return Text(
        'Checking who is free then…',
        key: const ValueKey('who-gets-it'),
        style: context.text.bodySmall?.copyWith(color: muted),
      );
    }
    final busy = _busy;
    final free = [
      for (final c in _recipients)
        if (!(busy?.contains(c.uid) ?? false)) _nameOf(c),
    ];
    final busyNames = [
      for (final c in _recipients)
        if (busy?.contains(c.uid) ?? false) _nameOf(c),
    ];
    return Column(
      key: const ValueKey('who-gets-it'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          free.isEmpty
              ? 'Nobody is free at that time.'
              : 'Rings for ${formatCount(context, free.length)}: '
                    '${free.join(', ')}.',
          style: context.text.bodyMedium,
        ),
        if (busyNames.isNotEmpty) ...[
          const SizedBox(height: Space.xs),
          Text(
            "Busy then, won't get it: ${busyNames.join(', ')}.",
            key: const ValueKey('busy-then'),
            // Attention as TEXT (§2.7 line work), not a form error.
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.tertiary,
            ),
          ),
        ],
        if (busy == null) ...[
          const SizedBox(height: Space.xs),
          Text(
            "Couldn't check who is busy. Anyone busy then is skipped when you "
            'send.',
            style: context.text.bodySmall?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final recipients = _recipients;
    final count = recipients.length;

    // Keep every member's profile warm, so names and zones are ready.
    for (final c in widget.candidates) {
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Plan for ${widget.groupName}',
              style: context.text.titleLarge,
            ),
            const SizedBox(height: Space.xs),
            Text(
              count == 0
                  ? "You can't plan for anyone in this group yet."
                  : _isVoice
                  ? 'Rings for $count ${count == 1 ? 'member' : 'members'}, '
                        'each at this time in their own local zone. Your '
                        'voice goes to the others, not to you.'
                  : 'Rings for $count ${count == 1 ? 'member' : 'members'} '
                        '(you included), each at this time in their own local '
                        'zone.',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Space.xl),
            Row(
              children: [
                Expanded(
                  child: _pickerButton(
                    key: const ValueKey('group-pick-date'),
                    onPressed: _saving ? null : _pickDate,
                    icon: AppIcons.date,
                    label: _date == null
                        ? 'Pick date'
                        : formatWallDate(context, _date!),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _pickerButton(
                    key: const ValueKey('group-pick-time'),
                    onPressed: _saving ? null : _pickTime,
                    icon: AppIcons.time,
                    label: _time == null
                        ? 'Pick time'
                        : formatTimeOfDay(context, _time!),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('everyones-time'),
                onPressed: _showMemberTimes,
                icon: const Icon(AppIcons.time),
                label: const Text("Everyone's time"),
              ),
            ),
            _whoGetsIt(context),
            const SizedBox(height: Space.xl),
            SegmentedButton<AlarmKind>(
              key: const ValueKey('group-alarm-kind'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: AlarmKind.voiceNote,
                  icon: Text(kVoiceNoteEmoji),
                  label: Text('Voice Note'),
                ),
                ButtonSegment(
                  value: AlarmKind.defaultAlarm,
                  icon: Text(kDefaultAlarmEmoji),
                  label: Text('Default Alarm'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: _saving
                  ? null
                  : (picked) => setState(() {
                      _kind = picked.first;
                      _nameError = false;
                      _voiceError = false;
                    }),
            ),
            const SizedBox(height: Space.xl),
            if (_isVoice) ...[
              if (_libraryNote case final note?)
                LibraryNoteChoice(
                  note: note,
                  enabled: !_saving,
                  onRemove: () {
                    if (mounted) setState(() => _libraryNote = null);
                  },
                )
              else ...[
                VoiceNoteRecorder(
                  key: const ValueKey('group-voice'),
                  recipientName: 'each member',
                  enabled: !_saving,
                  onChanged: (note) => setState(() {
                    _voiceDraft = note;
                    if (note != null) _voiceError = false;
                  }),
                ),
                if (_voiceDraft == null &&
                    (ref.watch(voiceLibraryProvider).value?.isNotEmpty ??
                        false))
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('group-choose-from-library'),
                      onPressed: _saving ? null : _chooseFromLibrary,
                      icon: const Icon(AppIcons.voiceLibrary),
                      label: const Text('Choose from library'),
                    ),
                  ),
              ],
              if (_voiceError) _errorLine(kVoiceNoteRequired),
            ] else ...[
              Text('Name of the Task', style: context.text.titleMedium),
              const SizedBox(height: Space.sm),
              FieldGlow(
                error: _nameError,
                child: TextField(
                  key: const ValueKey('group-task-name'),
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'What should everyone do?',
                    enabledBorder: _nameError ? _errorBorder() : null,
                    focusedBorder: _nameError ? _errorBorder() : null,
                  ),
                  onChanged: (_) {
                    if (_nameError) setState(() => _nameError = false);
                  },
                ),
              ),
              if (_nameError) _errorLine(kTaskNameRequired),
            ],
            const SizedBox(height: Space.xl),
            FieldGlow(
              child: TextField(
                key: const ValueKey('group-note'),
                controller: _note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
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
              key: const ValueKey('group-send'),
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

/// One timezone in "Everyone's time": the zone's current time and city, then
/// its members. Long lists collapse after [_collapsedLimit] names so a big
/// group stays scannable; busy members carry a "Busy" tag.
class _ZoneSection extends StatefulWidget {
  const _ZoneSection({required this.group});

  final ZoneGroup group;

  @override
  State<_ZoneSection> createState() => _ZoneSectionState();
}

class _ZoneSectionState extends State<_ZoneSection> {
  static const _collapsedLimit = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final muted = context.colors.onSurfaceVariant;
    final members = g.members;
    final shown = _expanded || members.length <= _collapsedLimit
        ? members
        : members.take(_collapsedLimit - 1).toList();
    final hidden = members.length - shown.length;
    final now = g.wallNow;

    return Padding(
      key: ValueKey('zone-${g.zone ?? 'unknown'}'),
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            now == null
                ? 'Time unknown'
                : '${formatWallTimeOfDay(context, now)}, '
                      '${formatWallDate(context, now)}',
            style: context.text.titleSmall,
          ),
          Text(
            [
              if (g.zone != null) zoneCityName(g.zone!),
              '${formatCount(context, members.length)} '
                  '${members.length == 1 ? 'member' : 'members'}',
            ].join(' · '),
            style: context.text.labelSmall?.copyWith(color: muted),
          ),
          const SizedBox(height: Space.xs),
          for (final m in shown)
            Padding(
              key: ValueKey('member-time-${m.uid}'),
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      m.name,
                      style: context.text.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (m.busy)
                    Text(
                      'Busy',
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.tertiary,
                      ),
                    ),
                ],
              ),
            ),
          if (hidden > 0)
            TextButton(
              key: ValueKey('zone-more-${g.zone ?? 'unknown'}'),
              onPressed: () => setState(() => _expanded = true),
              child: Text('+${formatCount(context, hidden)} more'),
            ),
        ],
      ),
    );
  }
}

/// What the planner reads the moment a group plan is sent (2026-09-28): who
/// got it, who was busy (as the before-Send preview verified) and who could
/// not be set for another reason. Pure, so every branch is tested.
String groupPlanSentMessage({
  required int setCount,
  required int skippedPast,
  required int skippedOther,
  required List<String> busyNames,
  required List<String> notSetNames,
}) {
  final n = setCount;
  if (n == 0 && skippedPast > 0 && skippedOther == 0) {
    return 'That time has already passed. Pick a later time.';
  }
  if (n == 0 && busyNames.isEmpty && notSetNames.isEmpty) {
    return 'No one could be planned for right now.';
  }
  final parts = <String>[
    n == 0
        ? 'No alarm was set.'
        : 'Alarm set for $n ${n == 1 ? 'member' : 'members'}.',
    if (busyNames.isNotEmpty) 'Busy at that time: ${busyNames.join(', ')}.',
    if (notSetNames.isNotEmpty) "Couldn't set for: ${notSetNames.join(', ')}.",
  ];
  final unnamed =
      skippedPast + skippedOther - busyNames.length - notSetNames.length;
  if (parts.length == 1 && unnamed > 0) {
    return '${parts.single.substring(0, parts.single.length - 1)}'
        ' · $unnamed skipped.';
  }
  return parts.join(' ');
}
