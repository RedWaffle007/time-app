import 'package:flutter/material.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/calendar_grouping.dart';
import 'calendar_entry_card.dart';

/// The day view: **an hour rail, not a proportional grid.**
///
/// Every other calendar app draws a day as blocks whose height is the event's
/// duration. We cannot, and the reason is in the model rather than in the
/// effort: `ScheduleItem` carries an INSTANT, not a span — there is no duration
/// field, and whether to add one is an open decision belonging to the goals
/// phase (CLAUDE.md, "Carried into the goals phase"). A block sized to look like
/// an hour would be asserting a duration nothing in the app knows.
///
/// So each hour is a row, items are pinned beside the hour they fall in, and a
/// row grows to whatever its cards need. An empty hour stays a square of
/// whitespace, which is what makes a gap in the day legible as a gap.
///
/// If `durationMinutes` ever lands, **this file is the one that changes.**
class CalendarDayView extends StatefulWidget {
  const CalendarDayView({
    super.key,
    required this.day,
    required this.entries,
    required this.onEntryTap,
  });

  /// The day being shown, as a UTC-midnight key.
  final DateTime day;

  /// Everything on that day, already in draw order.
  final List<CalendarEntry> entries;

  final void Function(CalendarEntry entry) onEntryTap;

  @override
  State<CalendarDayView> createState() => _CalendarDayViewState();
}

class _CalendarDayViewState extends State<CalendarDayView> {
  static const _hoursInDay = 24;

  /// Anchors the row the rail should open on, so it can be scrolled to once the
  /// list has laid out. Same technique `OutcomeScreen` uses for a tapped
  /// reminder — `ensureVisible` needs a real element, not an offset guess, and
  /// rows here are variable height because they hold cards.
  final _openingRowKey = GlobalKey();
  bool _scrolled = false;

  @override
  void didUpdateWidget(CalendarDayView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new day is a new opening hour. Without this, paging to tomorrow would
    // keep yesterday's scroll offset.
    if (oldWidget.day != widget.day) _scrolled = false;
  }

  /// Once per day shown. Re-scrolling on every rebuild would fight the user the
  /// moment they scrolled away themselves.
  void _scrollToOpeningHourAfterBuild() {
    if (_scrolled) return;
    _scrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _openingRowKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: 0.1,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final byHour = groupEntriesByHour(widget.entries);

    final now = DateTime.now();
    final isToday = widget.day == calendarDayKey(now);
    final openingHour = openingHourFor(
      entries: widget.entries,
      isToday: isToday,
      nowHour: now.hour,
    );

    _scrollToOpeningHourAfterBuild();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Space.xxxl),
      itemCount: _hoursInDay,
      itemBuilder: (context, hour) {
        return _HourRow(
          key: hour == openingHour ? _openingRowKey : null,
          hour: hour,
          entries: byHour[hour] ?? const [],
          isCurrentHour: isToday && hour == now.hour,
          onEntryTap: widget.onEntryTap,
        );
      },
    );
  }
}

class _HourRow extends StatelessWidget {
  const _HourRow({
    super.key,
    required this.hour,
    required this.entries,
    required this.isCurrentHour,
    required this.onEntryTap,
  });

  final int hour;
  final List<CalendarEntry> entries;
  final bool isCurrentHour;
  final void Function(CalendarEntry entry) onEntryTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      formatHourOfDay(context, hour),
      textAlign: TextAlign.right,
      style: context.text.labelSmall?.copyWith(
        // The current hour is the one piece of orientation the rail owes a user
        // scrolling their own day. Line work and text only — the whole rail is
        // structure, and structure is never a fill (UI-RULES.md §2.7).
        color: isCurrentHour
            ? context.colors.primary
            : context.colors.onSurfaceVariant,
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Sizes.calendarHourRow),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Sizes.calendarHourGutter,
            child: Padding(
              // Nudged down so the label sits on the rule that starts the hour
              // rather than floating above it.
              padding: const EdgeInsets.only(top: Space.sm, right: Space.sm),
              child: label,
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: context.colors.outlineVariant,
                    width: Sizes.hairline,
                  ),
                ),
              ),
              child: entries.isEmpty
                  ? const SizedBox(height: Sizes.calendarHourRow)
                  : Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xs),
                      child: Column(
                        children: [
                          for (final entry in entries)
                            CalendarEntryCard(
                              entry: entry,
                              onTap: () => onEntryTap(entry),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
