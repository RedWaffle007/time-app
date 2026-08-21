import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../../home/presentation/account_button.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../application/calendar_grouping.dart';
import '../application/calendar_providers.dart';
import 'calendar_day_view.dart';
import 'calendar_entry_card.dart';
import 'calendar_item_sheet.dart';
import 'calendar_markers.dart';

/// The three ways to look at the same items.
///
/// [month] and [week] are `table_calendar` grids; [day] is our own hour rail
/// (see `calendar_day_view.dart` for why it cannot be the package's).
enum CalendarViewMode { month, week, day }

/// **A view over the item stream — it stores nothing.**
///
/// Every item here comes from `myItemsAsTargetProvider` and
/// `myItemsAsPlannerProvider`, which existed before this screen. No collection,
/// no document, no rule, no index, no permission was added for it
/// (DECISIONS.md → "In-app calendar").
///
/// Top-level and pushed, reached from the account menu, exactly like Archived —
/// a cross-role view belongs to no tab. It is deliberately not a fourth nav
/// destination: the bar's three tabs are the three stances in the delegation
/// loop, and a calendar is a lens over all three rather than a fourth one.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// How far the grid may be paged. Wide enough that nobody hits the wall in
  /// normal use, bounded because `TableCalendar` asserts `focusedDay` is inside
  /// it and an unbounded range would build pages forever.
  static const _yearsEitherSide = 5;

  late DateTime _focusedDay;
  late DateTime _selectedDay;
  CalendarViewMode _mode = CalendarViewMode.month;

  /// Handed to us by `onCalendarCreated`, so the header chevrons can page the
  /// same controller the swipe gesture uses. Null in [CalendarViewMode.day],
  /// where there is no grid — the chevrons move the selected date instead.
  PageController? _pageController;

  @override
  void initState() {
    super.initState();
    // UTC-midnight keys throughout, matching `table_calendar`'s own
    // `normalizeDate` and `calendarDayFor` — so a day compares equal as a map
    // key, as an `isSameDay` argument and as a grid focus.
    final today = calendarDayKey(DateTime.now());
    _focusedDay = today;
    _selectedDay = today;
  }

  DateTime get _firstDay =>
      DateTime.utc(DateTime.now().year - _yearsEitherSide, 1, 1);
  DateTime get _lastDay =>
      DateTime.utc(DateTime.now().year + _yearsEitherSide, 12, 31);

  /// The week starts where the LOCALE says, never at a constant. Material's
  /// index is 0 = Sunday; `StartingDayOfWeek` starts at Monday, hence the shift.
  StartingDayOfWeek _startingDayOfWeek(BuildContext context) {
    final index = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    return StartingDayOfWeek.values[(index + 6) % 7];
  }

  void _goToToday() {
    final today = calendarDayKey(DateTime.now());
    setState(() {
      _selectedDay = today;
      _focusedDay = today;
    });
  }

  /// Page backwards or forwards by whatever the current view spans.
  ///
  /// In a grid that is the `PageController` the swipe gesture also drives, so
  /// the chevrons and the swipe cannot disagree. In the day view there is no
  /// controller, so it steps the selected date — and the focused day with it,
  /// or returning to a grid would land on the month the user left.
  void _page(int direction) {
    if (_mode == CalendarViewMode.day) {
      setState(() {
        _selectedDay = calendarDayKey(
          _selectedDay.add(Duration(days: direction)),
        );
        _focusedDay = _selectedDay;
      });
      return;
    }
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final target = controller.page == null
        ? null
        : (controller.page!.round() + direction).toDouble();
    if (target == null) return;
    controller.animateToPage(
      target.toInt(),
      duration: Motion.normal,
      curve: Motion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final indexAsync = ref.watch(calendarDayIndexProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(
            tooltip: 'Jump to today',
            icon: const Icon(AppIcons.today),
            onPressed: _goToToday,
          ),
          const AccountButton(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // The real schedule builder, seeded with the day in view — not a
        // parallel create flow. See `Routes.calendarNewFor`.
        onPressed: () => context.push(Routes.calendarNewFor(_selectedDay)),
        icon: const Icon(AppIcons.add),
        label: const Text('Plan an item'),
      ),
      body: AsyncView<Map<DateTime, List<CalendarEntry>>>(
        value: indexAsync,
        // Retry the SOURCE streams. Both derived providers would recompute a
        // filter without reconnecting the Firestore listener that failed.
        onRetry: () {
          ref.invalidate(allItemsAsTargetProvider);
          ref.invalidate(allItemsAsPlannerProvider);
        },
        builder: (context, byDay) => _buildCalendar(context, byDay),
      ),
    );
  }

  Widget _buildCalendar(
    BuildContext context,
    Map<DateTime, List<CalendarEntry>> byDay,
  ) {
    final selectedEntries = entriesOn(byDay, _selectedDay);

    return Column(
      children: [
        _ModeToggle(
          mode: _mode,
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        _PeriodHeader(
          title: _mode == CalendarViewMode.day
              ? formatDayHeadingShort(context, _selectedDay)
              : formatMonthYear(context, _focusedDay),
          onPrevious: () => _page(-1),
          onNext: () => _page(1),
        ),
        if (_mode != CalendarViewMode.day) _grid(byDay),
        Divider(height: Space.lg, color: context.colors.outlineVariant),
        Expanded(
          child: _mode == CalendarViewMode.day
              ? CalendarDayView(
                  day: _selectedDay,
                  entries: selectedEntries,
                  onEntryTap: (entry) => showCalendarItemSheet(context, entry),
                )
              : _Agenda(
                  day: _selectedDay,
                  entries: selectedEntries,
                  onEntryTap: (entry) => showCalendarItemSheet(context, entry),
                ),
        ),
      ],
    );
  }

  Widget _grid(Map<DateTime, List<CalendarEntry>> byDay) {
    return TableCalendar<CalendarEntry>(
      locale: Localizations.localeOf(context).toString(),
      firstDay: _firstDay,
      lastDay: _lastDay,
      focusedDay: _focusedDay,
      currentDay: calendarDayKey(DateTime.now()),
      calendarFormat: _mode == CalendarViewMode.week
          ? CalendarFormat.week
          : CalendarFormat.month,
      startingDayOfWeek: _startingDayOfWeek(context),
      rowHeight: Sizes.calendarCellHeight,
      // Our own header sits above this one, with the mode toggle — see
      // `_PeriodHeader`. The package's would be a second title and a second
      // pair of chevrons for the same grid.
      headerVisible: false,
      availableGestures: AvailableGestures.horizontalSwipe,
      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
      onDaySelected: (selected, focused) => setState(() {
        _selectedDay = calendarDayKey(selected);
        _focusedDay = focused;
      }),
      // Long-press a date to plan on it — the calendar convention, and it
      // reaches the same real builder the FAB does.
      onDayLongPressed: (selected, _) =>
          context.push(Routes.calendarNewFor(selected)),
      // `setState`, not a bare assignment: our header sits OUTSIDE the grid
      // (`_PeriodHeader`), so a swipe that changed the page without a rebuild
      // would leave the title naming the month the user just swiped away from.
      //
      // Stored EXACTLY as handed over, deliberately unnormalized.
      // `TableCalendarBase` sets its own `_focusedDay` to this same value
      // immediately before calling us, and its `didUpdateWidget` re-animates
      // whenever the two differ — so normalizing here would make every swipe
      // look like an external jump and page the grid a second time.
      onPageChanged: (focused) => setState(() => _focusedDay = focused),
      onCalendarCreated: (controller) => _pageController = controller,
      // EVERY cell is drawn here rather than by the package, and the reason is
      // the standing worldwide requirement: `table_calendar`'s own builders
      // interpolate `'${day.day}'`, which is Latin digits, and would silently
      // render the wrong numerals in a locale that has its own. Ours go through
      // `formatDayOfMonth` like every other date in the app (UI-RULES.md §6.10).
      calendarBuilders: CalendarBuilders<CalendarEntry>(
        dowBuilder: (context, day) => Center(
          child: Text(
            formatWeekdayShort(context, day),
            style: context.text.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
        defaultBuilder: (context, day, _) => _DayCell(
          day: day,
          entries: entriesOn(byDay, day),
        ),
        todayBuilder: (context, day, _) => _DayCell(
          day: day,
          entries: entriesOn(byDay, day),
          isToday: true,
        ),
        selectedBuilder: (context, day, _) => _DayCell(
          day: day,
          entries: entriesOn(byDay, day),
          isSelected: true,
        ),
        outsideBuilder: (context, day, _) => _DayCell(
          day: day,
          entries: entriesOn(byDay, day),
          isOutside: true,
        ),
        disabledBuilder: (context, day, _) => _DayCell(
          day: day,
          entries: const [],
          isOutside: true,
        ),
      ),
    );
  }
}

/// Month / Week / Day. A `SegmentedButton` because these are three views of one
/// thing and exactly one is active — the meaning the control already carries, so
/// nothing here has to encode selection a second time.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final CalendarViewMode mode;
  final ValueChanged<CalendarViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.sm,
      ),
      child: SegmentedButton<CalendarViewMode>(
        segments: const [
          ButtonSegment(
            value: CalendarViewMode.month,
            icon: Icon(AppIcons.viewMonth),
            label: Text('Month'),
          ),
          ButtonSegment(
            value: CalendarViewMode.week,
            icon: Icon(AppIcons.viewWeek),
            label: Text('Week'),
          ),
          ButtonSegment(
            value: CalendarViewMode.day,
            icon: Icon(AppIcons.viewDay),
            label: Text('Day'),
          ),
        ],
        selected: {mode},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// The period title with its two chevrons. Structure, so line work and text
/// only — no fill (UI-RULES.md §2.7).
class _PeriodHeader extends StatelessWidget {
  const _PeriodHeader({
    required this.title,
    required this.onPrevious,
    required this.onNext,
  });

  final String title;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous',
            icon: const Icon(AppIcons.previousPeriod),
            onPressed: onPrevious,
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: context.text.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next',
            icon: const Icon(AppIcons.nextPeriod),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

/// One day in the month or week grid.
///
/// The whole cell is the tap target — [Sizes.calendarCellHeight] is 48 for that
/// reason, and it is the §7 floor rather than a layout preference.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.entries,
    this.isToday = false,
    this.isSelected = false,
    this.isOutside = false,
  });

  final DateTime day;
  final List<CalendarEntry> entries;
  final bool isToday;
  final bool isSelected;
  final bool isOutside;

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;

    // Selected is a filled green disc; today is a green ring. Both are the
    // "current choice / action" register green owns (§2.1), and neither spends
    // the orange that has to keep meaning "waiting on you".
    final Color numberColor = isSelected
        ? cs.onPrimary
        : isToday
            ? cs.primary
            : isOutside
                ? cs.onSurfaceVariant
                : cs.onSurface;

    return Container(
      margin: const EdgeInsets.all(Space.xs),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? cs.primary : null,
        border: isToday && !isSelected
            ? Border.all(color: cs.primary, width: Sizes.hairline)
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatDayOfMonth(context, day),
            style: context.text.bodyMedium?.copyWith(color: numberColor),
          ),
          // Outside days carry no markers: their items belong to the month
          // either side and are shown properly when that month is in view.
          // Drawing them here doubles every item at a month boundary.
          CalendarMarkerRow(entries: isOutside ? const [] : entries),
        ],
      ),
    );
  }
}

/// The selected day's items, under the month or week grid.
class _Agenda extends StatelessWidget {
  const _Agenda({
    required this.day,
    required this.entries,
    required this.onEntryTap,
  });

  final DateTime day;
  final List<CalendarEntry> entries;
  final void Function(CalendarEntry entry) onEntryTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: Space.xxxl),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: SectionHeader(formatDayHeadingShort(context, day)),
        ),
        if (entries.isEmpty)
          const _FreeDay()
        else
          for (final entry in entries)
            CalendarEntryCard(entry: entry, onTap: () => onEntryTap(entry)),
      ],
    );
  }
}

/// A day with nothing on it — the §6.5 empty-state recipe.
///
/// Its own glyph rather than the generic inbox: an empty inbox and a free day
/// are different messages, and a free day is a good one.
class _FreeDay extends StatelessWidget {
  const _FreeDay();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: Space.screenForm,
      child: Column(
        children: [
          Icon(
            AppIcons.emptyDay,
            size: Sizes.emptyStateIcon,
            color: context.colors.primary,
          ),
          const SizedBox(height: Space.md),
          Text(
            'Nothing planned for this day.',
            style: context.text.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
