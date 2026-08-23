import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/calendar_grouping.dart';

/// Which of the **existing** two mappings applies to an item.
///
/// This is a selection, not a third mapping: once an outcome exists it replaces
/// the approval status, because "Done" strictly implies "Approved" and showing
/// both states the same fact twice. `planner_activity_screen.dart` makes the
/// identical choice inline; naming it here keeps the calendar's four call sites
/// from drifting from each other.
StatusStyle entryStyle(BuildContext context, ScheduleItem item) {
  final outcome = item.outcome;
  return outcome == null
      ? statusStyle(context, item.status)
      : outcomeStyle(context, outcome.result);
}

/// One item's dot in a day cell.
///
/// Its colour comes from `status_style.dart` and nowhere else — a dot is
/// *state*, so under §2.7 its fill belongs to the file that owns state. This
/// file never names an `attention*` role, so the firewall lint needs no
/// exemption for the calendar.
///
/// The neutral treatment has a transparent background by design (rejected,
/// withdrawn, skipped), so it draws as a ring rather than as a disc. That is
/// the same "the label differentiates, the colour does not have to" logic the
/// neutral badge uses, one size down.
class CalendarMarkerDot extends StatelessWidget {
  const CalendarMarkerDot({super.key, required this.item});

  final ScheduleItem item;

  @override
  Widget build(BuildContext context) {
    final style = entryStyle(context, item);
    final isNeutral = style.treatment == StatusTreatment.neutral;
    return Container(
      width: Sizes.calendarMarkerDot,
      height: Sizes.calendarMarkerDot,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isNeutral ? null : style.background,
        border: isNeutral
            ? Border.all(color: style.border!, width: Sizes.hairline)
            : null,
      ),
    );
  }
}

/// The marker strip under a day number.
///
/// Capped at [_maxDots] with a count for the remainder: a cell that fills edge
/// to edge with dots stops distinguishing a busy day from a full one, which is
/// the only thing the strip is for.
class CalendarMarkerRow extends StatelessWidget {
  const CalendarMarkerRow({super.key, required this.entries});

  final List<CalendarEntry> entries;

  static const _maxDots = 3;

  @override
  Widget build(BuildContext context) {
    // Reserved even when empty, so a cell does not change height as the month
    // pages past — a grid that reflows under the finger is hard to aim at.
    if (entries.isEmpty) {
      return const SizedBox(height: Sizes.calendarMarkerRow);
    }

    final shown = entries.take(_maxDots).toList();
    final overflow = entries.length - shown.length;

    // FittedBox(scaleDown) guarantees the strip can never overflow the cell's
    // width, however narrow the screen — the "Right overflowed by N pixels"
    // stripe was this Row exceeding the ~43dp cell. Gaps sit BETWEEN dots only
    // (no trailing gap), and dots are capped at three.
    return SizedBox(
      height: Sizes.calendarMarkerRow,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const SizedBox(width: Space.xs),
              CalendarMarkerDot(item: shown[i].item),
            ],
            if (overflow > 0) ...[
              const SizedBox(width: Space.xs),
              Text(
                '+$overflow',
                style: context.text.labelSmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
