import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:time_app/core/theme/app_icons.dart';

import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/calendar/application/calendar_grouping.dart';
import 'package:time_app/features/calendar/application/calendar_providers.dart';
import 'package:time_app/features/calendar/presentation/calendar_screen.dart';
import 'package:time_app/features/scheduling/domain/schedule_item.dart';

/// **What the pure tests cannot reach.**
///
/// `calendar_grouping_test.dart` pins which day an item belongs to. This file
/// pins the things that only exist once the widget is built: that the grid
/// mounts at all (`TableCalendar` asserts on its own `focusedDay` bounds, and
/// the screen composes it inside a `Column` with an `Expanded` sibling), that
/// selecting a day moves the agenda, that the mode toggle swaps in the hour
/// rail — and, most importantly, that day numbers are LOCALIZED.
///
/// That last one is the reason every cell in this app is drawn by our builder
/// rather than the package's: `table_calendar` renders cells with
/// `'${day.day}'`, which is Latin digits, and in a locale with its own numerals
/// that is a silent regression of the standing worldwide requirement — nothing
/// throws, nothing logs, the grid just quietly stops being localized.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  const kolkata = 'Asia/Kolkata';

  ScheduleItem item({
    required String id,
    required DateTime instantUtc,
    String title = 'Morning run',
    ScheduleItemStatus status = ScheduleItemStatus.approved,
  }) {
    return ScheduleItem(
      id: id,
      targetUid: 'me',
      createdByUid: 'me',
      groupId: '',
      title: title,
      localWallTime: '',
      timezone: kolkata,
      scheduledInstantUtc: instantUtc,
      status: status,
    );
  }

  /// The calendar screen with its data supplied directly.
  ///
  /// [calendarEntriesProvider] is the override point on purpose: it is the seam
  /// between the item streams and everything the calendar does with them, so a
  /// test needs no Firestore and the screen under test is the real one.
  /// `currentUidProvider` is pinned to null so the AppBar's account button
  /// short-circuits instead of opening a stream.
  Widget harness(List<CalendarEntry> entries, {Locale? locale}) {
    return ProviderScope(
      overrides: [
        currentUidProvider.overrideWithValue(null),
        calendarEntriesProvider.overrideWithValue(AsyncData(entries)),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('en'), Locale('bn')],
        home: const CalendarScreen(),
      ),
    );
  }

  List<CalendarEntry> entriesFor(List<ScheduleItem> items) =>
      calendarEntries(asTarget: items, asPlanner: const [], viewerUid: 'me');

  /// The cell the grid opens on: the VIEWER's today.
  ///
  /// Deliberately the device's date rather than the fixture zone's, because
  /// that is what the screen selects on launch. The two genuinely differ for
  /// part of every day — which is the whole point of the design: the GRID is
  /// the viewer's calendar, and an ITEM lands on the date its own card prints.
  DateTime viewerToday() => calendarDayKey(DateTime.now());

  /// An instant that renders at 09:00 Kolkata on [day], so the item's card date
  /// is [day] and it files under that cell.
  DateTime nineAmOn(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day, 3, 30);

  testWidgets('the month grid mounts and shows today', (tester) async {
    await tester.pumpWidget(harness(const []));
    await tester.pumpAndSettle();

    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Month'), findsOneWidget);
    expect(find.text('Week'), findsOneWidget);
    expect(find.text('Day'), findsOneWidget);

    // The heading names the focused month, through the one date/time helper.
    final now = DateTime.now();
    expect(find.text(DateFormat.yMMMM('en').format(now)), findsOneWidget);

    // A free day says so with its own glyph, not the generic empty inbox.
    expect(find.text('Nothing planned for this day.'), findsOneWidget);
  });

  testWidgets('an item on today appears in the agenda under the grid', (
    tester,
  ) async {
    final today = viewerToday();
    await tester.pumpWidget(
      harness(
        entriesFor([
          item(id: 'a', instantUtc: nineAmOn(today), title: 'Morning run'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Morning run'), findsOneWidget);
    expect(find.text('Nothing planned for this day.'), findsNothing);
    // Rendered with the ONE status mapping, not a local switch.
    expect(find.text('Approved'), findsOneWidget);
  });

  testWidgets('an item on another day is NOT shown until that day is selected', (
    tester,
  ) async {
    final today = viewerToday();
    // A MID-MONTH day (never today), in the same grid but not the opening cell.
    // Mid-month is deliberate: a grid's outside days are the boundary days of
    // the ADJACENT months (late 20s/30s of the previous, 1–~7 of the next), so
    // only a day number near a month edge can appear twice — the 15th/16th of
    // THIS month is always a single, unambiguous cell. (Picking today+2 broke
    // when the run date made the target day collide with an outside-day number,
    // e.g. Jul 28 in the Aug 2026 grid.)
    final mid = DateTime(today.year, today.month, 15);
    final other = mid.day == today.day
        ? DateTime(today.year, today.month, 16)
        : mid;

    await tester.pumpWidget(
      harness(
        entriesFor([
          item(id: 'a', instantUtc: nineAmOn(other), title: 'Gym session'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Gym session'), findsNothing);
    expect(find.text('Nothing planned for this day.'), findsOneWidget);

    // Tap that date in the grid — the mid-month number is a single cell.
    final dayNumber = DateFormat.d('en').format(other);
    await tester.tap(find.text(dayNumber).first);
    await tester.pumpAndSettle();

    expect(find.text('Gym session'), findsOneWidget);
  });

  testWidgets('switching to Day swaps the grid for the hour rail', (
    tester,
  ) async {
    final today = viewerToday();
    await tester.pumpWidget(
      harness(
        entriesFor([
          item(id: 'a', instantUtc: nineAmOn(today), title: 'Morning run'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Day'));
    await tester.pumpAndSettle();

    // The rail opened on the item's OWN hour — 09:00 in the fixture zone — not
    // on midnight and not on the wall clock. `openingHourFor` decides that, and
    // the scroll is what makes it visible; a `ListView.builder` this far down
    // would not even have built the row otherwise.
    expect(
      find.text(DateFormat.j('en').format(DateTime(2000, 1, 1, 9))),
      findsWidgets,
    );
    // The item is still there, now pinned beside that hour.
    expect(find.text('Morning run'), findsOneWidget);
    // The heading switched from a month to that day.
    expect(find.text(DateFormat.MMMEd('en').format(today)), findsOneWidget);
  });

  testWidgets('chevrons page the grid and Today comes back', (tester) async {
    await tester.pumpWidget(harness(const []));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final thisMonth = DateFormat.yMMMM('en').format(now);
    // Day 15, so adding a month can never skip one via a short-month rollover.
    final nextMonth = DateFormat.yMMMM(
      'en',
    ).format(DateTime(now.year, now.month + 1, 15));

    expect(find.text(thisMonth), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.nextPeriod));
    await tester.pumpAndSettle();
    // The header lives OUTSIDE the grid, so this only holds because
    // `onPageChanged` rebuilds — the exact thing a bare assignment would miss.
    expect(find.text(nextMonth), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.previousPeriod));
    await tester.pumpAndSettle();
    expect(find.text(thisMonth), findsOneWidget);

    // Two months out, then home in one tap.
    await tester.tap(find.byIcon(AppIcons.nextPeriod));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.nextPeriod));
    await tester.pumpAndSettle();
    expect(find.text(thisMonth), findsNothing);

    await tester.tap(find.byIcon(AppIcons.today));
    await tester.pumpAndSettle();
    expect(find.text(thisMonth), findsOneWidget);
  });

  testWidgets('Week keeps the grid and the agenda, Day drops the grid', (
    tester,
  ) async {
    final today = viewerToday();
    await tester.pumpWidget(
      harness(
        entriesFor([
          item(id: 'a', instantUtc: nineAmOn(today), title: 'Morning run'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TableCalendar<CalendarEntry>), findsOneWidget);

    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    // Still a grid — a week is one row of it — and still the day's agenda.
    expect(find.byType(TableCalendar<CalendarEntry>), findsOneWidget);
    expect(find.text('Morning run'), findsOneWidget);

    await tester.tap(find.text('Day'));
    await tester.pumpAndSettle();
    // The rail replaces the grid outright; there is no package day view.
    expect(find.byType(TableCalendar<CalendarEntry>), findsNothing);
  });

  testWidgets('tapping an item opens a VIEW sheet with no edit control', (
    tester,
  ) async {
    final today = viewerToday();
    await tester.pumpWidget(
      harness(
        entriesFor([
          item(id: 'a', instantUtc: nineAmOn(today), title: 'Morning run'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Morning run'));
    await tester.pumpAndSettle();

    // The sheet names the zone the item was built against, so a cross-timezone
    // plan can never read as the viewer's own local time.
    expect(find.text(kolkata), findsOneWidget);
    // Its one action ROUTES to the screen that owns the real controls. An
    // undecided item belongs to My Schedule even once its time has passed —
    // only a Done/Skip moves it to History (2026-09-25).
    expect(find.text('Open in My Schedule'), findsOneWidget);
    expect(find.text('Open in History'), findsNothing);

    // No edit affordance, disabled or otherwise. The deployed rules make
    // `title` and `scheduledInstantUtc` immutable after create, and a greyed
    // "Edit" would imply the feature is a tap away when it is a rules deploy
    // away. This assertion is the guard on that decision.
    expect(find.text('Edit'), findsNothing);
    // Nor a second rendering of Done / Skip — those live on My Schedule.
    expect(find.text('Done'), findsNothing);
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('day numbers are LOCALIZED, not raw integers', (tester) async {
    // Bengali, not Arabic: intl's `ar` data renders Latin digits (only
    // `ar_EG` and friends use Arabic-Indic), so `ar` would have made this test
    // pass while proving nothing. `bn` renders its own numerals.
    await tester.pumpWidget(harness(const [], locale: const Locale('bn')));
    await tester.pumpAndSettle();

    final today = DateTime.now();
    final localized = DateFormat.d('bn').format(today);
    final latin = DateFormat.d('en').format(today);

    // Guard the guard: if intl's `bn` data ever stopped using its own
    // numerals, the assertion below would pass vacuously and prove nothing.
    expect(
      localized,
      isNot(latin),
      reason: 'fixture assumes bn renders its own numerals',
    );
    expect(find.text(localized), findsWidgets);
    // And the Latin form is genuinely absent — which is what fails if a cell
    // ever goes back to interpolating the raw integer.
    expect(find.text(latin), findsNothing);
  });
}
