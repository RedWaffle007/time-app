import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class _TimeAppState extends ConsumerState<TimeApp> {
  @override
  void initState() {
    super.initState();
    _setupNotificationTaps();
  }

  Future<void> _setupNotificationTaps() async {
    // App opened from a terminated state by tapping a notification.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleTap(initial);

    // App in background → foreground via a notification tap.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

    // Foreground message. The in-app view already reflects the outcome, so we
    // just log it — no need to surface a redundant banner for v1.
    FirebaseMessaging.onMessage.listen((m) {
      debugPrint('FCM foreground: ${m.data}');
    });
  }

  void _handleTap(RemoteMessage message) {
    if (message.data['type'] == 'outcome') {
      ref.read(routerProvider).go(Routes.plannerActivity);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Register / refresh the device token whenever a user is signed in. The
    // MessagingService dedups per-uid internally, so calling it on rebuilds is
    // safe — the permission prompt + token write happen once per signed-in user.
    final uid = ref.watch(authStateProvider).value?.uid;
    if (uid != null) {
      ref.read(messagingServiceProvider).registerForUser(uid);
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'time-app',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
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
