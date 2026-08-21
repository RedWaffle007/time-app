import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
import '../../archive/presentation/archive_menu_button.dart';
import '../../home/presentation/account_button.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../reminders/presentation/reminder_primer.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import 'hero_band.dart';

/// The target's approved items — where they mark Done or Skip, and where a
/// tapped reminder lands.
///
/// A reminder carries only the item id (`Routes.outcomeForItem`), and this
/// screen resolves it: the matching card is scrolled into view and outlined for
/// a few seconds. Deliberately not a separate detail screen — this list already
/// holds the Done and Skip controls, so the tap ends one gesture from closing
/// the loop, and there is no second rendering of an item to keep in step.
class OutcomeScreen extends ConsumerStatefulWidget {
  const OutcomeScreen({super.key, this.highlightItemId});

  /// From `?item=` — the item a reminder was tapped for. Null in every other
  /// route onto this screen.
  final String? highlightItemId;

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

  /// Keys for the cards, so the highlighted one can be scrolled to. Only ever
  /// holds the one id we care about — a key per row in a long list is waste.
  final _highlightKey = GlobalKey();
  bool _scrolled = false;

  static const _highlightDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _applyHighlight(widget.highlightItemId);
  }

  @override
  void didUpdateWidget(OutcomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightItemId != oldWidget.highlightItemId) {
      _applyHighlight(widget.highlightItemId);
    }
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  void _applyHighlight(String? itemId) {
    _fade?.cancel();
    _highlighted = itemId;
    _scrolled = false;
    if (itemId == null) return;
    _fade = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = null);
    });
  }

  /// Runs after the frame that first built the highlighted card, because
  /// `ensureVisible` needs a laid-out element. Once only — re-scrolling on every
  /// rebuild would fight the user the moment they scrolled away themselves.
  void _scrollToHighlightAfterBuild() {
    if (_scrolled) return;
    _scrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: 0.2,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(myItemsAsTargetProvider);
    final pendingCount = itemsAsync.value
            ?.where((i) => i.status == ScheduleItemStatus.pending)
            .length ??
        0;

    return Scaffold(
      appBar: AppBar(
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
          const AccountButton(),
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
              .toList()
            ..sort((a, b) => a.scheduledInstantUtc.compareTo(b.scheduledInstantUtc));

          // The primer's precondition: something is actually going to need a
          // reminder. Matches `desiredReminders`' rule, so the card never claims
          // a reminder is missing for an item that would not have had one.
          final now = DateTime.now().toUtc();
          final upcoming = approved
              .where((i) =>
                  i.outcome == null && i.scheduledInstantUtc.isAfter(now))
              .toList();
          final hasUpcoming = upcoming.isNotEmpty;

          return ListView(
            children: [
              // `approved` is already sorted by instant, so the first upcoming
              // item IS the next one. The band reads the same list the cards
              // do — it never queries separately, so it cannot disagree.
              HeroBand(nextItem: upcoming.isEmpty ? null : upcoming.first),
              ReminderPrimerCard(hasUpcomingItems: hasUpcoming),
              for (final item in approved)
                _OutcomeCard(
                  item: item,
                  highlighted: item.id == _highlighted,
                  // The key rides on the highlighted card only; that is all
                  // `ensureVisible` needs to find it.
                  cardKey: item.id == _highlighted ? _highlightKey : null,
                  onNeedsScroll: _scrollToHighlightAfterBuild,
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
    this.onNeedsScroll,
  });

  final ScheduleItem item;
  final bool highlighted;
  final Key? cardKey;
  final VoidCallback? onNeedsScroll;

  /// A self-planned item has the same person as creator and target — no planner
  /// on the other end to notify.
  bool get _isSelfPlanned => item.createdByUid == item.targetUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outcome = item.outcome;
    if (highlighted) onNeedsScroll?.call();

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
            Text(formatInstant(context, item.scheduledInstantUtc, item.timezone)),
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
                    onPressed: () => _markDone(ref),
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
        if (outcome.skipReason case final reason?) ...[
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              reason,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
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
  Future<void> _markDone(WidgetRef ref) async {
    await ref.read(scheduleRepositoryProvider).markDone(item.targetUid, item.id);
    if (_isSelfPlanned) return; // no point notifying yourself
    await ref.read(notificationEventNotifierProvider).notify(
          event: NotifyEvent.outcome,
          targetUid: item.targetUid,
          itemId: item.id,
        );
  }

  Future<void> _skip(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Skip this?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'Your planner will see this',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(scheduleRepositoryProvider).markSkipped(
            item.targetUid,
            item.id,
            reason: controller.text,
          );
      if (_isSelfPlanned) return; // no point notifying yourself
      await ref.read(notificationEventNotifierProvider).notify(
            event: NotifyEvent.outcome,
            targetUid: item.targetUid,
            itemId: item.id,
          );
    }
  }
}
