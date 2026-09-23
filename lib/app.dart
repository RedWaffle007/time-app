import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_text.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/time_backdrop.dart';
import 'features/applock/presentation/app_lock_gate.dart';
import 'features/auth/application/auth_providers.dart';
import 'features/celebrations/presentation/completion_celebration_host.dart';
import 'features/notifications/application/messaging_service.dart';
import 'features/notifications/application/fcm_failure_banner_policy.dart';
import 'features/notifications/application/inactivity_tracker.dart';
import 'features/onboarding/application/onboarding_providers.dart';
import 'features/groups/application/group_providers.dart';
import 'features/groups/application/group_stats_providers.dart';
import 'features/groups/application/planner_access_reconciler.dart';
import 'features/reminders/application/alarm_timeline_providers.dart';
import 'features/reminders/application/missed_alarm_providers.dart';
import 'features/reminders/application/reminder_providers.dart';
import 'features/reminders/presentation/missed_alarm_review_host.dart';
import 'features/scheduling/application/item_lapse_reconciler.dart';
import 'features/scheduling/application/schedule_providers.dart';
import 'features/scheduling/application/slot_lock_reconciler.dart';
import 'features/social/application/stats_providers.dart';
import 'features/social/application/social_providers.dart';
import 'features/splash/presentation/splash_overlay.dart';
import 'features/theme/application/theme_mode_controller.dart';
import 'features/time_tracking/application/time_tracking_providers.dart';
import 'routing/app_router.dart';
import 'routing/notification_routing.dart';

/// Root widget. Uses MaterialApp.router so go_router owns navigation.
///
/// It is also where FCM is wired up: it registers the device token when a user
/// signs in, and routes notification taps to the planner's activity view. The
/// in-app outcomes view is unaffected by any of this — push is purely additive.
class TimeApp extends ConsumerStatefulWidget {
  const TimeApp({super.key});

  @override
  ConsumerState<TimeApp> createState() => _TimeAppState();
}

class _TimeAppState extends ConsumerState<TimeApp> with WidgetsBindingObserver {
  // Lets the FCM onMessage listener show a banner. That listener runs outside
  // the widget tree, so it has no BuildContext / ScaffoldMessenger of its own —
  // this key, attached to MaterialApp.router below, gives it one.
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  /// The uid whose session the currently-queued snackbars belong to. Compared
  /// against each new auth emission to spot a session ENDING — see the listener
  /// in build().
  String? _sessionUid;

  /// A dismissal belongs to one unchanged failed registration state. A new
  /// attempt (Retry or resume) may report its own result, but ordinary rebuilds
  /// cannot re-post a banner the user just dismissed.
  bool _registrationFailureDismissed = false;
  bool _registrationRetryRequested = false;

  /// A notification tap that cold-started this process. The FCM/local plugins
  /// report it asynchronously, so the splash may already be mounted when this
  /// flips; [SplashOverlay.skipReveal] handles both the initial and late signal.
  bool _openedFromNotification = false;
  bool _splashReady = false;
  String? _activityUid;

