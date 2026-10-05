import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../applock/application/app_lock_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../../celebrations/application/celebration_providers.dart';
import '../../celebrations/domain/completion_celebration.dart';
import '../../outcomes/application/outcome_feedback.dart';
import '../../outcomes/presentation/reply_note.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../voice_notes/application/voice_note_cache.dart';
import '../../voice_notes/application/voice_note_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/missed_alarms.dart';
import '../application/reminder_policy.dart';
import '../application/reminder_providers.dart';
import '../domain/reminder.dart';

/// How an alarm on a card was answered in this pop-up.
enum MissedCardAnswer { played, heard, done, skipped }

/// **The Missed pop-up** (2026-10-05, user-directed; UI-RULES §6.16).
///
/// Every alarm of mine that rang, is unanswered and is not ringing now
/// ([missedAlarms]) waits here, in two swipeable decks: voice notes first,
/// then default alarms. Each card is answered on its own; answering is what
/// stops that alarm's repeats. ✕ closes it without answering anything. It
/// opens on every app open while anything waits, whenever a new one joins,
/// and from the 🔔 Missed button ([missedPopupTriggerProvider]); never above
/// the app lock, and never while an alarm rings.
class MissedAlarmReviewHost extends ConsumerStatefulWidget {
  const MissedAlarmReviewHost({
    super.key,
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  ConsumerState<MissedAlarmReviewHost> createState() =>
      _MissedAlarmReviewHostState();
}

class _MissedAlarmReviewHostState extends ConsumerState<MissedAlarmReviewHost>
    with WidgetsBindingObserver {
  /// How often the pop-up checks whether an alarm is ringing (it hides then).
  static const _ringingPoll = Duration(seconds: 3);

  bool _open = true;
  bool _onAlarmDeck = false;

  /// The cards of this opening, in order. Answered ones stay (Played ✓ and
  /// Send note) until the pop-up closes.
  final _voiceIds = <String>[];
  final _alarmIds = <String>[];

  /// Every id shown since the last close: a NEW one reopens the pop-up.
  final _seen = <String>{};
  final _known = <String, ScheduleItem>{};
  final _answers = <String, MissedCardAnswer>{};
  final _noteSent = <String>{};

  /// The card being worked on, and what it is doing.
  String? _busyId;
  bool _loading = false;
  bool _playing = false;
  bool _updating = false;

  Set<String> _ringing = const {};
  Timer? _poll;
  int _trigger = 0;
  int _voicePage = 0;
  int _alarmPage = 0;
  final _voicePager = PageController();
  final _alarmPager = PageController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(_ringingPoll, (_) => unawaited(_checkRinging()));
    unawaited(_checkRinging());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _voicePager.dispose();
    _alarmPager.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Every app open shows what still waits, from a fresh deck.
    if (state == AppLifecycleState.resumed) _reopen();
  }

  Future<void> _checkRinging() async {
    final ids = (await ref.read(alarmSoundProvider).ringingItems()).toSet();
    if (!mounted) return;
    if (ids.length != _ringing.length || !ids.containsAll(_ringing)) {
      setState(() => _ringing = ids);
    }
  }

  void _reopen() {
    if (!mounted) return;
    setState(() {
      _open = true;
      _onAlarmDeck = false;
      _voiceIds.clear();
      _alarmIds.clear();
      _answers.clear();
      _seen.clear();
      _voicePage = 0;
      _alarmPage = 0;
    });
    _rewindPagers();
  }

  /// A fresh deck starts at its first card.
  void _rewindPagers() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final pager in [_voicePager, _alarmPager]) {
        if (pager.hasClients) pager.jumpToPage(0);
      }
    });
  }

  void _close() {
    setState(() => _open = false);
  }

  /// Brings this opening's decks up to date with [missed]: new alarms join
  /// at the end (and reopen a closed pop-up); answered ones stay put.
  void _absorb(MissedAlarms missed, List<ScheduleItem> items) {
    for (final item in items) {
      _known[item.id] = item;
    }
    var added = false;
    for (final item in missed.voice) {
      if (!_voiceIds.contains(item.id)) {
        _voiceIds.add(item.id);
        added |= _seen.add(item.id);
      }
    }
    for (final item in missed.alarms) {
      if (!_alarmIds.contains(item.id)) {
        _alarmIds.add(item.id);
        added |= _seen.add(item.id);
      }
    }
    if (added) _open = true;
  }

  bool _answered(String id) =>
      _answers.containsKey(id) || _known[id]?.outcome != null;

  Future<void> _play(ScheduleItem item) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = item.id;
      _loading = true;
    });
    try {
      final path = await ref.read(voiceNoteCacheProvider).ensure(item);
      final player = ref.read(voicePlayerProvider);
      final finished = player.completed.first;
      await player.play(path);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = true;
      });
      // The card stays until the note ends (device report 2026-10-05).
      // Bounded, in case the end is never reported.
      await finished.timeout(
        Duration(milliseconds: item.voiceNote?.durationMs ?? 25000) +
            const Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busyId = null;
          _loading = false;
          _playing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't load the voice note. Try again."),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _playing = false);
    await _answer(item, MissedCardAnswer.played);
  }

  /// Records [answer] for [item]: Played / Heard / Done count as Done to the
  /// planner, Skipped as Skipped. A full play or a Done closes to confetti.
  Future<void> _answer(ScheduleItem item, MissedCardAnswer answer) async {
    setState(() {
      _busyId = item.id;
      _updating = true;
    });
    final done = answer != MissedCardAnswer.skipped;
    try {
      final committed = await atLeast(
        ref.read(missedAlarmServiceProvider).answer(item, done: done),
      );
      if (!mounted) return;
      setState(() => _answers[item.id] = answer);
      if (committed &&
          (answer == MissedCardAnswer.played ||
              answer == MissedCardAnswer.done)) {
        ref
            .read(committedCelebrationProvider.notifier)
            .celebrate(
              CompletionCelebration.committed(
                targetUid: item.targetUid,
                itemId: item.id,
                plannerUid: item.createdByUid,
              ),
            );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't save. Check your connection and try again.",
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _updating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(missedAlarmServiceProvider);
    final lock = ref.watch(appLockControllerProvider);
    final uid = ref.watch(currentUidProvider);
    final items = ref.watch(allItemsAsTargetProvider).value ?? const [];
    final trigger = ref.watch(missedPopupTriggerProvider);
    if (trigger != _trigger) {
      // The 🔔 Missed button: a fresh deck of what still waits.
      _trigger = trigger;
      _open = true;
      _onAlarmDeck = false;
      _voiceIds.clear();
      _alarmIds.clear();
      _answers.clear();
      _voicePage = 0;
      _alarmPage = 0;
      _rewindPagers();
    }
    return ListenableBuilder(
      listenable: Listenable.merge([service, lock]),
      builder: (context, _) {
        final missed = missedAlarms(
          items: items,
          uid: uid,
          nowUtc: DateTime.now().toUtc(),
          ringingIds: _ringing,
          timedOutIds: {for (final r in service.reviews) r.item.id},
        );
        _absorb(missed, items);
        final hasCards = _voiceIds.isNotEmpty || _alarmIds.isNotEmpty;
        final visible =
            widget.enabled &&
            !lock.isLocked &&
            _open &&
            _ringing.isEmpty &&
            hasCards;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              excluding: visible,
              child: IgnorePointer(ignoring: visible, child: widget.child),
            ),
            if (visible)
              Positioned.fill(
                // Its own navigator (2026-10-05): this pop-up sits above the
                // router, so a dialog it opens (Send note) needs a navigator
                // of its own to open ON TOP of it, and its ✕ tooltip an
                // overlay. One page, rebuilt in place, so the deck keeps its
                // state. No hero animations: the app's hero controller
                // belongs to the router's navigator and cannot be shared.
                child: HeroControllerScope.none(
                child: Navigator(
                  pages: [
                    MaterialPage<void>(
                      key: const ValueKey('missed-popup-page'),
                      child: ColoredBox(
                  color: context.colors.scrim.withValues(alpha: 0.55),
                  child: SafeArea(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: Sizes.modalMaxWidth,
                          maxHeight:
                              MediaQuery.sizeOf(context).height *
                              Sizes.modalMaxHeightFraction,
                        ),
                        child: Card(
                          key: const ValueKey('missed-popup'),
                          margin: Space.screenForm,
                          child: Padding(
                            padding: Space.cardPadding,
                            child: _deck(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                    ),
                  ],
                  onDidRemovePage: (_) {},
                ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _deck(BuildContext context) {
    final voiceDeck = _voiceIds.isNotEmpty && !_onAlarmDeck;
    final ids = voiceDeck ? _voiceIds : _alarmIds;
    final pager = voiceDeck ? _voicePager : _alarmPager;
    final page = (voiceDeck ? _voicePage : _alarmPage).clamp(0, ids.length - 1);
    final allAnswered = ids.every(_answered);
    final nextDeck = voiceDeck && _alarmIds.isNotEmpty;
    return Column(
      key: ValueKey(voiceDeck ? 'missed-voice-deck' : 'missed-alarm-deck'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                voiceDeck ? 'Missed voice notes' : 'Missed alarms',
                style: context.text.titleLarge,
              ),
            ),
            IconButton(
              key: const ValueKey('missed-close'),
              tooltip: 'Close',
              icon: const Icon(AppIcons.close),
              onPressed: _close,
            ),
          ],
        ),
        Text(
          '${page + 1} of ${ids.length}',
          key: const ValueKey('missed-position'),
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Space.md),
        Flexible(
          child: SizedBox(
            height: Sizes.missedCardHeight,
            child: PageView(
              key: const ValueKey('missed-pages'),
              controller: pager,
              onPageChanged: (i) => setState(() {
                if (voiceDeck) {
                  _voicePage = i;
                } else {
                  _alarmPage = i;
                }
              }),
              children: [
                for (final id in ids)
                  if (_known[id] case final item?) _card(context, item),
              ],
            ),
          ),
        ),
        if (allAnswered) ...[
          const SizedBox(height: Space.md),
          FilledButton(
            key: const ValueKey('missed-deck-next'),
            onPressed: nextDeck
                ? () => setState(() => _onAlarmDeck = true)
                : _close,
            child: Text(
              nextDeck ? 'Next: missed alarms (${_alarmIds.length})' : 'Close',
            ),
          ),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, ScheduleItem item) {
    final self = item.createdByUid == item.targetUid;
    final plannerName = self
        ? null
        : ref.watch(profileByUidProvider(item.createdByUid)).value?.name;
    final answer = _answers[item.id] ??
        (item.outcome == null
            ? null
            : item.outcome!.result == OutcomeResult.done
            ? MissedCardAnswer.done
            : MissedCardAnswer.skipped);
    final mine = _busyId == item.id;
    final busy = _busyId != null;
    final canNote =
        !self && item.reply == null && !_noteSent.contains(item.id);
    // Scrolls inside the fixed card height, so a long sentence, large text
    // or the answered line never overflows it.
    return SingleChildScrollView(
      child: Column(
      key: ValueKey('missed-card-${item.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          alarmHeadline(item, plannerName: plannerName),
          style: context.text.titleMedium,
        ),
        const SizedBox(height: Space.xs),
        Text(
          missedPlannedAt(context, item),
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Space.md),
        if (mine && _updating)
          Text(
            updatingPlannerLabel(selfPlanned: self, plannerName: plannerName),
            key: ValueKey('missed-updating-${item.id}'),
            style: context.text.titleSmall,
          )
        else if (answer != null)
          Row(
            key: ValueKey('missed-answered-${item.id}'),
            children: [
              Icon(
                answer == MissedCardAnswer.skipped
                    ? AppIcons.skipped
                    : AppIcons.played,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(width: Space.xs),
              Text(
                missedAnswerLabel(answer),
                style: context.text.titleSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        const SizedBox(height: Space.sm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Space.sm,
          runSpacing: Space.xs,
          children: [
            if (answer == null && item.isVoiceAlarm)
              OutlinedButton(
                key: ValueKey('missed-heard-${item.id}'),
                onPressed: busy
                    ? null
                    : () => _answer(item, MissedCardAnswer.heard),
                child: const Text('Already heard'),
              ),
            if (answer == null && !item.isVoiceAlarm)
              OutlinedButton(
                key: ValueKey('missed-skip-${item.id}'),
                onPressed: busy
                    ? null
                    : () => _answer(item, MissedCardAnswer.skipped),
                child: const Text('Skip'),
              ),
            if (canNote)
              SendNoteButton(
                item: item,
                enabled: !busy,
                onSent: () => setState(() => _noteSent.add(item.id)),
              ),
            if (answer == null && item.isVoiceAlarm)
              FilledButton.icon(
                key: ValueKey('missed-play-${item.id}'),
                onPressed: busy ? null : () => _play(item),
                icon: const Icon(AppIcons.voiceNotePlay),
                label: Text(
                  mine && _loading
                      ? 'Loading…'
                      : mine && _playing
                      ? 'Playing…'
                      : 'Play',
                ),
              ),
            if (answer == null && !item.isVoiceAlarm)
              FilledButton(
                key: ValueKey('missed-done-${item.id}'),
                onPressed: busy
                    ? null
                    : () => _answer(item, MissedCardAnswer.done),
                child: const Text('Done'),
              ),
          ],
        ),
      ],
      ),
    );
  }
}

/// The answered state a card shows. Pure, for tests.
String missedAnswerLabel(MissedCardAnswer answer) => switch (answer) {
  MissedCardAnswer.played => 'Played',
  MissedCardAnswer.heard => 'Heard',
  MissedCardAnswer.done => 'Done',
  MissedCardAnswer.skipped => 'Skipped',
};

/// The missed popup's message (R3, 2026-10-02): always says who planned it.
/// A voice note keeps its question; a Default Alarm leads with the one alarm
/// sentence ([alarmHeadline]) so the planner's name is there too.
String missedPopupMessage(ScheduleItem item, {String? plannerName}) {
  if (item.isVoiceAlarm) {
    final name = plannerName?.trim();
    final who = name == null || name.isEmpty ? 'Someone' : name;
    return '$who sent you a voice note. Listen now?';
  }
  return '${alarmHeadline(item, plannerName: plannerName)}. '
      'It rang $kAlarmRingCount times with no response.';
}

/// When the missed alarm was planned for, in its own zone.
String missedPlannedAt(BuildContext context, ScheduleItem item) =>
    'Planned for '
    '${formatInstant(context, item.scheduledInstantUtc, item.timezone)}';
