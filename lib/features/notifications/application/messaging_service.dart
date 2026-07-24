import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/fcm_token_repository.dart';

/// Background/terminated message handler. Must be a top-level (or static)
/// function annotated for the entry point. We send a `notification` payload, so
/// Android displays it in the system tray automatically — there is no work to do
/// here; tap handling happens on open. Kept registered per FlutterFire guidance.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Intentionally minimal. Do NOT do Firestore work here for v1.
}

/// Where token registration currently stands, so the UI can surface a FAILURE
/// instead of it being silent. A silent no-token state cost six days and a fully
/// misdiagnosed bug (DECISIONS.md 2026-07-24) — `failed` exists so that can never
/// be invisible again.
enum FcmRegistrationStatus { idle, registering, registered, failed }

final fcmTokenRepositoryProvider = Provider<FcmTokenRepository>((ref) {
  return FcmTokenRepository(FirebaseFirestore.instance);
});

final messagingServiceProvider = Provider<MessagingService>((ref) {
  return MessagingService(ref.watch(fcmTokenRepositoryProvider));
});

/// Owns FCM setup: permission, token registration/refresh, and cleanup.
class MessagingService {
  MessagingService(this._tokenRepo);

  final FcmTokenRepository _tokenRepo;
  StreamSubscription<String>? _refreshSub;

  /// Set ONLY after a token write succeeds. This is the "we're good, stop
  /// trying" latch. It used to be set *before* the awaits that can fail, so one
  /// transient error disabled registration for the whole session with no retry
  /// — the exact defect in DECISIONS.md (B). Success is now the only thing that
  /// stops retries.
  String? _registeredUid;

  /// Concurrency + backoff guards. `build()`, app-resume, and auth changes can
  /// all call [registerForUser] in quick succession; these stop that from
  /// stacking writes or hammering Firestore while a device is genuinely offline.
  bool _inFlight = false;
  String? _attemptUid;
  DateTime? _lastAttemptAt;

  /// A genuinely offline device retries at most once per this interval, no
  /// matter how many resumes/rebuilds fire in between. An explicit user tap on
  /// "Retry" bypasses it (see [retryRegistration]).
  static const _retryCooldown = Duration(seconds: 30);

  /// Hard ceiling on the FCM calls so a HANG can't stall registration silently —
  /// the worst failure mode, because a hang leaves no Crashlytics record at all.
  /// A timeout converts that into a visible `failed` we can retry.
  static const _opTimeout = Duration(seconds: 15);

  final ValueNotifier<FcmRegistrationStatus> _status =
      ValueNotifier(FcmRegistrationStatus.idle);

  /// Observable registration state for the UI (drives the failure banner).
  ValueListenable<FcmRegistrationStatus> get status => _status;

  /// Called when a user is signed in — safe to call repeatedly (on every build,
  /// on app resume, on auth change). It self-limits: it no-ops once registered,
  /// while an attempt is in flight, or within the cooldown after a failure.
  Future<void> registerForUser(String uid) async {
    if (_registeredUid == uid) return; // already registered — nothing to do
    if (_inFlight) return; // an attempt is already running

    // A different user signing in resets the backoff so the new user isn't
    // blocked by the previous user's cooldown.
    if (uid != _attemptUid) {
      _attemptUid = uid;
      _lastAttemptAt = null;
    }

    // Persistent-failure throttle: skip if we failed too recently.
    final last = _lastAttemptAt;
    if (last != null && DateTime.now().difference(last) < _retryCooldown) {
      return;
    }

    await _attempt(uid);
  }

  /// Explicit user-driven retry (the banner's Retry action). Bypasses the
  /// cooldown — a deliberate tap is a fresh signal, not the resume spam the
  /// cooldown exists to damp.
  Future<void> retryRegistration(String uid) async {
    if (_inFlight) return;
    _lastAttemptAt = null;
    await _attempt(uid);
  }

  Future<void> _attempt(String uid) async {
    _inFlight = true;
    _lastAttemptAt = DateTime.now();
    _status.value = FcmRegistrationStatus.registering;

    final messaging = FirebaseMessaging.instance;
    try {
      // Android 13+: shows the POST_NOTIFICATIONS prompt. Declining is fine for
      // *token* registration — getToken still succeeds, so we proceed either way
      // (a declined user just won't see tray notifications). Inside the try now,
      // and time-boxed, so a hung prompt fails loudly instead of stalling.
      await messaging.requestPermission().timeout(_opTimeout);

      final token = await messaging.getToken().timeout(_opTimeout);
      if (token == null) {
        throw StateError('FCM getToken returned null');
      }
      await _tokenRepo.saveToken(uid, token);

      // Only NOW is it safe to latch: the token is actually in Firestore.
      _registeredUid = uid;
      _status.value = FcmRegistrationStatus.registered;

      await _refreshSub?.cancel();
      _refreshSub = messaging.onTokenRefresh.listen((t) {
        _tokenRepo.saveToken(uid, t).catchError((Object e, StackTrace st) {
          FirebaseCrashlytics.instance.recordError(
            e,
            st,
            reason: 'FCM token refresh save failed — pushes may stop after rotation',
            fatal: false,
          );
          debugPrint('MessagingService: token refresh save failed: $e');
        });
      });
    } catch (e, st) {
      // If the token never lands in Firestore, the Worker has nothing to push
      // to and EVERY outcome for this user silently misses forever. Record it,
      // AND flip the observable status so the UI can show a banner — the latch
      // stays null, so a resume / auth change / Retry tap will try again.
      _status.value = FcmRegistrationStatus.failed;
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FCM token register/save failed — device may never receive pushes',
        fatal: false,
      );
      debugPrint('MessagingService: register failed: $e');
    } finally {
      _inFlight = false;
    }
  }

  /// Called on sign-out BEFORE Firebase Auth signs out — the `fcmTokens` write
  /// is owner-only, so the delete must happen while still authenticated.
  Future<void> unregister(String uid) async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    _registeredUid = null;
    _attemptUid = null;
    _lastAttemptAt = null;
    _status.value = FcmRegistrationStatus.idle;

    final messaging = FirebaseMessaging.instance;
    try {
      final token = await messaging.getToken();
      if (token != null) await _tokenRepo.deleteToken(uid, token);
      await messaging.deleteToken();
    } catch (e) {
      debugPrint('MessagingService: unregister failed: $e');
    }
  }
}

/// Sign out with token cleanup: delete this device's token (while still
/// authenticated) and then sign out. UI sign-out buttons call this instead of
/// `AuthRepository.signOut()` directly.
Future<void> signOutWithTokenCleanup(WidgetRef ref) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid != null) {
    await ref.read(messagingServiceProvider).unregister(uid);
  }
  await ref.read(authRepositoryProvider).signOut();
}
