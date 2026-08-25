import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../plan/application/plan_intent.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/calendar_grouping.dart';

/// The detail sheet for a tapped calendar entry.
///
/// **It views; it does not act, and it does not edit.**
///
/// *Does not edit* is not a shortcut — it is what the deployed rules permit.
/// `firestore.rules` whitelists the target's approve / reject / done / skip and
/// the planner's withdraw, and nothing else: `title` and `scheduledInstantUtc`
/// are immutable after create, and the block says so in terms ("Planner edit is
/// still deferred"). `ScheduleRepository` has no `updateItem` to call. No
/// disabled Edit control appears here either — a stub would imply the feature is
/// one tap away when it is a rules deploy away.
///
/// *Does not act* is a choice, and the reason is `OutcomeScreen`'s own: Done and
/// Skip live on the screen that owns them, and two renderings of one item's
/// controls are two things to keep in step. So the sheet's primary action
/// **routes** — and `Routes.planForItem` already scrolls to the card and
/// outlines it, so the tap still ends one gesture from closing the loop.
Future<void> showCalendarItemSheet(
  BuildContext context,
  CalendarEntry entry,
) {
  return showModalBottomSheet<void>(
    context: context,
    // Long notes on a small screen: let it grow and scroll rather than clip.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _CalendarItemSheet(entry: entry),
  );
}

class _CalendarItemSheet extends ConsumerWidget {
  const _CalendarItemSheet({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = entry.item;
    final isMine = entry.side == CalendarSide.mine;

    // The other end of the item: who it is for, or who planned it.
    //
    // Resolved only when there IS an other end. A self-planned item has the
    // same person at both ends, so the name is never rendered — and opening a
    // profile stream to discard its result is a listener nobody needed.
    final isSelfPlanned = item.createdByUid == item.targetUid;
    final counterpartUid = isMine ? item.createdByUid : item.targetUid;
    final counterpartName = isSelfPlanned
        ? null
        : ref.watch(profileByUidProvider(counterpartUid)).value?.name;

    return SafeArea(
      child: SingleChildScrollView(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(item.title, style: context.text.titleLarge),
                ),
                const SizedBox(width: Space.sm),
                if (item.outcome case final outcome?)
                  StatusBadge.outcome(outcome.result, context)
                else
                  StatusBadge.status(item.status, context),
              ],
            ),
            const SizedBox(height: Space.lg),

            // The full instant, in the item's own zone — the same rendering the
            // Activity and My Schedule cards use.
            _DetailRow(
              icon: AppIcons.time,
              text: formatInstant(
                  context, item.scheduledInstantUtc, item.timezone),
            ),
            _DetailRow(icon: AppIcons.timezone, text: item.timezone),

            // Who the other party is. Omitted entirely when there isn't one —
            // a self-planned item has nobody on the other end, and "planned by
            // you, for you" is noise.
            if (!isSelfPlanned)
              _DetailRow(
                icon: AppIcons.person,
                text: isMine
                    ? 'Planned by ${counterpartName ?? 'someone in your group'}'
                    : 'For ${counterpartName ?? 'them'} — their local time',
              ),

            if (item.note case final note? when note.trim().isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              // Quoted user content is distinguished by colour, never italics
              // (UI-RULES.md §3).
              Text(
                note,
                style: context.text.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],

            // Why it was rejected, or why it was skipped. Same shape as the
            // Activity card's reason line.
            if (_reason(item) case final reason?) ...[
              const SizedBox(height: Space.lg),
              Text(
                reason,
                style: context.text.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],

            const SizedBox(height: Space.xl),
            FilledButton.icon(
              onPressed: () {
                // Pop the sheet BEFORE navigating: the destination is a
                // location inside the tab shell, and leaving a modal route on
                // top of a `go()` would drop the user back onto a sheet
                // belonging to a screen they have left.
                Navigator.of(context).pop();
                _open(context, ref, item, isMine: isMine);
              },
              icon: const Icon(AppIcons.openRow),
              label: Text(isMine ? 'Open in My Schedule' : 'Open in Activity'),
            ),
          ],
        ),
      ),
    );
  }

  /// Route to the screen that owns this item's controls.
  ///
  /// `go`, not `push`: both destinations are inside the tab shell, so go_router
  /// selects the owning branch and the nav bar comes with it. That is the whole
  /// point of the D2/D11 refactor and is easy to lose by pushing.
  void _open(
    BuildContext context,
    WidgetRef ref,
    ScheduleItem item, {
    required bool isMine,
  }) {
    // A pending item targeted at you belongs in the approvals queue, where
    // Approve/Reject live; an approved one belongs on My Schedule, singled out
    // (highlight → scroll + outline). Both are inside the Plan pillar. The
    // sub-tab/highlight is set on `planIntentProvider` BEFORE `go` — the
    // deterministic signal the shell listens to (query params were unreliable).
    if (isMine) {
      if (item.status == ScheduleItemStatus.pending) {
        context.go(Routes.approvals);
      } else {
        ref.read(planIntentProvider.notifier).highlightItem(item.id);
        context.go(Routes.plan);
      }
    } else {
      ref.read(planIntentProvider.notifier).openTab(PlanTab.activity);
      context.go(Routes.plan);
    }
  }

  String? _reason(ScheduleItem item) => switch (item) {
        ScheduleItem(
          status: ScheduleItemStatus.rejected,
          :final rejectionReason?
        ) =>
          'Reason: $rejectionReason',
        ScheduleItem(outcome: ScheduleOutcome(:final skipReason?)) =>
          'Reason: $skipReason',
        _ => null,
      };
}

/// One labelled fact. Icons are structural here, so they take their colour from
/// the theme rather than an inline value (UI-RULES.md §6.6).
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: Sizes.inlineIcon, color: context.colors.onSurfaceVariant),
          const SizedBox(width: Space.md),
          Expanded(child: Text(text, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}
