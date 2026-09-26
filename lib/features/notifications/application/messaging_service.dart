import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../auth/application/auth_providers.dart';
import '../../reminders/data/local_notifications_reminder_scheduler.dart';
import '../../reminders/data/reminder_audit_log.dart';
import '../../reminders/domain/reminder.dart';
import '../../../firebase_options.dart';
import '../data/fcm_token_repository.dart';
import '../../voice_notes/application/voice_rescue.dart';

/// Convert the trusted data payload emitted by the notification Worker into a
/// local reminder request. Kept pure so malformed or replayed pushes can be
/// rejected without touching a platform plugin.
ReminderRequest? reminderRequestFromPushData(Map<String, dynamic> data) {
  if (data['command'] != 'scheduleReminder') return null;
  final itemId = data['itemId'];
  final fireAtRaw = data['fireAtUtc'];
  final title = data['title'];
  final body = data['body'];
  if (itemId is! String ||
      itemId.isEmpty ||
      fireAtRaw is! String ||
      title is! String ||
      title.isEmpty ||
      body is! String) {
    return null;
  }
  final fireAt = DateTime.tryParse(fireAtRaw)?.toUtc();
  if (fireAt == null || !fireAt.isAfter(DateTime.now().toUtc())) return null;
  // A voice-note emergency (item 32c-2) arms WITH its note.
  final sha = data['voiceSha256'];
  final size = int.tryParse('${data['voiceSizeBytes'] ?? ''}');
  final voice =
      sha is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) && size != null && size > 0
      ? ReminderVoice(sha256: sha, sizeBytes: size)
      : null;
  return ReminderRequest(
    itemId: itemId,
    fireAtUtc: fireAt,
    title: title,
    body: body,
    voice: voice,
  );
}

/// Background/terminated message handler. Emergency plans are created already
/// approved on the planner's device, so the target's ordinary Firestore stream
/// cannot arm them while their app is killed. The Worker sends those events as
/// high-priority data and this handler installs the same local alarm the live
/// stream would install. Re-scheduling later under the same deterministic id is
/// harmless and lets the normal reconciler remain the final authority.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Voice-note rescue (item 32c): fetch a note that has not reached this
  // phone yet, while the app is closed. Best effort; the reconciler retries.
  final voiceFetch = voiceFetchRequestFromPushData(message.data);
  if (voiceFetch != null) {
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    try {
      await fetchVoiceNoteInBackground(voiceFetch);
    } catch (e) {
      debugPrint('TimeApp: background voice fetch failed: $e');
    }
    return;
  }

  final request = reminderRequestFromPushData(message.data);
  if (request == null) return;

  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  tzdata.initializeTimeZones();

  final scheduler = LocalNotificationsReminderScheduler(
    plugin: FlutterLocalNotificationsPlugin(),
    audit: const ReminderAuditLog(),
    onTapItem: (_) {},
    voicePathFor: (itemId) async =>
        '${(await getApplicationSupportDirectory()).path}/voice-notes/$itemId.m4a',
  );
  await scheduler.initialize();
  final armed = await scheduler.schedule(
    request,
    reminderNotificationId(request.itemId),
  );
  // Fetch the voice note now rather than waiting for the rescue push.
  if (request.voice != null) {
    final target = message.data['targetUid'];
    if (target is String && target.isNotEmpty) {
      try {
        await fetchVoiceNoteInBackground((
          targetUid: target,
          itemId: request.itemId,
        ));
      } catch (e) {
        debugPrint('TimeApp: emergency voice fetch failed: $e');
      }
    }
  }
  if (armed) {
    await scheduler.showEmergencyPlanAlert(
      itemId: request.itemId,
      title: message.data['pushTitle'] as String? ??
          'New emergency plan for you',
      body: message.data['pushBody'] as String? ?? request.title,
      data: message.data,
    );
  }
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

  final ValueNotifier<FcmRegistrationStatus> _status = ValueNotifier(
    FcmRegistrationStatus.idle,
  );

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
      // **NO PERMISSION PROMPT HERE.** This used to call
      // `messaging.requestPermission()`, which on Android 13+ is the
      // POST_NOTIFICATIONS system prompt — and because registration runs on the
      // first signed-in build, that prompt landed on a user who had not yet
      // seen a screen of the app. Android effectively grants that prompt once;
      // a "deny" is final and the only way back is Settings. Spending the one
      // ask on a cold launch, with no context, is spending it badly.
      //
      // The ask belongs to the first-install permission onboarding, which
      // explains it before the OS prompt. The reminder primer is the repair path
      // when a user skips, denies, or later revokes it.
      //
      // **Token registration is unaffected**, which is why this is safe to
      // remove rather than move: `getToken()` does not require notification
      // permission on Android, and the previous code already proceeded whether
      // the prompt was granted or denied. A user who has not granted anything
      // still registers a token and still receives data; the only thing
      // permission governs is whether the OS draws the tray notification — and
      // it governed that identically before, since a denial changed nothing here.
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
            reason:
                'FCM token refresh save failed — pushes may stop after rotation',
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
        reason:
            'FCM token register/save failed — device may never receive pushes',
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
