import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../plan/application/plan_intent.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../auth/domain/user_profile.dart';
import '../application/alarm_timeline_providers.dart';
import '../application/missed_alarm_providers.dart';
import '../application/reminder_policy.dart';
import '../application/reminder_providers.dart';
import '../application/ring_cycle.dart';
import '../data/alarm_lifecycle_store.dart';
import '../../outcomes/presentation/reply_note.dart';

/// The full-screen alarm surface a reminder lands on.
///
/// **Why it exists.** The reminder's notification is a full-screen intent: while
/// the screen is locked or off, Android launches the app straight onto this
/// screen; while the app is running, a tap on the heads-up brings it here. Both
/// arrive through the ONE tap route (`NotificationRouter.openItem`), which points
/// at `Routes.alarm` — a single place that decides where a reminder goes.
///
/// **The sound lives in a native service, not here.** On mount this screen
/// claims `AlarmSoundService` (a foreground service holding a wake lock) and
/// cancels the fired notification so its one-shot fallback tone does not double
/// up. The service is what keeps ringing with the screen off; every way off this
/// screen stops it. The notification's own tone still covers the case where
/// native delivery is delayed.
///
/// It is deliberately thin: it shows what is due and hands off to My Schedule,
/// where Done and Skip already live. It never marks an outcome itself.
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.itemId});

  /// The due item's id — the whole payload a reminder carries.
  final String itemId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  bool _dismissing = false;
  AlarmKeyEvents? _keyEvents;

  /// The sentence the native alarm was delivered with. Shown until the live
  /// item + planner name resolve, so the first frames never show a placeholder
  /// ("Reminder" / "Planner") that then changes — a device-reported flash.
  String? _deliveredHeadline;

  /// Opened between rings (2026-10-04): when it rings again. The screen stays
  /// silent and offers Dismiss, which also cancels the rings still to come.
  DateTime? _quietUntilUtc;

  /// Other alarms ringing at the same time (2026-10-04), oldest first. Only
  /// the newest makes a sound; each can be dismissed here on its own.
  List<String> _alsoRinging = const [];
  Timer? _ringingPoll;

  @override
  void initState() {
    super.initState();
    // Claim the wake-lock-backed tone FIRST, then cancel the redundant silent
    // scheduled notification. Deferred a frame: `ref` must not be used during
    // initState's synchronous build, and a platform call has no place there.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final keyEvents = ref.read(alarmKeyEventsProvider);
      _keyEvents = keyEvents;
      // Volume Down silenced EVERY ringing alarm natively (2026-10-04): leave
      // without opening another one.
      keyEvents.listen(() async {
        _ringingPoll?.cancel();
        _alsoRinging = const [];
        await _leave();
      });
      final sound = ref.read(alarmSoundProvider);
      // Both reads start together: the "already ended?" check never delays
      // the delivered sentence.
      final ended = _alarmEnded();
      final delivered = await sound.headline(widget.itemId);
      if (!mounted) return;
      if (delivered != null && delivered.trim().isNotEmpty) {
        setState(() => _deliveredHeadline = delivered.trim());
      }
      // An alarm that already ENDED (rang out unanswered, or was answered) is
      // not rung again. Opening the app after the ring cycle ran out used to land
      // here with a Dismiss button on top of the missed-alarm popup, and this
      // screen re-started the tone (2026-09-27 device report). Leave quietly
      // instead; the missed-alarm review shows over the Plan tab.
      if (await ended) {
        await _leaveEnded();
        return;
      }
      if (!mounted) return;
      // 2026-10-04: where the alarm is in its 25-minute cycle. Past it, with
      // nothing ringing now, it ends as missed with no tone, exactly like the
      // native path. Between rings it stays quiet: the next ring is already
      // armed natively, so this screen must not ring early.
      final item = ref
          .read(allItemsAsTargetProvider)
          .maybeWhen(data: _find, orElse: () => null);
      if (item != null && await sound.ringingItem() != widget.itemId) {
        switch (alarmScreenPhase(item, nowUtc: DateTime.now().toUtc())) {
          case RingOver():
            await sound.missLate(widget.itemId, headline: _headlineNow() ?? '');
            await _leaveEnded();
            return;
          case Quiet(:final nextRingAtUtc):
            if (mounted) setState(() => _quietUntilUtc = nextRingAtUtc);
            _watchRinging();
            return;
          case Ringing():
            break;
        }
      }
      if (!mounted) return;
      // The UI ownership claim must reach the native service before cancelling
      // the scheduled notification releases its native-delivery owner. These
      // used to race as two unawaited platform calls, briefly stopping and
      // restarting playback on an unlocked/full-screen launch.
      // The UI-fallback start carries the sentence too, for the heads-up of an
      // alarm whose native delivery did not run first.
      await sound.start(widget.itemId, headline: _headlineNow() ?? '');
      if (!mounted) return;
      final uid = ref.read(currentUidProvider);
      if (uid != null) {
        unawaited(
          ref
              .read(alarmTimelineServiceProvider)
              .recordRangFallback(uid, widget.itemId),
        );
      }
      // `dismiss` here means "cancel the OS notification for this item" — it
      // removes the redundant scheduled surface now that the foreground
      // service owns sound and its actionable notification. It does not
      // navigate; that is `_leave`.
      await ref.read(reminderServiceProvider).dismiss(widget.itemId);
      if (mounted) _watchRinging();
    });
  }

  @override
  void dispose() {
    _ringingPoll?.cancel();
    _keyEvents?.listen(null);
    super.dispose();
  }

  /// Keeps "Also ringing" current: alarms start and end on their own clocks.
  void _watchRinging() {
    _ringingPoll?.cancel();
    unawaited(_refreshRinging());
    _ringingPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshRinging()),
    );
  }

  Future<void> _refreshRinging() async {
    final ids = await ref.read(alarmSoundProvider).ringingItems();
    if (!mounted) return;
    final others = alsoRingingIds(ids, widget.itemId);
    // This alarm's own ring ended while others still ring: if it rings again
    // later, say when (the native side armed it).
    DateTime? quiet = _quietUntilUtc;
    if (quiet == null && ids.isNotEmpty && !ids.contains(widget.itemId)) {
      final item = ref
          .read(allItemsAsTargetProvider)
          .maybeWhen(data: _find, orElse: () => null);
      if (item != null) {
        final phase = alarmScreenPhase(item, nowUtc: DateTime.now().toUtc());
        if (phase is Quiet) quiet = phase.nextRingAtUtc;
      }
    }
    if (listEquals(others, _alsoRinging) && quiet == _quietUntilUtc) return;
    setState(() {
      _alsoRinging = others;
      _quietUntilUtc = quiet;
    });
  }

  /// Dismiss one of the other alarms: it stops, its later rings are
  /// cancelled, and its planner hears it was dismissed — as with Dismiss.
  Future<void> _dismissOther(String itemId) async {
    setState(
      () => _alsoRinging = [
        for (final id in _alsoRinging)
          if (id != itemId) id,
      ],
    );
    await ref.read(alarmSoundProvider).stop(itemId);
    final uid = ref.read(currentUidProvider);
    if (uid != null) {
      unawaited(
        ref.read(alarmTimelineServiceProvider).recordDismissed(uid, itemId),
      );
    }
    await ref.read(reminderServiceProvider).dismiss(itemId);
  }

  /// Dismiss every alarm ringing now, this one last, then leave as Dismiss.
  Future<void> _dismissAll() async {
    for (final id in List.of(_alsoRinging)) {
      await _dismissOther(id);
    }
    await _leave();
  }

  /// Whether this alarm is already over, from the facts this phone has now:
  /// the native timeout row (written the instant the ring cap is hit) or the
  /// item's own answer / timeline stamps.
  Future<bool> _alarmEnded() async {
    List<AlarmLifecycleEvent> events;
    try {
      events = await ref.read(alarmLifecycleStoreProvider).read();
    } catch (_) {
      events = const [];
    }
    final item = ref
        .read(allItemsAsTargetProvider)
        .maybeWhen(data: _find, orElse: () => null);
    return alarmHasEnded(itemId: widget.itemId, item: item, events: events);
  }

  /// Leave an alarm that already ended: no tone, no "dismissed" record (it was
  /// NOT dismissed; the missed-alarm flow owns it), just clear the leftover
  /// notification and land on the item in the Plan tab.
  Future<void> _leaveEnded() async {
    if (_dismissing) return;
    _dismissing = true;
    await ref.read(alarmSoundProvider).stop(widget.itemId);
    await ref.read(reminderServiceProvider).dismiss(widget.itemId);
    if (!mounted) return;
    if (widget.itemId.isNotEmpty) {
      ref.read(planIntentProvider.notifier).highlightItem(widget.itemId);
    }
    context.go(Routes.plan);
  }

  /// The best sentence available right now, or null when nothing trustworthy
  /// is known yet (render nothing rather than a placeholder).
  String? _headlineNow() {
    final item = ref
        .read(allItemsAsTargetProvider)
        .maybeWhen(data: _find, orElse: () => null);
    if (item == null) return _deliveredHeadline;
    final planner = ref.read(profileByUidProvider(item.createdByUid));
    return _resolveHeadline(item, planner);
  }

  String? _resolveHeadline(
    ScheduleItem item,
    AsyncValue<UserProfile?> planner,
  ) {
    final isSelf = item.createdByUid == item.targetUid;
    // The live sentence wins once the planner's name is settled (or not
    // needed); until then the delivered one is already correct.
    if (isSelf || planner.hasValue) {
      return alarmHeadline(item, plannerName: planner.value?.name);
    }
    return _deliveredHeadline;
  }

  ScheduleItem? _find(List<ScheduleItem> items) {
    for (final item in items) {
      if (item.id == widget.itemId) return item;
    }
    return null;
  }

  /// Stop the alarm, then land on My Schedule with this item singled out — the
  /// existing deep link, where Done/Skip are. Guarded so a double tap (or a Back
  /// racing the button) cannot fire two navigations.
  Future<void> _leave() async {
    if (_dismissing) return;
    _dismissing = true;
    await _stopAndRecordDismissed();
    if (!mounted) return;
    _goToPlan();
  }

  /// R6: "Dismiss & reply" on a voice note. Dismissing first (so the tone
  /// stops and the planner hears "heard", as with Dismiss), then the optional
  /// note pop-up right here, then the same landing as Dismiss.
  Future<void> _dismissAndReply(ScheduleItem item) async {
    if (_dismissing) return;
    _dismissing = true;
    await _stopAndRecordDismissed();
    if (!mounted) return;
    await showSendNoteDialog(context, ref, item);
    if (!mounted) return;
    _goToPlan();
  }

  Future<void> _stopAndRecordDismissed() async {
    await ref.read(alarmSoundProvider).stop(widget.itemId);
    // Between rings the next one is armed natively: cancel it now, without
    // waiting for the dismissal to reach the item stream (2026-10-04).
    if (_quietUntilUtc != null) {
      await ref.read(reminderServiceProvider).dismiss(widget.itemId);
    }
    final uid = ref.read(currentUidProvider);
    if (uid != null) {
      // Navigation must not wait on Firestore: Dismiss has to work offline.
      unawaited(
        ref
            .read(alarmTimelineServiceProvider)
            .recordDismissed(uid, widget.itemId),
      );
    }
  }

  void _goToPlan() {
    // Another alarm still ringing (2026-10-04): show it rather than leave its
    // sound playing behind the Plan tab.
    if (_alsoRinging.isNotEmpty) {
      context.go(Routes.alarmForItem(_alsoRinging.last));
      return;
    }
    if (widget.itemId.isNotEmpty) {
      // Set the highlight intent BEFORE navigating — the deterministic signal
      // the Plan shell listens to (query params were unreliable on the cached
      // branch page).
      ref.read(planIntentProvider.notifier).highlightItem(widget.itemId);
    }
    context.go(Routes.plan);
  }

  /// One other ringing alarm: who planned what, and its own Dismiss.
  Widget _alsoRingingRow(String id) {
    final items = ref.watch(allItemsAsTargetProvider);
    final item = items.maybeWhen(
      data: (list) {
        for (final i in list) {
          if (i.id == id) return i;
        }
        return null;
      },
      orElse: () => null,
    );
    final headline = item == null
        ? null
        : alarmHeadline(
            item,
            plannerName: ref
                .watch(profileByUidProvider(item.createdByUid))
                .value
                ?.name,
          );
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(
        key: ValueKey('alarm-also-$id'),
        children: [
          Expanded(
            child: Text(
              headline ?? '',
              style: context.text.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: ValueKey('alarm-also-dismiss-$id'),
            onPressed: () => _dismissOther(id),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The item comes from the same record stream the reminder was armed off, so
    // on a cold full-screen launch it may still be loading — the alarm is real
    // regardless, so this renders and rings with a generic title until the
    // stream resolves rather than blocking on it.
    final item = ref
        .watch(allItemsAsTargetProvider)
        .maybeWhen(data: _find, orElse: () => null);
    // The ring cap can be hit while this screen is up (or the stream can
    // arrive late and show it already ended): leave once the item says so.
    if (item != null &&
        !_dismissing &&
        alarmHasEnded(itemId: widget.itemId, item: item, events: const [])) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leaveEnded();
      });
    }
    final headline = item == null
        ? _deliveredHeadline
        : _resolveHeadline(
            item,
            ref.watch(profileByUidProvider(item.createdByUid)),
          );

    // Back / gesture-dismiss must also stop the tone, never leave it ringing.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: Space.screenForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Icon(
                  AppIcons.reminders,
                  size: Sizes.emptyStateIcon,
                  color: context.attention,
                ),
                const SizedBox(height: Space.xl),
                // ONE sentence, centered and bold: "{planner} planned {task} for
                // you" (device-directed copy, 2026-09-25). Nothing — not a
                // placeholder — until a trustworthy sentence is known.
                Text(
                  headline ?? '',
                  key: const ValueKey('alarm-headline'),
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (item != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    formatInstant(
                      context,
                      item.scheduledInstantUtc,
                      item.timezone,
                    ),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_quietUntilUtc case final until?) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    'Rings again at ${formatInstantTime(context, until, item?.timezone ?? 'Etc/UTC')}',
                    key: const ValueKey('alarm-quiet'),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (item?.note != null && item!.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    item.note!.trim(),
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium,
                  ),
                ],
                if (_alsoRinging.isNotEmpty) ...[
                  const SizedBox(height: Space.xl),
                  Text('Also ringing', style: context.text.titleSmall),
                  for (final id in _alsoRinging) _alsoRingingRow(id),
                ],
                const Spacer(),
                if (_alsoRinging.isNotEmpty) ...[
                  OutlinedButton(
                    key: const ValueKey('alarm-dismiss-all'),
                    onPressed: _dismissAll,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.sm),
                      child: Text('Dismiss all'),
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                ],
                FilledButton(
                  onPressed: _leave,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.sm),
                    child: Text('Dismiss'),
                  ),
                ),
                // R6: a voice note may be answered with a note. Dismiss alone
                // sends none.
                if (item != null &&
                    item.isVoiceAlarm &&
                    item.reply == null) ...[
                  const SizedBox(height: Space.sm),
                  OutlinedButton(
                    key: const ValueKey('alarm-dismiss-reply'),
                    onPressed: () => _dismissAndReply(item),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: Space.sm),
                      child: Text('Dismiss & reply'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The other alarms ringing with [itemId], oldest first. Pure, for tests.
List<String> alsoRingingIds(List<String> ringing, String itemId) => [
  for (final id in ringing)
    if (id != itemId) id,
];

/// Where an alarm opened on this screen stands in its ring cycle, when the
/// native service is not ringing it (2026-10-04). Pure, for tests.
RingPhase alarmScreenPhase(ScheduleItem item, {required DateTime nowUtc}) =>
    ringPhaseAt(item.scheduledInstantUtc, nowUtc);

/// True when an alarm is over and must not be shown or rung again: the native
/// side recorded its timeout, or the item already has an answer, an
/// "unavailable" fact or a dismissal. Pure, for tests.
bool alarmHasEnded({
  required String itemId,
  required ScheduleItem? item,
  required List<AlarmLifecycleEvent> events,
}) {
  final timedOut = events.any(
    (e) => e.itemId == itemId && e.kind == AlarmLifecycleEventKind.timeout,
  );
  if (timedOut) return true;
  if (item == null) return false;
  return item.outcome != null ||
      item.alarm?.unavailableAt != null ||
      item.alarm?.dismissedAt != null;
}
