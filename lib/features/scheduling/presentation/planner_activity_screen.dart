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
import '../../../core/widgets/explainer_card.dart';
import '../../../core/widgets/tab_action_row.dart';
import '../../../routing/app_router.dart';
import '../../calendar/application/calendar_grouping.dart';
import '../../archive/presentation/archive_menu_button.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../application/planner_ring_status.dart';
import '../application/schedule_item_order.dart';
import '../application/schedule_providers.dart';
import '../domain/schedule_item.dart';
import 'planner_item_detail_sheet.dart';
import '../../voice_notes/application/voice_delivery_policy.dart';
import '../../outcomes/application/schedule_partition.dart';
import '../../outcomes/presentation/reply_note.dart';

/// The planner's view of everything they created — updates LIVE as the target
/// approves/rejects and marks Done/Skip (Option B: no push, just a Firestore
/// listener). This is where the loop closes for the planner.
class PlannerActivityScreen extends ConsumerStatefulWidget {
  const PlannerActivityScreen({
    super.key,
    this.embedded = false,
    this.highlightItemId,
    this.highlightToken = 0,
  });

  /// When true, this is a sub-tab inside the Plan shell: the shell owns the app
  /// bar and its persistent `PLAN` action, so both are suppressed here. Default
  /// false retains this screen's standalone presentation.
  final bool embedded;

  /// The item to reveal and outline (Calendar → "Open in Activity"). A new
  /// [highlightToken] re-triggers the same item.
  final String? highlightItemId;
  final int highlightToken;

  @override
  ConsumerState<PlannerActivityScreen> createState() =>
      _PlannerActivityScreenState();
}

class _PlannerActivityScreenState extends ConsumerState<PlannerActivityScreen> {
  final _scrollController = ScrollController();
  final _highlightKey = GlobalKey();
  Timer? _fade;
  String? _highlighted;
  int? _highlightIndex;
  int _itemCount = 0;
  int _scrollRequest = 0;

