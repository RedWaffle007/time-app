import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/plan_badge_style.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/highlight_reveal.dart';
import '../../../core/widgets/collapsible_day_groups.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/tab_action_row.dart';
import '../../../routing/app_router.dart';
import '../../archive/presentation/archive_menu_button.dart';
import '../../auth/application/auth_providers.dart';
import '../../calendar/application/calendar_grouping.dart';
import '../../celebrations/application/celebration_providers.dart';
import '../../celebrations/domain/completion_celebration.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../reminders/presentation/reminder_primer.dart';
import '../../scheduling/application/schedule_item_order.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../scheduling/presentation/planner_activity_screen.dart';
import '../../scheduling/presentation/planner_item_detail_sheet.dart';
import '../../voice_notes/application/voice_note_cache.dart';
import '../../voice_notes/application/voice_note_providers.dart';
import '../application/history_intent.dart';
import '../application/outcome_feedback.dart';
import '../application/schedule_partition.dart';
import '../application/schedule_time_section.dart';
import 'hero_band.dart';
import 'updating_planner_dialog.dart';
import 'reply_note.dart';

/// The target's approved items — where they mark Done or Skip, and where a
/// tapped reminder lands.
///
/// A reminder carries only the item id (`Routes.planForItem`), and the Plan
/// shell forwards it here as `highlightItemId`: the matching card is scrolled
/// into view and outlined for
/// a few seconds. Deliberately not a separate detail screen — this list already
/// holds the Done and Skip controls, so the tap ends one gesture from closing
/// the loop, and there is no second rendering of an item to keep in step.
class OutcomeScreen extends ConsumerStatefulWidget {
  const OutcomeScreen({
    super.key,
    this.highlightItemId,
    this.embedded = false,
    this.highlightToken = 0,
  });

  /// From `?item=` — the item a reminder was tapped for. Null in every other
  /// route onto this screen.
  final String? highlightItemId;

  /// When true, this is the My Schedule sub-tab inside the Plan shell: the shell
  /// owns the app bar and carries the pending-approvals action + badge, so the
  /// app bar is suppressed here. Since the S5 cutover a tapped reminder reaches
  /// here embedded — the Plan shell forwards `highlightItemId` down. Default
  /// false is now dead (the old bar is gone) but kept so the screen still renders
  /// standalone in tests.
  final bool embedded;

  /// Re-trigger token for the highlight. It equals the `PlanIntent.seq` that
  /// carried [highlightItemId], so RE-highlighting the SAME item (a repeated
  /// reminder / calendar tap) still fires — the item string alone is unchanged,
  /// which is why keying off it silently swallowed repeats (found on the S5
  /// device pass). Ignored when [highlightItemId] is null.
  final int highlightToken;

  @override
  ConsumerState<OutcomeScreen> createState() => _OutcomeScreenState();
}

