import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/collapsible_day_groups.dart';
import '../../../routing/app_router.dart';
import '../../archive/presentation/archive_menu_button.dart';
import '../../calendar/application/calendar_grouping.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../reminders/presentation/reminder_primer.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../../time_tracking/presentation/log_from_done_prompt.dart';
import 'hero_band.dart';

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

class _OutcomeScreenState extends ConsumerState<OutcomeScreen> {
  /// The item currently outlined. Separate from `widget.highlightItemId`
  /// because it FADES: this tab is a shell branch, so its location — query
  /// parameter and all — survives every tab switch for the life of the process.
  /// Keyed off the widget property alone, an item tapped once this morning
  /// would still be outlined tonight.
  String? _highlighted;
  Timer? _fade;

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

  static const _highlightDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _applyHighlight(widget.highlightItemId);
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
    _fade?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _applyHighlight(String? itemId) {
    _fade?.cancel();
    _highlighted = itemId;
    if (itemId == null) return;
    _fade = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = null);
    });
    // Kick the index-driven scroll. Its post-frame runs AFTER the build that
    // sets `_highlightIndex`, so the index is available by the time it reads it.
    _tryScroll(0);
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
  void _tryScroll(int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlighted == null) return;
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        if (_isFullyVisible(ctx)) return; // done.
        Scrollable.ensureVisible(
          ctx,
          duration: Motion.fast,
          curve: Motion.curve,
          alignment: 0.2,
        );
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
      if (attempt < 60) _tryScroll(attempt + 1);
    });
  }

  /// Whether [ctx]'s render box is laid out and currently within the nearest
  /// scroll viewport — the signal that the highlight scroll has landed.
  ///
  /// Overlap-based, not "pixels == target reveal offset": near the list ends the
  /// card cannot reach the 0.2 alignment, so `ensureVisible` clamps and the exact
  /// offset is never hit — a strict equality check then loops forever (the
  /// "SCROLL exhausted" seen on the device pass). The box is visible when the
  /// current scroll window contains it.
  bool _isFullyVisible(BuildContext ctx) {
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return false;
    final position = Scrollable.maybeOf(ctx)?.position;
    if (position == null ||
        !position.hasPixels ||
        !position.hasViewportDimension) {
      return false;
    }
    // `getOffsetToReveal(box, 0.0).offset` IS the box's top in content
    // coordinates. The box is on screen when its extent overlaps the current
    // viewport window — an OVERLAP test, not "exactly aligned", so a near-list-end
    // card that clamps at `maxScrollExtent` (and can never reach a 0.2 alignment)
    // still counts as landed instead of retrying forever.
    final boxTop = viewport.getOffsetToReveal(box, 0.0).offset;
    final boxBottom = boxTop + box.size.height;
    final viewTop = position.pixels;
    final viewBottom = position.pixels + position.viewportDimension;
    return boxTop < viewBottom && boxBottom > viewTop;
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(myItemsAsTargetProvider);
    final pendingCount =
        itemsAsync.value
            ?.where((i) => i.status == ScheduleItemStatus.pending)
            .length ??
        0;

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: const Text('My Schedule'),
              actions: [
                IconButton(
                  tooltip: 'Pending approvals',
                  icon: Badge(
                    isLabelVisible: pendingCount > 0,
                    label: Text('$pendingCount'),
                    child: const Icon(AppIcons.approvals),
                  ),
                  onPressed: () => context.push(Routes.approvals),
                ),
              ],
            ),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        // Retry the SOURCE stream — see the note in planner_activity_screen.
        onRetry: () => ref.invalidate(allItemsAsTargetProvider),
        isEmpty: (items) =>
            !items.any((i) => i.status == ScheduleItemStatus.approved),
        emptyMessage: 'No approved items yet.',
        builder: (context, items) {
          final approved = items
              .where((i) => i.status == ScheduleItemStatus.approved)
              .toList();

          // Group by each item's OWN-timezone day (`calendarDayFor`, never the
          // viewer's — a "Tue 9:00" card must not file under Monday). UPCOMING
          // days rise to the top (soonest first); PAST days sink below
          // (most-recent first). Within a day, items read chronologically.
          // (Upcoming-first chosen 2026-08-26; day grouping added 2026-08-27.)
          final byDay = <String, List<ScheduleItem>>{};
          final dateFor = <String, DateTime>{};
          for (final item in approved) {
            final day = calendarDayFor(item);
            final key = dayKeyOf(day);
            dateFor[key] = day;
            byDay.putIfAbsent(key, () => []).add(item);
          }
          for (final list in byDay.values) {
            list.sort(
              (a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc),
            );
          }
          // yyyy-MM-dd keys sort lexicographically = chronologically, so the
          // today-split and the per-side ordering can work on the keys directly.
          final todayKey = dayKeyOf(DateTime.now());
          final upcomingKeys =
              byDay.keys.where((k) => k.compareTo(todayKey) >= 0).toList()
                ..sort();
          final pastKeys =
              byDay.keys.where((k) => k.compareTo(todayKey) < 0).toList()
                ..sort((a, b) => b.compareTo(a));
          final orderedKeys = [...upcomingKeys, ...pastKeys];

          _approvedCount = approved.length;
          // The highlighted card is force-built by expanding its day (below), so
          // the old flat-index jump is unnecessary — ensureVisible alone lands it.
          _highlightIndex = null;

          // The NEXT upcoming item (earliest future, no outcome) drives the hero
          // band and the primer — the same facts the old `upcoming` list carried.
          final now = DateTime.now().toUtc();
          ScheduleItem? nextItem;
          for (final item in approved) {
            if (item.outcome == null && item.scheduledInstantUtc.isAfter(now)) {
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
            initiallyExpandedKeys: {todayKey},
            forceExpandKey: forceKey,
            leading: [
              HeroBand(nextItem: nextItem),
              ReminderPrimerCard(hasUpcomingItems: hasUpcoming),
            ],
            groups: [
              for (final key in orderedKeys)
                DayGroupData(
                  key: key,
                  label: formatWallDate(context, dateFor[key]!),
                  // Today / Future plans / Past plans buckets. yyyy-MM-dd keys
                  // compare chronologically, so today is ==, future is >, past <.
                  section: key == todayKey
                      ? 'Today'
                      : (key.compareTo(todayKey) > 0
                            ? 'Future plans'
                            : 'Past plans'),
                  itemCount: byDay[key]!.length,
                  itemBuilder: (context, index) {
                    final item = byDay[key]![index];
                    return _OutcomeCard(
                      item: item,
                      highlighted: item.id == _highlighted,
                      // The key rides on the highlighted card only; that is all
                      // `ensureVisible` needs to find it.
                      cardKey: item.id == _highlighted ? _highlightKey : null,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _OutcomeCard extends ConsumerWidget {
  const _OutcomeCard({
    required this.item,
    this.highlighted = false,
    this.cardKey,
  });

  final ScheduleItem item;
  final bool highlighted;
  final Key? cardKey;

  /// A self-planned item has the same person as creator and target — no planner
  /// on the other end to notify.
  bool get _isSelfPlanned => item.createdByUid == item.targetUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outcome = item.outcome;

    return Card(
      key: cardKey,
      // Line work, never a fill: an orange filled surface is reserved for "a
      // schedule item is waiting on you" (UI-RULES.md §2.7), and "you tapped a
      // reminder for this one" is a different, much weaker claim. A primary
      // outline says *this one* without spending that signal.
      shape: highlighted
          ? RoundedRectangleBorder(
              borderRadius: Radii.md,
              side: BorderSide(
                color: context.colors.primary,
                width: Sizes.ruleWidth,
              ),
            )
          : null,
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
                // Archive lives in the card overflow, not inline: this list
                // scrolls, and an exposed control that makes a row vanish is a
                // mis-tap waiting to happen. Present only once an outcome is
                // recorded — a live item is hideable by no route at all.
                if (item.isManuallyArchivable) ArchiveMenuButton(item: item),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              formatInstant(context, item.scheduledInstantUtc, item.timezone),
            ),
            const SizedBox(height: Space.md),
            if (outcome == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Skipping is a legitimate outcome, so it gets the neutral
                  // secondary treatment — never red (UI-RULES.md §2.5).
                  OutlinedButton(
                    onPressed: () => _skip(context, ref),
                    child: const Text('Skip'),
                  ),
                  const SizedBox(width: Space.sm),
                  FilledButton(
                    onPressed: () => _markDone(context, ref),
                    child: const Text('Done'),
                  ),
                ],
              )
            else
              _outcomeLine(context, outcome),
          ],
        ),
      ),
    );
  }

  /// The recorded outcome. This used to be a second, private status→colour
  /// mapping that disagreed with the planner's view; both now read the one
  /// mapping in `status_style.dart` (UI-RULES.md §2.3).
  Widget _outcomeLine(BuildContext context, ScheduleOutcome outcome) {
    return Row(
      children: [
        StatusBadge.outcome(outcome.result, context),
        // Completed, but after its scheduled time — surfaced, never hidden. Line
        // work / muted text, not a doctrine fill: a late Done is still a Done.
        if (item.completionDelay case final delay?) ...[
          const SizedBox(width: Space.sm),
          Text(
            '${formatDurationMinutes(context, delay.inMinutes)} late',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
        if (outcome.skipReason case final reason?) ...[
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              reason,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Record completion, then fire the (best-effort) planner push. The write is
  /// the source of truth; the push is additive (see DECISIONS.md).
  ///
  /// The reminder needs no cancelling here: recording an outcome makes the item
  /// undesired, the item stream re-emits, and the reconciler cancels it. That is
  /// the point of driving reminders off the stream rather than off transitions.
  Future<void> _markDone(BuildContext context, WidgetRef ref) async {
    await ref
        .read(scheduleRepositoryProvider)
        .markDone(item.targetUid, item.id);
    // The planner push is skipped for a self-planned item (no one else to tell),
    // but the time-tracking prompt is NOT — self-planned items are exactly the
    // ones a user logs their own time against. So the early-out only guards the
    // notify; the Done→track hook below runs for every completed item.
    if (!_isSelfPlanned) {
      await ref
          .read(notificationEventNotifierProvider)
          .notify(
            event: NotifyEvent.outcome,
            targetUid: item.targetUid,
            itemId: item.id,
          );
    }
    if (!context.mounted) return;
    await promptLogFromDone(
      context,
      ref,
      taskName: item.title,
      sourceItemId: item.id,
      timezone: item.timezone,
    );
  }

  Future<void> _skip(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Skip this?'),
        content: TextField(
          controller: controller,
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
    if (confirmed == true) {
      await ref
          .read(scheduleRepositoryProvider)
          .markSkipped(item.targetUid, item.id, reason: controller.text);
      if (_isSelfPlanned) return; // no point notifying yourself
      await ref
          .read(notificationEventNotifierProvider)
          .notify(
            event: NotifyEvent.outcome,
            targetUid: item.targetUid,
            itemId: item.id,
          );
    }
  }
}