  static const _highlightDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    if (widget.highlightItemId != null) _applyHighlight(widget.highlightItemId);
  }

  @override
  void didUpdateWidget(PlannerActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightItemId != oldWidget.highlightItemId ||
        widget.highlightToken != oldWidget.highlightToken) {
      _applyHighlight(widget.highlightItemId);
    }
  }

  @override
  void dispose() {
    _fade?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Called from initState/didUpdateWidget, both of which are followed by a
  /// build, so the field is set directly.
  void _applyHighlight(String? itemId) {
    _fade?.cancel();
    final request = ++_scrollRequest;
    _highlighted = itemId;
    if (itemId == null) return;
    _fade = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = null);
    });
    _tryScroll(request, 0);
  }

  /// Same reveal as My Schedule / History: the day is forced open, then the
  /// keyed card is brought into view; a far card in the lazy list is first
  /// approached by its flattened position so it gets built at all.
  void _tryScroll(int request, int attempt, [int settled = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlighted == null || request != _scrollRequest) return;
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
        if (_scrollController.hasClients &&
            _highlightIndex != null &&
            _itemCount > 0) {
          final max = _scrollController.position.maxScrollExtent;
          final fraction = _itemCount <= 1
              ? 0.0
              : _highlightIndex! / (_itemCount - 1);
          _scrollController.jumpTo((fraction * max).clamp(0.0, max));
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

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(myItemsAsPlannerProvider);
    final me = ref.watch(currentUidProvider) ?? '';
    final embedded = widget.embedded;

    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Activity')),
      floatingActionButton: embedded
          ? null
          : FloatingActionButton.extended(
              // Unique tag — this tab is mounted alongside GroupsScreen's FAB
              // inside HomeShell's IndexedStack, so the default shared FAB hero
              // tag collides.
              heroTag: 'activityFab',
              onPressed: () => context.push(Routes.scheduleBuilder),
              icon: const Icon(AppIcons.add),
              label: const Text('Plan an item'),
            ),
      body: Column(
        children: [
          // The same top button row as every Plan sub-tab (2026-09-28).
          TabActionRow(
            groups: TabAction(
              key: const ValueKey('activity-archive'),
              label: 'ARCHIVE',
              onPressed: () => context.push(Routes.archived),
            ),
          ),
          const ExplainerCard('Answered plans you made for others.'),
          Expanded(
            child: AsyncView<List<ScheduleItem>>(
              value: itemsAsync,
              // Retry the SOURCE stream. `myItemsAsPlannerProvider` is a derived
              // Provider; invalidating it would recompute the filter without ever
              // reconnecting the Firestore listener that actually failed.
              onRetry: () => ref.invalidate(allItemsAsPlannerProvider),
              // Item 7 (2026-09-27): Activity holds the plans you set for
              // others ONCE THEY ARE ANSWERED. Still-open ones live on Home,
              // and self-plans were never here.
              isEmpty: (items) =>
                  !items.any((i) => isSettledPlanForOthers(i, me)),
              emptyMessage:
                  'Plans you set for others appear here once they answer. '
                  'Until then they are on Home.',
              builder: (context, items) {
                final sorted =
                    items.where((i) => isSettledPlanForOthers(i, me)).toList()
                      ..sort(compareScheduleItemsLatestFirst);
                final groups = _grouped(context, sorted);
                _itemCount = sorted.length;
                _highlightIndex = null;
                String? forceKey;
                if (_highlighted != null) {
                  var flattened = 0;
                  for (final group in groups) {
                    final index = _byDay[group.key]!.indexWhere(
                      (item) => item.id == _highlighted,
                    );
                    if (index >= 0) {
                      _highlightIndex = flattened + index;
                      forceKey = group.key;
                      break;
                    }
                    flattened += group.itemCount;
                  }
                }
                return CollapsibleDayGroups(
                  controller: _scrollController,
                  initiallyExpandedKeys: {dayKeyOf(DateTime.now())},
                  forceExpandKey: forceKey,
                  groups: groups,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  final _byDay = <String, List<ScheduleItem>>{};

  /// Bucket the already-sorted (instant-desc) items into collapsible day groups
  /// by each item's OWN-timezone day (`calendarDayFor` — never the viewer's, so
  /// a "Tue 9:00" card can't file under Monday). Days ordered most-recent-first;
  /// within a day, items keep the instant-desc order they arrived in.
  List<DayGroupData> _grouped(BuildContext context, List<ScheduleItem> sorted) {
    final byDay = _byDay..clear();
    final dateFor = <String, DateTime>{};
    for (final item in sorted) {
      final day = calendarDayFor(item);
      final key = dayKeyOf(day);
      dateFor[key] = day;
      byDay.putIfAbsent(key, () => []).add(item);
    }
    final keys = byDay.keys.toList()
      ..sort(
        (a, b) => dateFor[b]!.compareTo(dateFor[a]!),
      ); // most-recent day first
    return [
      for (final key in keys)
        DayGroupData(
          key: key,
          date: dateFor[key]!,
          label: formatWallDate(context, dateFor[key]!),
          itemCount: byDay[key]!.length,
          itemBuilder: (context, index) {
            final item = byDay[key]![index];
            return PlannerItemCard(
              item: item,
              highlighted: item.id == _highlighted,
              cardKey: item.id == _highlighted ? _highlightKey : null,
            );
          },
        ),
    ];
  }
}

/// One plan you set for someone else — its status, their local time, voice
/// delivery, the unavailable fact, and **Cancel alarm** while it is open. Used
/// by Activity (answered plans) and by Home (still-open ones, item 7).
class PlannerItemCard extends ConsumerWidget {
  const PlannerItemCard({
    super.key,
    required this.item,
    this.highlighted = false,
    this.cardKey,
  });

  final ScheduleItem item;
  final bool highlighted;
  final Key? cardKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targetName =
        ref.watch(profileByUidProvider(item.targetUid)).value?.name ?? 'target';

    // Card margin, padding, radius, border and elevation all come from
    // CardTheme (UI-RULES.md §6.1) — a bare Card would inherit Material's
    // default shadow, which the flat-by-default rule forbids.
    return Card(
      key: cardKey,
      clipBehavior: Clip.antiAlias,
      // The same primary outline My Schedule uses for a deep-linked card: line
      // work, never a doctrine fill (UI-RULES.md §2.7).
      shape: highlighted
          ? RoundedRectangleBorder(
              borderRadius: Radii.md,
              side: BorderSide(
                color: context.colors.primary,
                width: Sizes.ruleWidth,
              ),
            )
          : null,
      child: InkWell(
        onTap: () => showPlannerItemDetailSheet(
          context,
          item: item,
          targetName: targetName,
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
                  PlanBadges(item: item, iAmTarget: false),
                ],
              ),
              const SizedBox(height: Space.xs),
              // Always name the zone: this time is in the TARGET's local time, not
              // the planner's — a bare "09:00" here is the most misleading thing a
              // planner could see.
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'for '),
                    TextSpan(text: targetName, style: AppText.bodySmallStrong),
                    TextSpan(
                      text:
                          ' · '
                          '${formatInstant(context, item.scheduledInstantUtc, item.timezone)} '
                          '(${item.timezone}, their local time)',
                    ),
                  ],
                ),
                // bodySmall, not labelSmall: this reads as a sentence even though
                // it carries metadata (UI-RULES.md §3, prose-wins tiebreaker).
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              ..._reasonLine(context),
              // Late completion — the delay is honest accountability data, so the
              // planner sees it here too (muted line, not a red flag: it was done).
              if (item.completionDelay case final delay?) ...[
                const SizedBox(height: Space.xs),
                Text(
                  'Completed ${formatDurationMinutes(context, delay.inMinutes)} late',
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
              // Voice-note delivery (item 32c): whether the planner's note is
              // safely on the other phone yet. Muted line work, not state.
              if (plannerVoiceNoteStatus(item) case final voice?) ...[
                const SizedBox(height: Space.xs),
                Text(
                  voice,
                  key: const ValueKey('planner-voice-status'),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
              // Live while it goes off (2026-10-04): which ring, or when it
              // rings again. Worked out on this phone, no push.
              PlannerRingStatusLine(item: item),
              if (item.wasUnavailableAtAlarmTime) ...[
                const SizedBox(height: Space.xs),
                Text(
                  'User unavailable at alarm time',
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
              // Bottom row (UI-RULES §6.18): the ONE status badge on the left
              // (an outcome replaces the approval status, because "Done"
              // implies "Approved"), the card's one action on the right —
              // Cancel alarm while it is open (F2), Archive once answered.
              // Rejected and withdrawn rows never render here: they are
              // auto-hidden the moment their status is set.
              ..._bottomRow(context, ref),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _bottomRow(BuildContext context, WidgetRef ref) {
    final status = itemStatusBadge(item, context);
    final canCancel = plannerCanCancel(item, DateTime.now().toUtc());
    // Mirrors `itemStatusBadge`: a live approved alarm shows no badge.
    final hasStatus =
        item.outcome != null || item.status != ScheduleItemStatus.approved;
    if (!hasStatus && !canCancel && !item.isManuallyArchivable) {
      return const [];
    }
    return [
      const SizedBox(height: Space.sm),
      // One line when it fits, else the action drops below, right.
      OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.end,
        overflowSpacing: Space.xs,
        children: [
          status,
          // R6: the target's note, on the answered card only.
          if (item.outcome != null && item.reply != null)
            ReplyNoteButton(item: item, iAmTarget: false),
          if (canCancel)
            TextButton(
              key: const ValueKey('planner-cancel-alarm'),
              onPressed: () => _withdraw(context, ref),
              child: const Text('Cancel alarm'),
            )
          else if (item.isManuallyArchivable)
            ArchiveButton(item: item),
        ],
      ),
    ];
  }

  /// Cancel an alarm I set, then tell the target. The write is the source of
  /// truth (their phone stops arming it off the item stream); the push is
  /// additive — a failed push never blocks the cancel.
  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this alarm?'),
        content: const Text("It won't ring on their phone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          // Destructive — one of the rationed uses of red (UI-RULES.md §2.5).
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colors.error,
              foregroundColor: ctx.colors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel alarm'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(scheduleRepositoryProvider)
        // `item:` frees the slot lock this plan was holding.
        .withdraw(item.targetUid, item.id, item: item);
    await ref
        .read(notificationEventNotifierProvider)
        .notify(
          event: NotifyEvent.withdrawn,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  /// The reason line, when the target gave one.
  ///
  /// The outcome itself is carried by the badge in the header — this is only the
  /// prose. Quoted user content is distinguished by `onSurfaceVariant` colour,
  /// never italics (UI-RULES.md §3).
  ///
  /// In practice only the skip arm is reachable from this screen now: rejected
  /// items are auto-hidden before they can render here, and their reason is
  /// shown on the Archived screen instead. The rejected arm is kept rather than
  /// deleted because it is the correct rendering for the state, and narrowing
  /// the auto-hide rule would need it back immediately.
  List<Widget> _reasonLine(BuildContext context) {
    final reason = switch (item) {
      ScheduleItem(
        status: ScheduleItemStatus.rejected,
        :final rejectionReason?,
      ) =>
        'Reason: $rejectionReason',
      // A missed-alarm skip's reason repeats the "User unavailable at alarm
      // time" line below; show that fact once (device report 2026-09-28).
      ScheduleItem(outcome: ScheduleOutcome(:final skipReason?))
          when skipReason != kUserUnavailableSkipReason =>
        'Reason: $skipReason',
      _ => null,
    };
    if (reason == null) return const [];
    return [
      const SizedBox(height: Space.xs),
      Text(
        reason,
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    ];
  }
}

/// "Ringing now", "Ringing · reminder 2 of 3" or "Not answered · rings again
/// about 5:23" from the target phone's ring record (2026-10-05); nothing
/// otherwise. Re-checks itself every few seconds, only
/// while there is something live to show.
class PlannerRingStatusLine extends StatefulWidget {
  const PlannerRingStatusLine({super.key, required this.item, this.now});

  final ScheduleItem item;

  /// The clock, for tests.
  final DateTime Function()? now;

  @override
  State<PlannerRingStatusLine> createState() => _PlannerRingStatusLineState();
}

class _PlannerRingStatusLineState extends State<PlannerRingStatusLine> {
  Timer? _tick;

  DateTime _now() => (widget.now ?? DateTime.now)().toUtc();

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _keepTicking(bool live) {
    if (live && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) setState(() {});
      });
    } else if (!live && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = plannerRingStatus(widget.item, _now());
    // The rang fact arrives with the item stream, which rebuilds this; from
    // then on it ticks by itself until the cycle is over.
    _keepTicking(status != null);
    final text = switch (status) {
      PlannerRinging(:final ring) =>
        ring <= 1
            ? 'Ringing now'
            : 'Ringing · reminder $ring of $kPlannerRingCount',
      PlannerWaiting(:final ringsDone, :final nextRingAtUtc) =>
        nextRingAtUtc != null && nextRingAtUtc.isAfter(_now())
            ? 'Not answered · rings again about '
                  '${formatInstantTime(context, nextRingAtUtc, widget.item.timezone)}'
            : 'Not answered after $ringsDone of $kPlannerRingCount · '
                  'reminder pending',
      null => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Text(
        text,
        key: const ValueKey('planner-ring-status'),
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
