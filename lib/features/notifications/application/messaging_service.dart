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
  String? _registeredUid;

  /// Called when a user is signed in. Requests the Android 13+ notification
  /// permission, registers this device's token, and keeps it fresh.
  Future<void> registerForUser(String uid) async {
    if (_registeredUid == uid) return; // already set up for this user
    _registeredUid = uid;

    final messaging = FirebaseMessaging.instance;
    // Android 13+: shows the POST_NOTIFICATIONS prompt. Declining is fine — the
    // app degrades to no push; the in-app view still works.
    await messaging.requestPermission();

    try {
      final token = await messaging.getToken();
      if (token != null) await _tokenRepo.saveToken(uid, token);
    } catch (e, st) {
      // If the token never lands in Firestore, the Worker has nothing to push
      // to and EVERY outcome for this user silently misses forever — worse than
      // a single dropped push. Record it so that blind spot becomes visible.
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FCM token register/save failed — device may never receive pushes',
        fatal: false,
      );
      debugPrint('MessagingService: getToken/save failed: $e');
    }

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
  }

  /// Called on sign-out BEFORE Firebase Auth signs out — the `fcmTokens` write
  /// is owner-only, so the delete must happen while still authenticated.
  Future<void> unregister(String uid) async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    _registeredUid = null;

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