class _OutcomeScreenState extends ConsumerState<OutcomeScreen>
    with WidgetsBindingObserver {
  /// The item currently outlined. Separate from `widget.highlightItemId`
  /// because it FADES: this tab is a shell branch, so its location — query
  /// parameter and all — survives every tab switch for the life of the process.
  /// Keyed off the widget property alone, an item tapped once this morning
  /// would still be outlined tonight.
  String? _highlighted;
  Timer? _fade;

  /// Drives time-section changes even when Firestore is quiet. Without this,
  /// a screen left open across midnight can keep yesterday under Future until
  /// some unrelated state happens to rebuild it.
  Timer? _clockTick;
  Timer? _boundaryTick;
  late DateTime _nowUtc;

  /// Key on the highlighted card, so it can be scrolled to precisely once built.
  final _highlightKey = GlobalKey();

  /// Drives the highlight scroll by index — the card may be far off-screen and
  /// therefore NOT built (a lazy `ListView` only builds near the viewport), so
  /// we cannot wait for its `build` to trigger the scroll (the "no scroll" bug
  /// found on the S5 device pass). We jump toward its index to force it to
  /// build, then `ensureVisible` lands it exactly.
  final _scrollController = ScrollController();

  /// The highlighted item's index among the approved cards, and how many there
  /// are — both set during [build], read by [_tryScroll]. Null index = the
  /// highlighted item is not in the list.
  int? _highlightIndex;
  int _approvedCount = 0;

  /// The highlighted card is in Waiting on You / Them (the top), not in the
  /// Upcoming day groups — set during [build], read by [_tryScroll].
  bool _highlightInWaiting = false;

  /// Increments for every deep-link intent, including a repeat of the same id.
  /// Delayed scroll callbacks from an earlier intent become harmless no-ops.
  int _scrollRequest = 0;

  static const _highlightDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nowUtc = DateTime.now().toUtc();
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _nowUtc = DateTime.now().toUtc());
    });
    _applyHighlight(widget.highlightItemId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _nowUtc = DateTime.now().toUtc());
    }
  }

  @override
  void didUpdateWidget(OutcomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-apply when the item changes OR the token advances — the token is what
    // lets a repeat of the SAME item re-highlight.
    if (widget.highlightItemId != oldWidget.highlightItemId ||
        widget.highlightToken != oldWidget.highlightToken) {
      _applyHighlight(widget.highlightItemId);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fade?.cancel();
    _clockTick?.cancel();
    _boundaryTick?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _applyHighlight(String? itemId) {
    _fade?.cancel();
    _highlighted = itemId;
    final request = ++_scrollRequest;
    if (itemId == null) return;
    _fade = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = null);
    });
    // Kick the index-driven scroll. Its post-frame runs AFTER the build that
    // sets `_highlightIndex`, so the index is available by the time it reads it.
    _tryScroll(request, 0);
  }

  /// Bring the highlighted card into view, retrying across frames.
  ///
  /// Two stages, because the card may not be built yet:
  ///  - **Not built** (far off-screen in a lazy `ListView`): jump the controller
  ///    toward the card's index fraction, which forces the list to build that
  ///    region — next frame the card exists.
  ///  - **Built**: `ensureVisible` lands it exactly, at a comfortable alignment.
  ///
  /// This also covers the WARM path where the deep link arrives mid inner-TabBar
  /// slide — we simply keep retrying (a no-op once landed) until visible or a
  /// bounded budget runs out. Cold start / a near-top card lands on frame 0.
  void _tryScroll(int request, int attempt, [int settled = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlighted == null || request != _scrollRequest) {
        return;
      }
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        if (isHighlightRevealed(ctx)) {
          // Landed; keep watching a few frames in case the page still moves.
          if (settled < kHighlightSettleFrames) {
            WidgetsBinding.instance.scheduleFrame();
            _tryScroll(request, attempt, settled + 1);
          }
          return;
        }
        // Wait for this precise reveal to finish before looking again. Scheduling
        // another frame immediately used to keep retrying after the target had
        // already arrived, especially at a list boundary where reveal clamps.
        if (attempt < 60) {
          try {
            Scrollable.ensureVisible(
              ctx,
              // The first reveal is instant: arriving from a link, the plan
              // is simply there, no visible scroll (2026-09-28).
              duration: attempt == 0 ? Duration.zero : Motion.fast,
              curve: Motion.curve,
              alignment: kHighlightAlignment,
            ).whenComplete(() => _tryScroll(request, attempt + 1));
          } catch (_) {
            // The target can be mid page-transition (e.g. arriving from the
            // Calendar): try again next frame rather than give up.
            WidgetsBinding.instance.scheduleFrame();
            _tryScroll(request, attempt + 1);
          }
        }
      } else {
        if (_scrollController.hasClients && _highlightInWaiting) {
          // A Waiting on You / Them card sits at the TOP (2026-09-28): when
          // the list is scrolled down it is not built, and it has no Upcoming
          // index to jump to — go to the top, where it is.
          _scrollController.jumpTo(0);
        } else if (_scrollController.hasClients &&
            _highlightIndex != null &&
            _approvedCount > 0) {
          // The card is not built — jump roughly to its position so it does, then
          // the next frame refines with `ensureVisible` above.
          final max = _scrollController.position.maxScrollExtent;
          final frac = _approvedCount <= 1
              ? 0.0
              : _highlightIndex! / (_approvedCount - 1);
          _scrollController.jumpTo((frac * max).clamp(0.0, max));
        }
        if (attempt < 60) {
          // Post-frame callbacks need a frame; ask for one so the retry
          // never stalls on a quiet screen.
          WidgetsBinding.instance.scheduleFrame();
          _tryScroll(request, attempt + 1);
        }
      }
    });
  }


  void _scheduleBoundaryTick(List<ScheduleItem> items) {
    _boundaryTick?.cancel();
    final now = DateTime.now().toUtc();
    DateTime? next;
    for (final item in items) {
      if (item.status != ScheduleItemStatus.approved || item.outcome != null) {
        continue;
      }
      final due = item.scheduledInstantUtc;
      if (!due.isBefore(now) && (next == null || due.isBefore(next))) {
        next = due;
      }
    }
    if (next == null) return;
    _boundaryTick = Timer(
      next.difference(now) + const Duration(milliseconds: 1),
      () {
        if (mounted) setState(() => _nowUtc = DateTime.now().toUtc());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(myItemsAsTargetProvider);
    // Item 7 (2026-09-27): plans I set for OTHERS stay on Home until they
    // answer (then they move to Activity). Their own stream; an error there
    // must not hide my own plans, so it simply contributes nothing.
    final me = ref.watch(currentUidProvider) ?? '';
    final forOthers = [
      for (final item
          in ref.watch(myItemsAsPlannerProvider).value ??
              const <ScheduleItem>[])
        if (isOpenPlanForOthers(item, me)) item,
    ];

    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Home')),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        // Retry the SOURCE stream — see the note in planner_activity_screen.
        onRetry: () => ref.invalidate(allItemsAsTargetProvider),
        builder: (context, items) {
          _scheduleBoundaryTick([...items, ...forOthers]);
          final mine = items
              .where((item) => isUpcomingPlan(item, _nowUtc))
              .toList();
          // Mine first, then the open plans I set for others (a plan can be
          // both only as a self-plan, which is already in `mine`).
          final mineIds = {for (final item in mine) item.id};
          final open = [
            ...mine,
            for (final item in forOthers)
              if (!mineIds.contains(item.id)) item,
          ];
          // Three headings (2026-09-28): a plan leaves Upcoming the moment it
          // rings and waits under Waiting on You / Waiting on Them.
          final waitingOnYou = <ScheduleItem>[];
          final waitingOnThem = <ScheduleItem>[];
          final approved = <ScheduleItem>[];
          for (final item in open) {
            switch (homeSectionFor(
              item,
              _nowUtc,
              isMine: mineIds.contains(item.id),
            )) {
              case HomeSection.waitingOnYou:
                waitingOnYou.add(item);
              case HomeSection.waitingOnThem:
                waitingOnThem.add(item);
              case HomeSection.upcoming:
                approved.add(item);
            }
          }
          waitingOnYou.sort(compareScheduleItemsLatestFirst);
          waitingOnThem.sort(compareScheduleItemsLatestFirst);

          // Upcoming is one surface, grouped only by each item's own-timezone
          // calendar day. The partition itself is absolute-instant based; the
          // day is presentation only.
          final byGroup = <String, List<ScheduleItem>>{};
          final dateFor = <String, DateTime>{};
          for (final item in approved) {
            final day = calendarDayFor(item);
            final key = dayKeyOf(day);
            dateFor[key] = day;
            byGroup.putIfAbsent(key, () => []).add(item);
          }
          for (final list in byGroup.values) {
            list.sort(compareScheduleItemsLatestFirst);
          }
          final orderedKeys = byGroup.keys.toList()..sort();

          _approvedCount = approved.length;
          _highlightInWaiting =
              _highlighted != null &&
              [
                ...waitingOnYou,
                ...waitingOnThem,
              ].any((item) => item.id == _highlighted);
          // Keep the flattened position for the lazy-list fallback. Expanding a
          // target day makes its rows eligible to build, but it does not mount a
          // far-away child; this fraction jump brings that region into the
          // viewport so the keyed card can finish with `ensureVisible`.
          var flattenedIndex = 0;
          _highlightIndex = null;
          if (_highlighted != null) {
            for (final key in orderedKeys) {
              final dayItems = byGroup[key]!;
              final index = dayItems.indexWhere(
                (item) => item.id == _highlighted,
              );
              if (index >= 0) {
                _highlightIndex = flattenedIndex + index;
                break;
              }
              flattenedIndex += dayItems.length;
            }
          }

          // The NEXT upcoming item (earliest future, no outcome) drives the hero
          // band and the primer — the same facts the old `upcoming` list carried.
          // The hero band is about MY next plan, never one set for someone else.
          ScheduleItem? nextItem;
          for (final item in mine) {
            if (item.outcome == null &&
                item.scheduledInstantUtc.isAfter(_nowUtc)) {
              if (nextItem == null ||
                  item.scheduledInstantUtc.isBefore(
                    nextItem.scheduledInstantUtc,
                  )) {
                nextItem = item;
              }
            }
          }
          final hasUpcoming = nextItem != null;

          // Force the highlighted item's day open so its card mounts and the
          // scroll can land, even if that day would default to collapsed.
          String? forceKey;
          if (_highlighted != null) {
            for (final item in approved) {
              if (item.id == _highlighted) {
                forceKey = dayKeyOf(calendarDayFor(item));
                break;
              }
            }
          }

          return CollapsibleDayGroups(
            controller: _scrollController,
            initiallyExpandedKeys: {
              for (final key in orderedKeys)
                if (byGroup[key]!.any((item) => _isOnCurrentDay(item, _nowUtc)))
                  key,
            },
            forceExpandKey: forceKey,
            leading: [
              const _HomeActions(),
              HeroBand(nextItem: nextItem),
              ReminderPrimerCard(hasUpcomingItems: hasUpcoming),
              // Few, and each needs an answer: listed flat above Upcoming
              // (always built, so a deep-link highlight lands directly).
              if (waitingOnYou.isNotEmpty) ...[
                const SectionHeader(
                  'Waiting on You',
                  key: ValueKey('home-waiting-on-you'),
                  attention: true,
                ),
                for (final item in waitingOnYou) _card(item, me),
              ],
              if (waitingOnThem.isNotEmpty) ...[
                const SectionHeader(
                  'Waiting on Them',
                  key: ValueKey('home-waiting-on-them'),
                ),
                for (final item in waitingOnThem) _card(item, me),
              ],
              const _UpcomingPlansHeader(),
              if (approved.isEmpty) const _NoUpcomingPlans(),
            ],
            groups: [
              for (final key in orderedKeys)
                DayGroupData(
                  key: key,
                  date: dateFor[key]!,
                  label: formatWallDate(context, dateFor[key]!),
                  itemCount: byGroup[key]!.length,
                  itemBuilder: (context, index) =>
                      _card(byGroup[key]![index], me),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(ScheduleItem item, String me) {
    // A plan for someone else: its planner card — status, Cancel alarm, no
    // Done/Skip (those are theirs).
    if (item.targetUid != me && item.createdByUid == me) {
      return PlannerItemCard(
        item: item,
        highlighted: item.id == _highlighted,
        cardKey: item.id == _highlighted ? _highlightKey : null,
      );
    }
    return OutcomeCard(
      item: item,
      highlighted: item.id == _highlighted,
      // The key rides on the highlighted card only; that is all
      // `ensureVisible` needs to find it.
      cardKey: item.id == _highlighted ? _highlightKey : null,
    );
  }
}

bool _isOnCurrentDay(ScheduleItem item, DateTime nowUtc) =>
    scheduleTimeSection(item, nowUtc) == ScheduleTimeSection.today;

/// Home's top buttons (2026-09-28): CALENDAR · HISTORY · ARCHIVE, in the
/// same place as every Plan sub-tab's (`TabActionRow`). ARCHIVE replaced the
/// app bar's ⋮ → Archived.
class _HomeActions extends ConsumerWidget {
  const _HomeActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TabActionRow(
    home: TabAction(
      label: 'CALENDAR',
      onPressed: () => context.push(Routes.calendar),
    ),
    activity: TabAction(
      label: 'HISTORY',
      onPressed: () {
        ref.read(historyIntentProvider.notifier).open();
        context.push(Routes.history);
      },
    ),
    groups: TabAction(
      key: const ValueKey('home-archive'),
      label: 'ARCHIVE',
      onPressed: () => context.push(Routes.archived),
    ),
  );
}

class _UpcomingPlansHeader extends StatelessWidget {
  const _UpcomingPlansHeader();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
    child: Text(
      'Upcoming Plans',
      style: context.text.titleLarge,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

class _NoUpcomingPlans extends StatelessWidget {
  const _NoUpcomingPlans();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xxl),
    child: Center(
      child: Text(
        'No upcoming plans.',
        style: context.text.titleMedium,
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class OutcomeCard extends ConsumerStatefulWidget {
  const OutcomeCard({
    super.key,
    required this.item,
    this.highlighted = false,
    this.cardKey,
  });

  final ScheduleItem item;
  final bool highlighted;
  final Key? cardKey;

  @override
  ConsumerState<OutcomeCard> createState() => _OutcomeCardState();
}

class _OutcomeCardState extends ConsumerState<OutcomeCard> {
  bool _writingOutcome = false;

  /// A self-planned item has the same person as creator and target — no planner
  /// on the other end to notify.
  bool get _isSelfPlanned => widget.item.createdByUid == widget.item.targetUid;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final outcome = item.outcome;
    final plannerName = _isSelfPlanned
        ? 'you'
        : ref.watch(profileByUidProvider(item.createdByUid)).value?.name ??
              'someone';

    return Card(
      key: widget.cardKey,
      clipBehavior: Clip.antiAlias,
      // Line work, never a fill: an orange filled surface is reserved for "a
      // schedule item is waiting on you" (UI-RULES.md §2.7), and "you tapped a
      // reminder for this one" is a different, much weaker claim. A primary
      // outline says *this one* without spending that signal.
      shape: widget.highlighted
          ? RoundedRectangleBorder(
              borderRadius: Radii.md,
              side: BorderSide(
                color: context.colors.primary,
                width: Sizes.ruleWidth,
              ),
            )
          : null,
      // Tapping the card (anywhere but its buttons) opens the same status
      // timeline the planner sees from Activity — here for upcoming AND past
      // plans (device report 2026-09-25).
      child: InkWell(
        key: ValueKey('outcome-card-${item.id}'),
        onTap: () => showPlannerItemDetailSheet(
          context,
          item: item,
          targetName: 'you',
          contextLine: 'Planned by $plannerName · ${item.timezone}',
        ),
        child: Padding(
          padding: Space.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(item.title, style: context.text.titleMedium),
                  ),
                  const SizedBox(width: Space.sm),
                  // Who the plan is between (+ Group), top-right; status and
                  // the card's action sit on the bottom row (UI-RULES §6.18).
                  PlanBadges(item: item, iAmTarget: true),
                ],
              ),
              const SizedBox(height: Space.xs),
              Text(
                formatInstant(context, item.scheduledInstantUtc, item.timezone),
              ),
              const SizedBox(height: Space.xs),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Planned by '),
                    TextSpan(text: plannerName, style: AppText.bodySmallStrong),
                  ],
                ),
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              // Fixed layout for every card (device report 2026-09-28): the
              // facts sit here, left-aligned, each once and in one order, and
              // the bottom row is always status left / action right. The
              // permanent unavailable fact therefore stays ABOVE any
              // still-open decision.
              ..._factLines(context),
              const SizedBox(height: Space.md),
              // A voice note has no Done/Skip (2026-09-28). Before it rings
              // there is nothing to answer; once it has rung unanswered, the
              // same two choices as the missed popup.
              if (outcome == null && item.isVoiceAlarm) ...[
                if (!item.scheduledInstantUtc.isAfter(DateTime.now().toUtc()))
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    children: [
                      OutlinedButton(
                        key: ValueKey('voice-already-heard-${item.id}'),
                        onPressed: _writingOutcome
                            ? null
                            : () => _markHeard(play: false),
                        child: const Text('Already heard'),
                      ),
                      // R6: the optional note, beside the answers.
                      if (item.canSendReply)
                        SendNoteButton(item: item, enabled: !_writingOutcome),
                      FilledButton.icon(
                        key: ValueKey('voice-play-${item.id}'),
                        onPressed: _writingOutcome
                            ? null
                            : () => _markHeard(play: true),
                        icon: const Icon(AppIcons.voiceNotePlay),
                        label: Text(_writingOutcome ? 'Saving…' : 'Play'),
                      ),
                    ],
                  ),
              ] else if (outcome == null)
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  children: [
                    // Skipping is a legitimate outcome, so it gets the neutral
                    // secondary treatment — never red (UI-RULES.md §2.5).
                    OutlinedButton(
                      onPressed: _writingOutcome ? null : () => _skip(context),
                      child: const Text('Skip'),
                    ),
                    // R6: Skip · Send note · Done. Tapping Skip or Done
                    // directly means no note; nothing extra is asked.
                    if (item.canSendReply)
                      SendNoteButton(item: item, enabled: !_writingOutcome),
                    FilledButton(
                      onPressed: _writingOutcome ? null : _markDone,
                      child: Text(_writingOutcome ? 'Saving…' : 'Done'),
                    ),
                  ],
                )
              else
                _outcomeRow(),
            ],
          ),
        ),
      ),
    );
  }

  /// The muted facts under "Planned by", in a fixed order: unavailable at
  /// alarm time, how late, the skip reason. A missed-alarm skip's reason says
  /// the same thing as the unavailable tag, so it is not repeated.
  List<Widget> _factLines(BuildContext context) {
    final item = widget.item;
    final muted = context.text.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final skipReason = item.outcome?.skipReason;
    return [
      if (item.wasUnavailableAtAlarmTime) ...[
        const SizedBox(height: Space.xs),
        const _UnavailableTag(),
      ],
      // Completed, but after its scheduled time — surfaced, never hidden.
      // Muted text, not a doctrine fill: a late Done is still a Done.
      if (item.completionDelay case final delay?) ...[
        const SizedBox(height: Space.xs),
        Text(
          '${formatDurationMinutes(context, delay.inMinutes)} late',
          style: muted,
        ),
      ],
      if (skipReason != null &&
          skipReason.isNotEmpty &&
          skipReason != kUserUnavailableSkipReason) ...[
        const SizedBox(height: Space.xs),
        Text(skipReason, style: muted),
      ],
    ];
  }

  /// The recorded outcome: the ONE status badge bottom-left and the card's
  /// one action bottom-right (UI-RULES §6.18), on every card. Status reads
  /// the one mapping in `status_style.dart` (UI-RULES.md §2.3).
  /// On a phone too narrow for both, Archive wraps below; the badge never
  /// leaves the left edge.
  Widget _outcomeRow() => SizedBox(
    width: double.infinity,
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: Space.xs,
      children: [
        StatusBadge.itemOutcome(widget.item, context),
        // R6: the note this plan was answered with, if one was sent.
        if (widget.item.reply != null)
          ReplyNoteButton(item: widget.item, iAmTarget: true),
        // Only once an outcome is recorded — a live item is hideable by no
        // route at all.
        if (widget.item.isManuallyArchivable) ArchiveButton(item: widget.item),
      ],
    ),
  );

  // Record completion, then fire the (best-effort) planner push. The write is
  // the source of truth; the push is additive (see DECISIONS.md). No reminder
  // cancelling here: the outcome makes the item undesired, the item stream
  // re-emits, and the reconciler cancels it.
  /// "Updating {planner}…" for this card's planner — a self-plan and an unloaded
  /// name each have their own wording; never a uid.
  String _updatingLabel() => updatingPlannerLabel(
    selfPlanned: _isSelfPlanned,
    plannerName: _isSelfPlanned
        ? null
        : ref.read(profileByUidProvider(widget.item.createdByUid)).value?.name,
  );

  /// Tell the planner. Fire-and-forget: it runs inside the "Updating" window,
  /// but a slow push must never hold the screen.
  void _notifyPlanner(ScheduleItem item) {
    if (_isSelfPlanned) return; // no point notifying yourself
    unawaited(
      ref
          .read(notificationEventNotifierProvider)
          .notify(
            event: NotifyEvent.outcome,
            targetUid: item.targetUid,
            itemId: item.id,
          ),
    );
  }

  Future<void> _markDone() async {
    if (_writingOutcome) return;
    setState(() => _writingOutcome = true);
    final item = widget.item;
    final repository = ref.read(scheduleRepositoryProvider);
    final celebrations = ref.read(committedCelebrationProvider.notifier);
    bool recorded;
    try {
      // "Updating {planner}…" for 1.5 s (directed 2026-09-25), then the
      // celebration — the wait is explained instead of feeling like lag.
      recorded = await showUpdatingPlanner(
        context,
        label: _updatingLabel(),
        work: () async {
          final ok = await repository.markDone(
            item.targetUid,
            item.id,
            plannerUid: item.createdByUid,
          );
          if (ok) _notifyPlanner(item);
          return ok;
        },
      );
    } catch (_) {
      // R1 (2026-10-02): an offline transaction throws; it used to escape the
      // button as an uncaught crash with no message to the person.
      _showSaveFailed();
      return;
    } finally {
      if (mounted) setState(() => _writingOutcome = false);
    }
    if (!recorded) return;
    // Celebrate the committed Done without waiting for Firestore to echo the
    // event back (the echo is de-duplicated by id). No post-Done prompt: the
    // Log Time pop-up was removed 2026-09-25.
    celebrations.celebrate(
      CompletionCelebration.committed(
        targetUid: item.targetUid,
        itemId: item.id,
        plannerUid: item.createdByUid,
      ),
    );
  }

  /// Play / Already heard on a voice note that rang unanswered (2026-09-28):
  /// both close it as heard (Done under the hood; "Heard (Late)" after a
  /// missed ring) and tell the planner. No celebration: there was no task.
  Future<void> _markHeard({required bool play}) async {
    if (_writingOutcome) return;
    final item = widget.item;
    // Busy from the FIRST tap, before the fetch (R2, 2026-10-02): repeated
    // taps must not start a second fetch, play or write.
    setState(() => _writingOutcome = true);
    if (play) {
      try {
        final path = await ref.read(voiceNoteCacheProvider).ensure(item);
        await ref.read(voicePlayerProvider).play(path);
      } catch (_) {
        if (mounted) {
          setState(() => _writingOutcome = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Couldn't load the voice note. Try again."),
            ),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final repository = ref.read(scheduleRepositoryProvider);
    try {
      await showUpdatingPlanner(
        context,
        label: _updatingLabel(),
        work: () async {
          final ok = await repository.markDone(
            item.targetUid,
            item.id,
            plannerUid: item.createdByUid,
          );
          if (ok) _notifyPlanner(item);
          return ok;
        },
      );
    } catch (_) {
      _showSaveFailed();
    } finally {
      if (mounted) setState(() => _writingOutcome = false);
    }
  }

  Future<void> _skip(BuildContext context) async {
    if (_writingOutcome) return;
    var reason = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Skip this?'),
        content: TextField(
          onChanged: (value) => reason = value,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'Your planner will see this',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Skip'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !context.mounted) return;
    setState(() => _writingOutcome = true);
    final item = widget.item;
    final repository = ref.read(scheduleRepositoryProvider);
    try {
      // Same 1.5 s "Updating {planner}…" as Done, then back to the list — no
      // celebration for a skip.
      await showUpdatingPlanner(
        context,
        label: _updatingLabel(),
        work: () async {
          final ok = await repository.markSkipped(
            item.targetUid,
            item.id,
            reason: reason,
            announceToPlannerUid: item.createdByUid,
          );
          if (ok) _notifyPlanner(item);
          return ok;
        },
      );
    } catch (_) {
      _showSaveFailed();
    } finally {
      if (mounted) setState(() => _writingOutcome = false);
    }
  }

  /// Done / Skip / Heard could not be saved (offline, or refused). Nothing
  /// was recorded, so the buttons come back for another try.
  void _showSaveFailed() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't save. Check your connection and try again."),
      ),
    );
  }
}

/// The permanent alarm-time fact. Muted line work, never a doctrine fill: it
/// explains what happened, it is not something waiting on you (UI-RULES §2.7).
class _UnavailableTag extends StatelessWidget {
  const _UnavailableTag();

  @override
  Widget build(BuildContext context) => Text(
    'User unavailable at alarm time',
    key: const ValueKey('user-unavailable-tag'),
    style: context.text.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    ),
  );
}
