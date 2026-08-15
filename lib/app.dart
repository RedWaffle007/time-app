import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_icons.dart';
import 'core/theme/app_text.dart';
import 'core/theme/app_theme.dart';
import 'features/applock/presentation/app_lock_gate.dart';
import 'features/auth/application/auth_providers.dart';
import 'features/notifications/application/messaging_service.dart';
import 'routing/app_router.dart';

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

  @override
  void initState() {
    super.initState();
    _setupNotificationTaps();

    // Retry trigger #1: app resume. If token registration failed earlier (e.g.
    // the device was briefly offline), coming back to the foreground gives it a
    // fresh attempt — the MessagingService cooldown keeps this from hammering
    // Firestore if the device is still offline. (Retry trigger #2 — auth change
    // — is handled in build(), which re-runs when authStateProvider changes.)
    WidgetsBinding.instance.addObserver(this);

    // Surface a token-registration FAILURE instead of it being silent. A silent
    // no-token state is exactly what cost a whole debugging session
    // (DECISIONS.md 2026-07-24) — this shows a dismissible banner with Retry.
    ref.read(messagingServiceProvider).status.addListener(_onRegistrationStatus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(messagingServiceProvider).status.removeListener(_onRegistrationStatus);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final uid = ref.read(authStateProvider).value?.uid;
      if (uid != null) {
        ref.read(messagingServiceProvider).registerForUser(uid);
      }
    }
  }

  void _onRegistrationStatus() {
    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    final status = ref.read(messagingServiceProvider).status.value;

    if (status != FcmRegistrationStatus.failed) {
      messenger.hideCurrentMaterialBanner();
      return;
    }

    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: const Text(
          "Couldn't set up notifications on this device — you may not be "
          'notified when someone plans or completes an item.',
        ),
        leading: const Icon(AppIcons.notificationsOff),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
            },
            child: const Text('Dismiss'),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              final uid = ref.read(authStateProvider).value?.uid;
              if (uid != null) {
                ref.read(messagingServiceProvider).retryRegistration(uid);
              }
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
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
    // In the foreground the `notification` block is delivered but NOT rendered
    // by the OS; render it ourselves. Data-only messages have nothing to show.
    final title = message.notification?.title;
    final body = message.notification?.body;
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
            if (title != null)
              Text(title, style: AppText.labelLarge),
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

  void _handleTap(RemoteMessage message) {
    // Route to where the recipient acts on this event. Target-facing events
    // (a plan created for them, or withdrawn) open their pending queue;
    // planner-facing events (their plan was decided or its outcome recorded)
    // open Activity. `type == 'outcome'` is the legacy payload, kept working.
    //
    // A plain `go()` is shell-aware now that both destinations are branch
    // locations: `Routes.approvals` is nested under the My Schedule tab, so it
    // selects that branch and stacks the queue on top of it (Back → the tab),
    // and `Routes.plannerActivity` is a branch root, so it is a tab switch.
    final router = ref.read(routerProvider);
    switch (message.data['event']) {
      case 'created':
      case 'withdrawn':
        router.go(Routes.approvals);
      case 'decided':
      case 'outcome':
        router.go(Routes.plannerActivity);
      default:
        if (message.data['type'] == 'outcome') {
          router.go(Routes.plannerActivity);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Drop the previous session's snackbars when one ENDS.
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
    ref.listen(authStateProvider, (previous, next) {
      final nextUid = next.value?.uid;
      final endedUid = _sessionUid;
      _sessionUid = nextUid;
      if (endedUid == null || endedUid == nextUid) return;
      _scaffoldMessengerKey.currentState?.clearSnackBars();
    });

    // Register / refresh the device token whenever a user is signed in. The
    // MessagingService dedups per-uid internally, so calling it on rebuilds is
    // safe — the permission prompt + token write happen once per signed-in user.
    final uid = ref.watch(authStateProvider).value?.uid;
    if (uid != null) {
      ref.read(messagingServiceProvider).registerForUser(uid);
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'time-app',
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
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox.shrink()),
      // All visual tokens live in core/theme — see UI-RULES.md. Dark is designed
      // alongside light, not derived from it, and follows the device setting.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
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
      routerConfig: router,
    );
  }
}
