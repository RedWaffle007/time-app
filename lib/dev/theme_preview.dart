// Dev-only render harness. Not part of the app — it has its own `main()` and is
// never reachable from a normal launch.
//
//   flutter run -t lib/dev/theme_preview.dart -d <device>
//
// Two tabs, both rendering REAL widgets — never a copy of one:
//
//   Cards  the REAL PlannerActivityScreen against synthetic data covering every
//          status and outcome, so a card in context can be eyeballed on a real
//          panel without a signed-in pair or live Firestore.
//   Panel  the REAL WarningPanel at its true width, stacked directly against the
//          badges. The panel is the largest orange fill in the app and the only
//          place `attentionContainerStrong` is seen at size; a value tuned on a
//          Pending badge is not proven until it is seen here. Both are on screen
//          at once so the two fills can be compared small vs large — in dark
//          they are the same value, in light the panel is stronger (§2.4).
//
// Follows ThemeMode.system, so `adb shell cmd uimode night yes|no` flips
// light/dark. See UI-RULES.md §8: nothing ships light-only, and a value that
// works in one mode proves nothing about the other.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../core/theme/app_icons.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/app_tokens.dart';
import '../core/theme/status_style.dart';
import '../core/widgets/warning_panel.dart';
import '../features/auth/application/auth_providers.dart';
import '../features/auth/domain/user_profile.dart';
import '../features/scheduling/application/schedule_providers.dart';
import '../features/scheduling/domain/schedule_item.dart';
import '../features/scheduling/presentation/planner_activity_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Same startup the real main() does before any date/time is rendered:
  // formatInstant() resolves an IANA zone, which needs the tz database, and the
  // locale-aware formatters need the date symbols.
  tzdata.initializeTimeZones();
  await initializeDateFormatting();
  runApp(
    ProviderScope(
      overrides: [
        // `myItemsAsPlannerProvider` is the archive-FILTERED view, so it is a
        // plain Provider holding an AsyncValue, not a StreamProvider. The
        // preview feeds it directly; there is no archive in a static harness.
        myItemsAsPlannerProvider.overrideWith((ref) => AsyncData(_items)),
        profileByUidProvider.overrideWith(
          (ref, uid) => Stream.value(
            const UserProfile(
              uid: 'target',
              name: 'Sam',
              homeTimezone: 'Asia/Kolkata',
            ),
          ),
        ),
      ],
      child: const _PreviewApp(),
    ),
  );
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _PreviewHome(),
    );
  }
}

/// Panel and cards are separate destinations rather than one long scroll so each
/// is seen at full width, the way it renders in the app.
class _PreviewHome extends StatefulWidget {
  const _PreviewHome();

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _index == 0 ? const PanelPreview() : const PlannerActivityScreen(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(AppIcons.devPanels),
            label: 'Panel',
          ),
          NavigationDestination(
            icon: Icon(AppIcons.devCards),
            label: 'Cards',
          ),
        ],
      ),
    );
  }
}

/// The attention family at both of its sizes, on one screen.
///
/// The panels use the REAL strings the schedule builder produces — a one-line
/// quiet-hours warning and the two multi-line DST notices — because how a fill
/// reads depends on how much of it there is.
///
/// Public only so a headless capture can pump this exact page when no device is
/// plugged in; on-device and captured renders are then the same composition.
class PanelPreview extends StatelessWidget {
  const PanelPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: Space.screenList,
        children: [
          _heading(context, 'Warning panel — on background'),
          const WarningPanel(
            'This falls in their quiet hours (10:00 pm–7:00 am). '
            'You can still send it — they approve every item.',
          ),
          const WarningPanel(
            "That clock time doesn't exist on this date — clocks spring "
            "forward. It'll fire at 24 Mar 2026, 3:30 am instead.",
          ),
          const WarningPanel(
            'That clock time happens twice on this date — clocks fall back. '
            "It'll use the first: 1 Nov 2026, 1:30 am.",
          ),
          const SizedBox(height: Space.xl),

          // The comparison that matters: the panel's fill directly above the
          // badge tint it is pitched up from. In dark the two are the same
          // value; in light the panel is stronger (UI-RULES.md §2.4). Seeing
          // both adjacencies at once is the whole point of the tab.
          _heading(context, 'Badge tint, for comparison'),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final status in ScheduleItemStatus.values)
                StatusBadge.status(status, context),
              for (final result in OutcomeResult.values)
                StatusBadge.outcome(result, context),
            ],
          ),
          const SizedBox(height: Space.xl),

          // The panel also appears inside a card in the builder form, where it
          // sits on `surface` rather than `background`.
          _heading(context, 'Warning panel — on a card surface'),
          Card(
            child: Padding(
              padding: Space.cardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Morning run', style: context.text.titleMedium),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    children: [
                      StatusBadge.status(ScheduleItemStatus.pending, context),
                      StatusBadge.outcome(OutcomeResult.done, context),
                    ],
                  ),
                  const WarningPanel(
                    'This falls in late night (11pm–6am). You can still send '
                    'it — they approve every item.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Space.sm, top: Space.md),
        child: Text(text, style: context.text.titleLarge),
      );
}

ScheduleItem _item({
  required String id,
  required String title,
  required ScheduleItemStatus status,
  int hour = 9,
  ScheduleOutcome? outcome,
  String? rejectionReason,
}) {
  return ScheduleItem(
    id: id,
    targetUid: 'target',
    createdByUid: 'planner',
    groupId: 'g1',
    title: title,
    localWallTime: '0$hour:00',
    timezone: 'Asia/Kolkata',
    scheduledInstantUtc: DateTime.utc(2026, 7, 24, hour),
    status: status,
    outcome: outcome,
    rejectionReason: rejectionReason,
  );
}

/// Every badge state the card can show, plus both reason lines.
final _items = [
  _item(
    id: '1',
    title: 'Morning run',
    status: ScheduleItemStatus.pending,
    hour: 6,
  ),
  _item(
    id: '2',
    title: 'Read for 30 minutes',
    status: ScheduleItemStatus.approved,
    hour: 8,
  ),
  _item(
    id: '3',
    title: 'Physio exercises',
    status: ScheduleItemStatus.approved,
    hour: 9,
    outcome: const ScheduleOutcome(result: OutcomeResult.done),
  ),
  _item(
    id: '4',
    title: 'Call the dentist',
    status: ScheduleItemStatus.approved,
    hour: 10,
    outcome: const ScheduleOutcome(
      result: OutcomeResult.skipped,
      skipReason: 'Clinic was closed, rebooking tomorrow',
    ),
  ),
  _item(
    id: '5',
    title: 'Study session',
    status: ScheduleItemStatus.rejected,
    hour: 11,
    rejectionReason: 'Already have a lecture then',
  ),
  _item(
    id: '6',
    title: 'Grocery shop',
    status: ScheduleItemStatus.withdrawn,
    hour: 12,
  ),
  _item(
    id: '7',
    title: 'Team stand-up',
    status: ScheduleItemStatus.cancelled,
    hour: 13,
  ),
];
