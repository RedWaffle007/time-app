import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/quiet_hours.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/field_glow.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/warning_panel.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../../groups/domain/planner_grant.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../plan_requests/application/plan_request_providers.dart';
import '../../plan_requests/domain/plan_request.dart';
import '../../social/application/social_providers.dart';
import '../../voice_notes/application/voice_note_providers.dart';
import '../../voice_notes/application/voice_note_cache.dart';
import '../../voice_notes/data/voice_note_client.dart';
import '../../voice_notes/domain/voice_library_note.dart';
import '../../voice_notes/presentation/voice_library_picker.dart';
import '../../voice_notes/presentation/voice_library_screen.dart';
import '../../voice_notes/presentation/voice_note_recorder.dart';
import '../application/schedule_clash.dart';
import '../application/schedule_providers.dart';
import '../domain/schedule_item.dart';

/// The two kinds of alarm (F4). A self-plan is always [defaultAlarm].
enum AlarmKind { voiceNote, defaultAlarm }

/// The fixed title a voice alarm is stored with: it has no name field (F4) —
/// the recording is the message — but the model and rules need a title.
const kVoiceAlarmTitle = 'Voice alarm';

/// Shown in red under the task name when Send is tapped with it empty (F4).
const kTaskNameRequired = 'Please write task name. It is mandatory.';

/// Shown when Voice Note is chosen but nothing was recorded.
const kVoiceNoteRequired = 'Please record a voice note.';

/// Planner picks a target they may plan for and creates a timetable item IN THE
/// TARGET'S LOCAL TIME.
class ScheduleBuilderScreen extends ConsumerStatefulWidget {
  const ScheduleBuilderScreen({
    super.key,
    this.initialDate,
    this.initialTargetUid,
    this.initialGroupId,
    this.initialIsSelf = false,
    this.initialTitle,
    this.initialTime,
    this.planRequest,
  });

  /// Item 5b (2026-09-27): fulfilling a friend's Request Plan. The builder
  /// opens on the requester, their requested date and time (LOCKED — the
  /// request is for that minute), the task and the note; the friend chooses
  /// Default Alarm or Voice Note as usual. Send saves the plan AND completes
  /// the request in one write (which is what stops the reminders), then
  /// closes the screen.
  final PlanRequest? planRequest;

  /// A date to open with, seeded by the calendar when a user plans from a
  /// tapped day (`Routes.calendarNew`). Null everywhere else, and null behaves
  /// exactly as this screen always has — no date chosen until the user picks
  /// one.
  ///
  /// **The date only.** Not a time: a date is what the user actually indicated
  /// by tapping a cell, and pre-filling a time they never chose would let an
  /// alarm be sent for an hour nobody selected. `_canSave` still
  /// requires a time, so the form cannot be submitted straight through.
  ///
  /// This one optional parameter is the whole of the calendar's integration
  /// with the builder. The calendar deliberately has no create flow of its own.
  final DateTime? initialDate;

  /// Voice-flow seeds (S6). The Plan voice flow picks the target FIRST (its own
  /// person-picker), captures speech, parses it, and pushes this screen with the
  /// target already chosen and whatever the parser read pre-filled. All are
  /// optional and null everywhere else; the form is otherwise unchanged, and
  /// `_canSave` still requires a title, date and time, so an incomplete voice
  /// parse cannot submit straight through — it lands here for confirm/edit.
  final String? initialTargetUid;
  final String? initialGroupId;
  final bool initialIsSelf;
  final String? initialTitle;
  final TimeOfDay? initialTime;

  @override
  ConsumerState<ScheduleBuilderScreen> createState() =>
      _ScheduleBuilderScreenState();
}

class _ScheduleBuilderScreenState extends ConsumerState<ScheduleBuilderScreen> {
  String? _targetUid; // selected target
  String? _groupId; // group the grant came from (null when planning for self)
  bool _isSelf = false; // selected target is me → skip queue, no group

  /// The person list is shown only until someone is picked (or while the
  /// planner is changing their pick). Once chosen it collapses to one row, so
  /// the planning fields start at the top instead of below a long list.
  bool _changingTarget = false;
  bool get _showTargetList => _targetUid == null || _changingTarget;
  final _scrollController = ScrollController();

  /// No double-booking (Batch G item 4): the (target, minute) last checked,
  /// and whether that exact minute is already held by a live plan. Only the
  /// latest check may set [_clashBlocked]; while it is set, Send is off and the
  /// red line under the pickers says why.
  String? _clashKey;
  bool _clashBlocked = false;
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _saving = false;