  @override
  void initState() {
    super.initState();
    _setupNotificationTaps();
    _setupReminderLaunchTap();

    // Retry trigger #1: app resume. If token registration failed earlier (e.g.
    // the device was briefly offline), coming back to the foreground gives it a
    // fresh attempt — the MessagingService cooldown keeps this from hammering
    // Firestore if the device is still offline. (Retry trigger #2 — auth change
    // — is handled in build(), which re-runs when authStateProvider changes.)
    WidgetsBinding.instance.addObserver(this);

    // Surface a token-registration FAILURE instead of it being silent. A silent
    // no-token state is exactly what cost a whole debugging session
    // (DECISIONS.md 2026-07-24) — this shows a dismissible banner with Retry.
    ref
        .read(messagingServiceProvider)
        .status
        .addListener(_onRegistrationStatus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref
        .read(messagingServiceProvider)
        .status
        .removeListener(_onRegistrationStatus);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    final uid = ref.read(authStateProvider).value?.uid;
    if (uid != null) {
      ref.read(messagingServiceProvider).registerForUser(uid);
      ref.read(inactivityTrackerProvider).record(uid);
    }

    // RECONCILE ON RESUME. The item stream alone is not enough, because the
    // things that invalidate scheduled alarms happen while the app is not
    // running and produce no emission: a reboot, an app update (which on this
    // Redmi also revokes SCHEDULE_EXACT_ALARM), the user granting a permission
    // in Settings and coming back, or simply time passing until a reminder is
    // due. The reconcile is idempotent, so the ordinary resume computes an empty
    // plan and touches no plugin.
    final items = ref.read(allItemsAsTargetProvider).value;
    if (items != null) {
      ref
          .read(reminderServiceProvider)
          .sync(items: items, uid: uid, reason: 'resume');
      ref.read(alarmTimelineServiceProvider).sync(items, uid);
      ref.read(missedAlarmServiceProvider).sync(items, uid);
    }

    // Permissions can be changed from Settings behind the app's back, and on
    // this device SCHEDULE_EXACT_ALARM is revoked by every reinstall — so the
    // cached answer is re-read rather than trusted. This is what makes the
    // primer card disappear the moment the user grants what it asked for.
    ref.invalidate(reminderPermissionStateProvider);
  }

  void _onRegistrationStatus() {
    final status = ref.read(messagingServiceProvider).status.value;
    if (status != FcmRegistrationStatus.failed) {
      _registrationFailureDismissed = false;
    }
    if (status != FcmRegistrationStatus.registering) {
      _registrationRetryRequested = false;
    }
    _syncRegistrationBanner();
  }

  void _syncRegistrationBanner() {
    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    final status = ref.read(messagingServiceProvider).status.value;
    // An unresolved first-run preference is treated as incomplete. If the
    // preference itself fails, OnboardingGate deliberately lets the app through
    // (there is no active flow to cover), so presentation may proceed rather
    // than deferring a genuine registration failure forever.
    final onboarding = ref.read(onboardingCompletedProvider);
    final onboardingCompleted = onboarding.hasError || onboarding.value == true;
    final mode = fcmFailureBannerMode(
      registrationStatus: status,
      onboardingCompleted: onboardingCompleted,
      permissionFlowInProgress: ref.read(permissionFlowInProgressProvider),
      failureDismissed: _registrationFailureDismissed,
      retryRequested: _registrationRetryRequested,
    );

    if (mode == FcmFailureBannerMode.hidden) {
      messenger.hideCurrentMaterialBanner();
      return;
    }

    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      FcmRegistrationBanner(
        mode: mode,
        onDismiss: () {
          _registrationFailureDismissed = true;
          _syncRegistrationBanner();
        },
        onRetry: () {
          final uid = ref.read(authStateProvider).value?.uid;
          if (uid == null) return;
          _registrationRetryRequested = true;
          // `_attempt` synchronously enters `registering`, which updates this
          // same banner to an explicit busy state.
          ref.read(messagingServiceProvider).retryRegistration(uid);
        },
      ),
    );
  }