  /// Voice Note or Default Alarm (F4). Self-plans are always a default alarm.
  AlarmKind _kind = AlarmKind.defaultAlarm;
  bool get _isVoice => !_isSelf && _kind == AlarmKind.voiceNote;

  /// Validation shown after Send was tapped (F4) — never before.
  bool _nameError = false;
  bool _voiceError = false;

  /// The recorded-but-unsent voice note for someone else's alarm (item 32b).
  RecordedVoiceNote? _voiceDraft;

  /// A note chosen from the library instead of recording (32d); the Worker
  /// copies it onto the plan at Send.
  VoiceLibraryNote? _libraryNote;
  bool _libraryPlaying = false;
  StreamSubscription<void>? _libraryDone;

  /// Bumped to give the recorder a fresh state (after a save or a target
  /// change) — the recorder owns its phase; the builder only resets it.
  int _voiceRecorderGen = 0;

  bool get _fromRequest => widget.planRequest != null;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    final request = widget.planRequest;
    if (request != null) {
      final local = wallNowIn(request.timezone, nowUtc: request.windowStartUtc);
      _targetUid = request.requesterUid;
      _groupId = '';
      _isSelf = false;
      _date = DateTime(local.year, local.month, local.day);
      _time = TimeOfDay(hour: local.hour, minute: local.minute);
      _titleController.text = request.title ?? '';
      _noteController.text = request.message ?? '';
      return;
    }
    // Voice-flow seeds (S6). The target was chosen in the voice person-picker,
    // so honour it and its group here; the tiles below render it selected
    // because `_targetUid`/`_isSelf` already match.
    _isSelf = widget.initialIsSelf;
    _targetUid = widget.initialTargetUid;
    _groupId = widget.initialGroupId;
    _time = widget.initialTime;
    if (widget.initialTitle != null) {
      _titleController.text = widget.initialTitle!;
    }
  }

  @override
  void dispose() {
    _libraryDone?.cancel();
    _scrollController.dispose();
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  /// The selected person's home zone (the zone the plan is built in), or
  /// null while their profile is loading.
  String? get _targetZone => _targetUid == null
      ? null
      : ref.read(profileByUidProvider(_targetUid!)).value?.homeTimezone;

  /// What the clock reads for the selected person right now (Batch G2): the
  /// pickers open on THEIR day and time, since the plan is built in their
  /// zone. Falls back to this device's time until the zone is known.
  DateTime _nowThere() {
    final zone = _targetZone;
    if (zone != null && zone.isNotEmpty) return wallNowIn(zone);
    final now = clock.now();
    return DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  Future<void> _pickDate() async {
    final nowThere = _nowThere();
    final today = DateTime(nowThere.year, nowThere.month, nowThere.day);
    var firstDate = today.subtract(const Duration(days: 1));
    var lastDate = today.add(const Duration(days: 365));

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
      initialDate: selected ?? today,
      currentDate: today,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final nowThere = _nowThere();
    final picked = await showTimePicker(
      context: context,
      initialTime:
          _time ?? TimeOfDay(hour: nowThere.hour, minute: nowThere.minute),
    );
    if (picked != null) setState(() => _time = picked);
  }

  /// Checks the chosen minute (item 4) and blocks Send on a literal clash. A
  /// read that still fails after the checker's retries blocks nothing here —
  /// the rules refuse a real clash at save time anyway.
  Future<ClashResult> _checkClash({
    required String key,
    required String targetUid,
    required DateTime instantUtc,
  }) async {
    final result = await ref
        .read(scheduleClashCheckerProvider)
        .check(targetUid: targetUid, instantUtc: instantUtc);
    if (mounted && _clashKey == key) {
      setState(() => _clashBlocked = result == ClashResult.clash);
    }
    return result;
  }

  /// The red line (item 4). Self-plans say "You"; others name the person.
  String _clashMessage(String? name) => _isSelf
      ? 'You already have a plan scheduled for this time. '
            'Please select a different time.'
      : '${name ?? 'They'} already has a plan scheduled for this time. '
            'Please select a different time.';

  /// Send is enabled once WHO and WHEN are chosen; what to send is checked
  /// on tap, so the missing piece can be named in red (F4).
  bool get _canSend =>
      _targetUid != null &&
      _date != null &&
      _time != null &&
      !_saving &&
      !_clashBlocked;

  /// Whether the alarm is complete; marks what is missing when it is not.
  bool _validate() {
    final nameMissing = !_isVoice && _titleController.text.trim().isEmpty;
    final voiceMissing =
        _isVoice && _voiceDraft == null && _libraryNote == null;
    setState(() {
      _nameError = nameMissing;
      _voiceError = voiceMissing;
    });
    return !nameMissing && !voiceMissing;
  }

  Future<void> _save(String timezone) async {
    final me = ref.read(authRepositoryProvider).currentUser;
    if (me == null || _targetUid == null) return;
    if (!_isSelf && _groupId == null) {
      return; // planning for others needs a group
    }
    if (!_validate()) return;

    final wall = _wall();
    final instantUtc = resolveWallTimeToUtc(wall, timezone);

    // No planning in the past — the real chokepoint for it, not the date
    // picker's `firstDate`. The picker guard only runs when the user opens the
    // picker; a voice-parsed draft (or a calendar seed) pre-fills the fields
    // directly and never touches it, so a spoken day/time that has already gone
    // would otherwise create a plan in the past. Checked on the resolved INSTANT
    // in the target's zone, so it is correct across timezones, and it covers
    // self, planner, manual and voice alike.
    if (!instantUtc.isAfter(DateTime.now().toUtc())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That time has already passed. Pick a later time.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    // A last check right before saving (item 4): the minute may have been
    // taken since it was first checked. The rules are the real guard; this
    // just avoids uploading a voice note for a plan that cannot land.
    final key = '${_targetUid!}|${instantUtc.millisecondsSinceEpoch}';
    _clashKey = key;
    final preCheck = await _checkClash(
      key: key,
      targetUid: _targetUid!,
      instantUtc: instantUtc,
    );
    if (!mounted) return;
    if (preCheck == ClashResult.clash) {
      setState(() => _saving = false);
      return;
    }
    try {
      // A voice note is uploaded FIRST, under an id minted for this plan; the
      // Worker checks the audio and the rules then accept the item only with
      // the metadata the Worker recorded. A failed upload saves nothing.
      final repository = ref.read(scheduleRepositoryProvider);
      final draft = _isVoice ? _voiceDraft : null;
      final fromLibrary = _isVoice && draft == null ? _libraryNote : null;
      String? preparedId;
      VoiceNoteMeta? voiceNote;
      if (draft != null || fromLibrary != null) {
        preparedId = repository.newItemId(_targetUid!);
        final client = ref.read(voiceNoteClientProvider);
        final groupId = (_groupId ?? '').isEmpty ? null : _groupId;
        try {
          voiceNote = fromLibrary != null
              ? await client.attachFromLibrary(
                  noteId: fromLibrary.id,
                  targetUid: _targetUid!,
                  itemId: preparedId,
                  groupId: groupId,
                )
              : await client.upload(
                  bytes: await File(draft!.path).readAsBytes(),
                  targetUid: _targetUid!,
                  itemId: preparedId,
                  groupId: groupId,
                );
        } on VoiceNoteFailure catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(e.message)));
          }
          return;
        } on Object {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(voiceNoteErrorMessage(null))),
            );
          }
          return;
        }
      }
      final request = widget.planRequest;
      final itemId = request != null
          ? await ref
                .read(planRequestRepositoryProvider)
                .fulfill(
                  request: request,
                  plannerUid: me.uid,
                  itemId: preparedId,
                  voiceNote: voiceNote,
                  title: voiceNote != null
                      ? kVoiceAlarmTitle
                      : _titleController.text,
                  note: _noteController.text,
                  wall: wall,
                  durationMinutes: request.durationMinutes,
                  finishFlexibleRequest: true,
                )
          : await repository.createItem(
              itemId: preparedId,
              voiceNote: voiceNote,
              targetUid: _targetUid!,
              createdByUid: me.uid,
              groupId: _isSelf ? null : _groupId,
              title: voiceNote != null
                  ? kVoiceAlarmTitle
                  : _titleController.text,
              note: _noteController.text,
              wall: wall,
              timezone: timezone,
              // F2 (2026-09-26): there is no approval step — every alarm rings
              // directly; the rules re-check the planning permission live.
              status: ScheduleItemStatus.approved,
            );
      // The draft was uploaded and is now the plan's; drop the local copy.
      if (draft != null) unawaited(_deleteQuietly(draft.path));
      // Notify the target that a plan was created for them. Self-planned items
      // have no one else to tell (the Worker would skip them anyway).
      NotificationDeliveryResult? delivery;
      if (!_isSelf) {
        delivery = await ref
            .read(notificationEventNotifierProvider)
            .notifyConfirmed(
              event: NotifyEvent.created,
              targetUid: _targetUid!,
              itemId: itemId,
            );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            delivery != null && !delivery.delivered
                ? 'Plan saved, but the notification was not delivered '
                      '(${delivery.reason}). Ask your friend to open or update '
                      'Checkmate, then try again.'
                : _isSelf
                ? 'Added to your schedule.'
                : voiceNote != null
                ? 'Voice alarm sent.'
                : 'Alarm sent.',
          ),
        ),
      );
      // A fulfilled request is done — back to it (it now reads "set").
      if (request != null) {
        Navigator.of(context).pop();
        return;
      }
      // Reset for the next item, keep the same target.
      setState(() {
        _titleController.clear();
        _noteController.clear();
        _date = null;
        _time = null;
        _voiceDraft = null;
        _libraryNote = null;
        _voiceRecorderGen++;
        _nameError = false;
        _voiceError = false;
      });
    } catch (e) {
      // Refused by the rules? If it is because the minute was taken in the
      // meantime (item 4), say so in the red line instead of a raw error.
      final clash =
          e is FirebaseException &&
          e.code == 'permission-denied' &&
          await _checkClash(
                key: key,
                targetUid: _targetUid!,
                instantUtc: instantUtc,
              ) ==
              ClashResult.clash;
      if (mounted && !clash) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetsAsync = ref.watch(effectivePlanningTargetsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule Builder')),
      // No empty-state: "Myself" is always an available target, so the form
      // always renders — a solo user with zero grants can still plan.
      body: AsyncView<List<PlannerGrant>>(
        value: targetsAsync,
        onRetry: () {
          ref.invalidate(myFriendshipsProvider);
        },
        builder: (context, grants) => _buildForm(grants),
      ),
    );
  }

  Widget _buildForm(List<PlannerGrant> grants) {
    // Resolve the selected target's profile (name + timezone).
    final selectedProfile = _targetUid == null
        ? null
        : ref.watch(profileByUidProvider(_targetUid!)).value;
    final timezone = selectedProfile?.homeTimezone;

    // No double-booking (item 4): once target, date and time are known, that
    // exact minute is checked in the target's own zone — self-plans too. A
    // clash turns Send off and shows the red line under the pickers.
    if (_targetUid != null &&
        _date != null &&
        _time != null &&
        timezone != null) {
      final targetUid = _targetUid!;
      final instantUtc = resolveWallTimeToUtc(_wall(), timezone);
      final key = '$targetUid|${instantUtc.millisecondsSinceEpoch}';
      if (key != _clashKey) {
        _clashKey = key;
        _clashBlocked = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _checkClash(key: key, targetUid: targetUid, instantUtc: instantUtc);
        });
      }
    } else {
      _clashKey = null;
      _clashBlocked = false;
    }

    return ListView(
      controller: _scrollController,
      padding: Space.screenListSafe(context),
      children: [
        // Target picker. "Myself" is always first, then anyone who granted you.
        // After a pick it collapses to the chosen person + Change.
        const SectionHeader('Plan for'),
        if (_showTargetList) ...[
          _selfTile(),
          for (final grant in grants) _targetTile(grant),
        ] else
          _chosenTargetTile(selectedProfile),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isSelf
                        ? "You're building in your local time: $timezone."
                        : "You're building in "
                              '${possessive(selectedProfile?.name)} local time'
                              ': $timezone.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  if (!_isSelf) TimeThereLine(timezone: timezone),
                ],
              ),
            ),
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: _pickerButton(
                  key: const ValueKey('pick-date'),
                  onPressed: _fromRequest ? null : _pickDate,
                  icon: AppIcons.date,
                  label: _date == null
                      ? 'Pick date'
                      : formatWallDate(context, _date!),
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: _pickerButton(
                  key: const ValueKey('pick-time'),
                  onPressed: _fromRequest ? null : _pickTime,
                  icon: AppIcons.time,
                  label: _time == null
                      ? 'Pick time'
                      : formatTimeOfDay(context, _time!),
                ),
              ),
            ],
          ),
          if (_fromRequest)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                'Requested for this exact time.',
                key: const ValueKey('plan-request-locked'),
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          if (_clashBlocked) _errorLine(_clashMessage(selectedProfile?.name)),
          // Voice notes are for someone else: a self-plan is a default alarm
          // and shows no choice (F4).
          if (!_isSelf) ...[
            const SizedBox(height: Space.xl),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AlarmKind>(
                key: const ValueKey('alarm-kind'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: AlarmKind.voiceNote,
                    icon: Icon(AppIcons.voiceNote),
                    label: Text('Voice Note'),
                  ),
                  ButtonSegment(
                    value: AlarmKind.defaultAlarm,
                    icon: Icon(AppIcons.defaultAlarm),
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
            ),
          ],
          const SizedBox(height: Space.xl),
          if (_isVoice) ...[
            if (_libraryNote case final note?)
              _libraryChoice(note)
            else ...[
              VoiceNoteRecorder(
                key: ValueKey('voice-$_targetUid-$_voiceRecorderGen'),
                recipientName: selectedProfile?.name ?? 'their',
                enabled: !_saving,
                onChanged: (note) => setState(() {
                  _voiceDraft = note;
                  if (note != null) _voiceError = false;
                }),
              ),
              // Reuse a saved note instead (32d) — offered while nothing is
              // recorded, and only once the library has something in it.
              if (_voiceDraft == null &&
                  (ref.watch(voiceLibraryProvider).value?.isNotEmpty ?? false))
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('choose-from-library'),
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
                key: const ValueKey('task-name'),
                controller: _titleController,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'What should they do?',
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
              key: const ValueKey('note'),
              controller: _noteController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ),
          if (timezone != null && _date != null && _time != null) ...[
            const SizedBox(height: Space.lg),
            Text(
              'Fires at: ${_previewLocal(context, timezone)}  ($timezone)',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
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
            key: const ValueKey('plan-send'),
            onPressed: (_canSend && timezone != null)
                ? () => _save(timezone)
                : null,
            child: _saving
                ? const SizedBox(
                    height: Sizes.buttonSpinner,
                    width: Sizes.buttonSpinner,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isSelf ? 'Add to my schedule' : 'Send'),
          ),
        ],
      ],
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

  Future<void> _stopLibraryPreview() async {
    if (!_libraryPlaying) return;
    await ref.read(voicePlayerProvider).stop();
    if (mounted) setState(() => _libraryPlaying = false);
  }

  Future<void> _toggleLibraryPreview(VoiceLibraryNote note) async {
    if (_libraryPlaying) return _stopLibraryPreview();
    final player = ref.read(voicePlayerProvider);
    try {
      final path = await ref.read(voiceNoteCacheProvider).ensureLibrary(note);
      _libraryDone?.cancel();
      _libraryDone = player.completed.listen((_) {
        if (mounted) setState(() => _libraryPlaying = false);
      });
      await player.play(path);
      if (mounted) setState(() => _libraryPlaying = true);
    } on VoiceNoteFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// The chosen library note, with a preview and the way back to recording.
  Widget _libraryChoice(VoiceLibraryNote note) {
    return Card(
      key: const ValueKey('library-choice'),
      child: ListTile(
        leading: const Icon(AppIcons.voiceLibrary),
        title: Text(
          voiceNoteLabel(context, note),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'From your library · ${formatVoiceLength(note.length)} · '
          'plays ${voicePlaysFor(note.length)} times',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('library-choice-play'),
              tooltip: _libraryPlaying ? 'Stop' : 'Play',
              iconSize: Sizes.voiceChoiceIcon,
              constraints: const BoxConstraints.tightFor(
                width: Sizes.voiceChoiceButton,
                height: Sizes.voiceChoiceButton,
              ),
              onPressed: _saving ? null : () => _toggleLibraryPreview(note),
              icon: Icon(
                _libraryPlaying
                    ? AppIcons.voiceNoteStopPlaying
                    : AppIcons.voiceNotePlay,
              ),
            ),
            IconButton(
              key: const ValueKey('library-choice-remove'),
              tooltip: 'Record instead',
              iconSize: Sizes.voiceChoiceIcon,
              constraints: const BoxConstraints.tightFor(
                width: Sizes.voiceChoiceButton,
                height: Sizes.voiceChoiceButton,
              ),
              onPressed: _saving
                  ? null
                  : () async {
                      await _stopLibraryPreview();
                      if (mounted) setState(() => _libraryNote = null);
                    },
              icon: const Icon(AppIcons.voiceNoteDiscard),
            ),
          ],
        ),
      ),
    );
  }

  /// Pick date / Pick time: taller, `titleMedium`, with the field glow (F4).
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

  /// The theme's own form-error border, applied while the error line shows
  /// (the error text sits outside the glow, so `errorText` is not used).
  InputBorder? _errorBorder() =>
      Theme.of(context).inputDecorationTheme.errorBorder;

  /// A red form-validation line (§2.5), outside the glow so the halo hugs the
  /// field alone.
  Widget _errorLine(String message) => Padding(
    padding: const EdgeInsets.only(top: Space.sm, left: Space.md),
    child: Text(
      message,
      key: ValueKey('error-$message'),
      style: context.text.bodySmall?.copyWith(color: context.colors.error),
    ),
  );

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
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
        onTap: () => _choose(() {
          _isSelf = true;
          _kind = AlarmKind.defaultAlarm;
          _voiceError = false;
          _targetUid = me.uid;
          _groupId = null;
          _voiceDraft = null;
          _libraryNote = null;
          _voiceRecorderGen++;
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
        // Never the raw uid, even for the few ms before the profile resolves.
        title: Text(profile?.name ?? kProfileNameLoading),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        trailing: selected ? const Icon(AppIcons.selected) : null,
        onTap: () => _choose(() {
          _isSelf = false;
          _targetUid = grant.targetUid;
          _groupId = grant.groupId;
          _voiceDraft = null;
          _libraryNote = null;
          _voiceRecorderGen++;
        }),
      ),
    );
  }

  /// Apply a pick, collapse the list, and bring the planning fields to the
  /// top — the planner may have scrolled down a long list to reach the person.
  void _choose(VoidCallback pick) {
    setState(() {
      pick();
      _changingTarget = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  /// The collapsed picker: who this plan is for, and the way back to the list.
  Widget _chosenTargetTile(UserProfile? profile) {
    final name = profile == null
        ? (_isSelf ? 'Myself' : kProfileNameLoading)
        : _isSelf
        ? '${profile.name} (myself)'
        : profile.name;
    return Card(
      key: const ValueKey('plan-target-chosen'),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: const Icon(AppIcons.person),
        title: Text(name),
        subtitle: profile == null ? null : Text(profile.homeTimezone),
        // A request names who it is for: nothing to change (item 5b).
        trailing: _fromRequest
            ? null
            : TextButton(
                key: const ValueKey('plan-target-change'),
                onPressed: () => setState(() => _changingTarget = true),
                child: const Text('Change'),
              ),
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
      '${_isSelf ? 'You can still add it.' : 'You can still send it — it will ring at that time.'}',
    );
  }

  /// Non-blocking notice when the chosen wall time is a DST gap/overlap in the
  /// target's zone, so the planner knows which instant will actually be used.
  Widget _dstBanner(String timezone) {
    final res = resolveWall(_wall(), timezone);
    final actual = formatInstant(context, res.utc, timezone);
    final text = switch (res.anomaly) {
      DstAnomaly.none => null,
      DstAnomaly.skipped =>
        "That clock time doesn't exist on this date: "
            "clocks spring forward. It'll fire at $actual instead.",
      DstAnomaly.ambiguous =>
        'That clock time happens twice on this date: '
            'clocks fall back. It\'ll use the first: $actual.',
    };
    return text == null ? const SizedBox.shrink() : WarningPanel(text);
  }
}

/// "{Name}'s" — the target's name as a possessive (F4 fixed "You're building
/// in Sam local time"). Unknown name → "their".
String possessive(String? name) {
  final n = name?.trim() ?? '';
  return n.isEmpty ? 'their' : "$n's";
}

/// "It's now 9:30 PM, Sat, Sep 26, 2026 there." (Batch G2) — the recipient's
/// current time and date, through the one format helper, so the planner sees
/// at a glance whether it is evening (or still yesterday) for them. Refreshes
/// every 20 s; its own widget so the refresh rebuilds only this line.
class TimeThereLine extends StatefulWidget {
  const TimeThereLine({super.key, required this.timezone});

  final String timezone;

  @override
  State<TimeThereLine> createState() => _TimeThereLineState();
}

class _TimeThereLineState extends State<TimeThereLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nowUtc = clock.now().toUtc();
    final there = wallNowIn(widget.timezone, nowUtc: nowUtc);
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Text(
        "It's now ${formatWallTimeOfDay(context, there)}, "
        '${formatWallDate(context, there)} there.',
        key: const ValueKey('time-there'),
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