  /// A local reminder that was tapped while the app was DEAD.
  ///
  /// `onDidReceiveNotificationResponse` — wired in the scheduler — only fires
  /// for a running app. A tap that cold-starts the process is reported once, on
  /// launch, through this call and nowhere else; without it, tapping a reminder
  /// for a killed app opens the app on whatever screen it was last on and the
  /// item is never surfaced.
  Future<void> _setupReminderLaunchTap() async {
    try {
      final launch = await ref
          .read(localNotificationsPluginProvider)
          .getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp != true) return;
      final itemId = launch?.notificationResponse?.payload;
      if (itemId == null || itemId.isEmpty) return;
      if (!mounted) return;
      _dismissColdStartReveal();
      ref.read(notificationRouterProvider).openItem(itemId);
    } catch (e) {
      // Nothing here is worth failing a launch over — on a platform with no
      // implementation this is a MissingPluginException, and the cost of an
      // error is a lost deep link, not a lost reminder. Unhandled, it would
      // surface as an async error during `initState` on every cold start.
      debugPrint('TimeApp: reminder launch tap lookup failed: $e');
    }
  }

  Future<void> _setupNotificationTaps() async {
    // App opened from a terminated state by tapping a notification.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleTap(initial);

    // App in background → foreground via a notification tap.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

    // Foreground message. FCM auto-displays a system-tray notification ONLY when
    // the app is backgrounded/terminated — while it's open, nothing appears
    // unless we render it. So show an in-app banner (SnackBar) with a View
    // action; without this, a recipient looking at the app sees nothing at all.
    FirebaseMessaging.onMessage.listen(_showForegroundBanner);
  }

  void _showForegroundBanner(RemoteMessage message) {
    debugPrint('FCM foreground: ${message.data}');
    // A DONE event has a durable Firestore celebration. The app-wide host shows
    // the colored-paper effect live and acknowledges it exactly once; stacking
    // the ordinary snackbar over that effect would render the same event twice.
    if (message.data['event'] == 'outcome' &&
        message.data['subtype'] == 'done') {
      return;
    }
    // In the foreground the `notification` block is delivered but NOT rendered
    // by the OS; render it ourselves. Data-only messages have nothing to show.
    // Emergency-created messages are data-only so Android invokes the
    // background alarm installer. In the foreground there is no background
    // isolate, so use the Worker-provided display copy for the same banner.
    final title =
        message.notification?.title ?? (message.data['pushTitle'] as String?);
    final body =
        message.notification?.body ?? (message.data['pushBody'] as String?);
    if (title == null && body == null) return;

    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) return;

    messenger.hideCurrentSnackBar(); // replace, don't stack, on rapid outcomes
    messenger.showSnackBar(
      SnackBar(
        // Without `persist: false` the 6s below is dead code: a SnackBar with a
        // SnackBarAction defaults to `persist: true` (`snack_bar.dart:303`) and
        // its dismiss timer returns without acting (`scaffold.dart:619-626`).
        // This banner has had a View action since it was written, so it has
        // never once timed out.
        persist: false,
        duration: const Duration(seconds: 6),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Text(title, style: AppText.labelLarge),
            if (body != null) Text(body),
          ],
        ),
        action: SnackBarAction(
          label: 'View',
          // Same routing as tapping a tray notification (see _handleTap).
          onPressed: () => _handleTap(message),
        ),
      ),
    );
  }

  /// Where a push tap goes. The rules moved into [NotificationRouter] when local
  /// reminders arrived: there are now two tap sources reaching the router
  /// through unrelated plugin callbacks, and two copies of the destination table
  /// would drift the first time a route moved — which these routes already did
  /// once, in the Session 3 shell refactor.
  void _handleTap(RemoteMessage message) {
    _dismissColdStartReveal();
    ref.read(notificationRouterProvider).openForPushEvent(message.data);
  }

  void _dismissColdStartReveal() {
    if (!mounted || _openedFromNotification) return;
    setState(() => _openedFromNotification = true);
  }

  @override
  Widget build(BuildContext context) {
    // Drop the previous session's snackbars AND banners when one ENDS.
    //
    // The ScaffoldMessenger is built above the Router (`material/app.dart:1047`
    // wraps the Router and this widget's `builder`), so its queue is outside the
    // navigation tree: no route change, branch switch or sign-out reaches it,
    // and `_register` hands a live snackbar straight to any newly mounted root
    // Scaffold (`scaffold.dart:211-222`). That is how an archive snackbar
    // survived sign-out AND a sign-in as a different account. Nothing else in
    // the app tears the messenger down, so it is done here — the one place that
    // owns the messenger key.
    //
    // **This cannot eat a wanted message.** It fires only when a session that
    // was actually established is replaced by a different one: sign-out
    // (uid → null) and account switch (uidA → uidB). The first sign-in of the
    // process is skipped (`endedUid == null`), and a token refresh re-emitting
    // the same user is skipped (`endedUid == nextUid`). Any snackbar in flight
    // at that moment belongs to the session being torn down, which is precisely
    // what has to go.
    //
    // The registration banner needs the same treatment and does NOT get it for
    // free: `clearSnackBars()` deliberately leaves banners alone, and they are
    // the more account-scoped of the two — "Couldn't set up notifications on
    // this device" is a statement about ONE user's token, and it outlived
    // sign-out for the same above-the-Router reason. Cleared on the same hook
    // rather than a second listener, so there is one place that decides what a
    // session ending means to the messenger.
    ref.listen(authStateProvider, (previous, next) {
      final nextUid = next.value?.uid;
      final endedUid = _sessionUid;
      _sessionUid = nextUid;
      if (endedUid == null || endedUid == nextUid) return;
      _scaffoldMessengerKey.currentState
        ?..clearSnackBars()
        ..clearMaterialBanners();
      // The stats publisher caches what it last wrote so an unchanged
      // recomputation costs nothing. That cache is per-ACCOUNT: without this,
      // the next account's first computation would be compared against the
      // previous account's numbers and skipped as "unchanged", leaving their
      // published stats stale — or, if the two happened to differ, written
      // under the wrong uid's document by a race on the way out.
      ref.read(profileStatsPublisherProvider).reset();
      ref.read(groupStatsPublisherProvider).reset();
    });
    // A failure may have occurred while the first-run gate was explaining
    // permissions. Re-evaluate when that gate finishes and when an OS/settings
    // surface opens or returns; this is state policy, never route inspection.
    ref.listen(onboardingCompletedProvider, (previous, next) {
      _syncRegistrationBanner();
    });
    ref.listen(permissionFlowInProgressProvider, (previous, next) {
      _syncRegistrationBanner();
    });

    // Register / refresh the device token whenever a user is signed in. The
    // MessagingService dedups per-uid internally, so calling it on rebuilds is
    // safe — the permission prompt + token write happen once per signed-in user.
    final uid = ref.watch(authStateProvider).value?.uid;
    if (_activityUid != uid) {
      _activityUid = uid;
      if (uid == null) {
        ref.read(inactivityTrackerProvider).clear();
      } else {
        ref.read(inactivityTrackerProvider).record(uid);
      }
    }
    if (uid != null) {
      ref.read(messagingServiceProvider).registerForUser(uid);
    }

    // THE REMINDER LAYER'S ONE WIRE. Watching it keeps the sync alive: it
    // listens to the item stream and to auth, and reconciles the OS against
    // both. Everything else about reminders follows from that — there is no
    // per-transition hook anywhere in the app.
    ref.watch(reminderSyncProvider);

    // Native AUDIO_FIRED rows are the only trustworthy source for when an
    // alarm really rang while Dart was dead. Reconcile them into the shared
    // item so its planner-facing timeline can display reached events.
    ref.watch(alarmTimelineSyncProvider);
    ref.watch(missedAlarmSyncProvider);

    // THE PLANNER-ACCESS MIRROR'S ONE WIRE — same shape again, and here the
    // argument is sharper than for either of its neighbours. `plannerAccess` is
    // what the RULES consult to decide whether a planner may read this user's
    // schedule, so a stale mirror is not a missed notification, it is access
    // that outlives its revocation. Driving it off the grant stream means
    // revoke, re-grant, a second group's grant and being ejected from a group
    // are all the same code path, and it backfills grants that predate the
    // feature the first time this user opens the app.
    //
    // There is deliberately NO mirror write inside `setPlannerGrant()`.
    ref.watch(plannerAccessSyncProvider);

    // Group planning permission is only for non-friend group members. When an
    // existing pair becomes friends, preserve the target's consent by moving
    // the live grant to their profile relationship, then revoke the duplicate
    // group copy. This is stream-driven so older installs self-migrate.
    ref.watch(planningPermissionMigrationSyncProvider);

    // LEGACY SLOT-LOCK CLEANUP. New plans no longer create 30-minute locks:
    // schedule entries are point alarms and may share a half-hour. Keep this
    // stream-driven cleanup wired while existing installations delete locks
    // created by older builds.
    ref.watch(slotLockSyncProvider);

    // THE END-OF-DAY LAPSE WIRE — the same shape a fifth time. An item nobody
    // approves or acts on cannot sit in "next" forever: at the end of its own
    // local day a pending plan is rejected ("Not approved in time") and an
    // approved-but-untouched item is skipped ("Did not respond"), off the item
    // stream, never off a transition. Late completions before that boundary are
    // ordinary Done writes and keep their delay (ScheduleItem.completionDelay).
    ref.watch(itemLapseSyncProvider);

    // THE STATS LAYER'S ONE WIRE, and it is the same shape as the reminder
    // wire above on purpose: **driven off the item stream, never off
    // transitions.** There is no `publishStats()` call in `markDone()`,
    // `approve()`, `reject()` or anywhere else — a single recomputation is
    // applied to whatever the stream currently says, so an outcome, an edit, a
    // withdrawal and a rejection are not special cases. Adding a per-transition
    // hook would create a second place that decides, and the two would
    // disagree.
    //
    // Publishing is what lets ANOTHER person's device see these numbers: their
    // device cannot read `scheduleItems/{me}/items`, so it reads the small
    // document this writes (`ProfileStatsRepository`). `publishIfChanged` is
    // idempotent and skips an unchanged recomputation, which is what makes it
    // safe on every emission.
    ref.listen(myComputedStatsProvider, (previous, next) {
      if (next.hasValue) {
        ref.read(profileStatsPublisherProvider).publishIfChanged();
        // Group accountability + leaderboard: the SAME computation, republished
        // into each of my groups so fellow members can read it (they cannot read
        // my items or my friend-gated profileStats). Same idempotent, off-stream
        // discipline. See group_stats_providers.dart.
        ref.read(groupStatsPublisherProvider).publishIfChanged();
      }
    });
    // Also republish when my group membership changes — joining a group has to
    // seed my summary into it without waiting for the next stats recomputation.
    ref.listen(myGroupsProvider, (previous, next) {
      if (next.hasValue) {
        ref.read(groupStatsPublisherProvider).publishIfChanged();
      }
    });
    ref.listen(myTrackedEntriesProvider, (_, next) {
      if (next.hasValue) {
        ref.read(profileStatsPublisherProvider).publishIfChanged();
        ref.read(groupStatsPublisherProvider).publishIfChanged();
      }
    });

    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'Checkmate',
      // THE APP LOCK GOES HERE — `builder`, not HomeGate, not a route.
      //
      // `builder` wraps the Router and the root Navigator itself, so the gate
      // sits above EVERY route and above the navigator that `showDialog` and
      // `showModalBottomSheet` push onto. A gate at HomeGate would cover the
      // home screen and leave Archived, Edit profile, the schedule builder and
      // every dialog reachable if the app was backgrounded while one was on
      // top. A lock with a reachable door is not a lock.
      //
      // Snackbars and the FCM registration banner are safe for the same reason:
      // both render inside a `Scaffold`, every Scaffold lives in a route, and
      // every route is under `child` here — so neither can paint over the lock.
      // `LockScreen` deliberately uses `Material` rather than `Scaffold`, so
      // nothing can be posted onto it either.
      // THE COLD-START REVEAL wraps the app lock, not the reverse: on an ordinary
      // fresh launch the black Supercell-style reveal covers EVERYTHING —
      // including the lock screen — then fades to reveal whatever gate resolves
      // beneath. A notification launch bypasses it because the user explicitly
      // asked to see one destination now; a warm resume never re-runs `main()`.
      // See SplashOverlay for both paths.
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          final currentUid = _activityUid;
          if (currentUid != null) {
            ref.read(inactivityTrackerProvider).record(currentUid);
          }
        },
        child: SplashOverlay(
          skipReveal: _openedFromNotification,
          onRevealComplete: () {
            if (mounted && !_splashReady) {
              setState(() => _splashReady = true);
            }
          },
          child: AppLockGate(
            child: CompletionCelebrationHost(
              enabled: _splashReady,
              child: MissedAlarmReviewHost(
                enabled: _splashReady,
                child: TimeBackdrop(
                  key: TimeBackdrop.backdropKey,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
      // All visual tokens live in core/theme — see UI-RULES.md. Dark is designed
      // alongside light, not derived from it, and follows the device setting.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      themeAnimationDuration: Duration.zero,
      // Follow the device locale: these delegates localize Material chrome and
      // the date/time pickers, and make Localizations.localeOf(context) reflect
      // the user's locale (which every display in datetime_format.dart reads).
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Accept ANY locale that Flutter's Material localizations support (~80,
      // covering South Asia, MENA, SE Asia, Africa, Latin America) rather than a
      // hand-picked few — so no region is silently dropped. This only governs
      // date/time formatting + Material chrome; our own labels stay English
      // (translating those would need ARB files, which is out of scope). The
      // supportedLocales list below is just a representative fallback set.
      localeResolutionCallback: (deviceLocale, supportedLocales) {
        if (deviceLocale != null &&
            GlobalMaterialLocalizations.delegate.isSupported(deviceLocale)) {
          return deviceLocale;
        }
        return const Locale('en');
      },
      supportedLocales: const [Locale('en')],
      // Without this the PopScope in home_shell.dart is dead on a fresh launch.
      // See forceFrameworkHandlesBack below.
      onNavigationNotification: forceFrameworkHandlesBack,
      routerConfig: router,
    );
  }
}

/// Tells Android that Dart handles Back — always, whatever the notification says.
///
/// This replaces WidgetsApp's default handler (`widgets/app.dart:1442`), which
/// forwards `notification.canHandlePop` to the platform verbatim. That default
/// is last-writer-wins, and under a `StatefulShellRoute` the last writer is the
/// wrong one. At launch four notifications arrive in this order:
///
///   `false, true, true, false`
///
/// The shell route's [PopScope] dispatches `true`
/// (`widgets/routes.dart:2142` — a `doNotPop` disposition means "I handle it"),
/// but each of the three branch navigators sitting at its tab root dispatches
/// `false`, because it has nothing to pop and no PopScope of its own
/// (`widgets/navigator.dart:3753`). The root navigator forwards that `false`
/// untouched: it only upgrades a `false` when *it* can pop
/// (`widgets/navigator.dart:5920`), and it never looks at the PopScope on its
/// own current route. So a branch's `false` lands last and wins.
///
/// With targetSdk 36 + predictive back on Android 16, a `false` flag means the
/// engine finishes the activity itself and `popRoute` never reaches Dart — so
/// `_handleBack()` in home_shell.dart never ran and Back at a tab root exited
/// the app silently. It healed once a branch had something to pop, which is why
/// it only reproduced on a fresh launch. Regression coverage:
/// `test/back_button_test.dart`.
///
/// **Forcing `true` cannot trap the user.** The flag is a routing hint, not a
/// promise: Back is merely delivered to Dart, `GoRouterDelegate.popRoute()`
/// runs, and when nothing handles it `handlePopRoute()` falls through to
/// `SystemNavigator.pop()` (`widgets/binding.dart:1132`). `/auth` — no
/// PopScope, nothing to pop — therefore still exits on the first press, as the
/// test asserts. The cost is one IPC round-trip and the loss of the system's
/// predictive-back preview animation on screens that would have exited.
///
/// Lifecycle-guarded exactly like the default handler, so nothing is sent to the
/// engine before the app is attached.
bool forceFrameworkHandlesBack(NavigationNotification notification) {
  switch (WidgetsBinding.instance.lifecycleState) {
    case null:
    case AppLifecycleState.detached:
      return true;
    case AppLifecycleState.inactive:
    case AppLifecycleState.resumed:
    case AppLifecycleState.hidden:
    case AppLifecycleState.paused:
      SystemNavigator.setFrameworkHandlesBack(true);
      return true;
  }
}
