package com.timeapp.time_app

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.timeapp.time_app.reminders.AlarmSoundService
import com.timeapp.time_app.reminders.ReminderAuditChannel

/**
 * Hosts the `time_app/secure_window` channel — the Android half of
 * [SecureWindow] (`lib/features/applock/data/secure_window.dart`).
 *
 * REGISTRATION POINT. `configureFlutterEngine` runs during `onAttach`, after the
 * engine exists and BEFORE `doInitialFlutterViewRun()` executes the Dart
 * entrypoint — so the handler is always in place before `AppLockController.start()`
 * can call it. That ordering holds because this activity gets a fresh engine; a
 * cached/pre-warmed engine could already be running Dart and would break it.
 *
 * `super.configureFlutterEngine` must come first: it runs GeneratedPluginRegistrant
 * (Firebase, local_auth, shared_preferences). Skipping it silently kills every plugin.
 *
 * WHO DECIDES *WHEN*. Dart does. FLAG_SECURE is per-Window and lost on process
 * death, so it has to be re-applied every launch — and that is already
 * `AppLockController.start()`'s job. This side deliberately persists nothing and
 * reads no setting; two sources of truth for one flag is how it drifts.
 *
 * ---
 *
 * SUPERCLASS: MUST be [FlutterFragmentActivity], not `FlutterActivity`.
 *
 * `local_auth` refuses to prompt unless the host is an AndroidX `FragmentActivity`
 * — `LocalAuthPlugin.java:124` returns `ERROR_NOT_FRAGMENT_ACTIVITY` *before* it
 * ever builds a BiometricPrompt. `FlutterActivity` extends `android.app.Activity`,
 * so tapping Unlock did nothing at all: the plugin bailed early, the resulting
 * `PlatformException('no_fragment_activity')` was swallowed by `device_auth.dart`,
 * and the user was locked out of the app permanently (found on-device 2026-08-14).
 *
 * Turning the lock ON kept working the whole time, which is what hid it —
 * `setEnabled` only calls `canAuthenticate()` (a capability query with no such
 * guard). `authenticate()` is reached from exactly one place, `unlock()`, so the
 * prompt was first *required* on the first relaunch.
 *
 * Trade accepted: AndroidX `FragmentActivity` reserves the upper 16 bits of
 * `onActivityResult` request codes, which can break plugins using the legacy
 * activity-result path. Google Sign-In is the exposure here; it routes through
 * CredentialManager (`google_sign_in_android` 7.2.15), not that path — but a
 * sign-out/sign-in still needs exercising on-device to prove it.
 */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "time_app/secure_window"
        const val METHOD = "setSecure"
        const val TAG = "SecureWindow"

        // The full-screen-intent capability query. Requesting the grant is the
        // plugin's job (`requestFullScreenIntentPermission`); only the CHECK has
        // no Dart-side API, so this one method fills the gap.
        const val FSI_CHANNEL = "time_app/full_screen_intent"
        const val FSI_METHOD = "canUseFullScreenIntent"

        // The alarm-playback lifecycle. Dart (`AlarmScreen`) starts the sound on
        // mount and stops it on dismiss; the sound itself lives in
        // [AlarmSoundService] so it survives the screen going dark.
        const val ALARM_CHANNEL = "time_app/alarm_sound"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The reminder fire-timing audit (`reminder_audit_log.dart`). Registered
        // on `applicationContext`, not `this`: the alarms it arms outlive this
        // activity by hours, and holding an Activity in a PendingIntent's
        // context is how a leak becomes a crash on a 6am delivery.
        ReminderAuditChannel(applicationContext).register(flutterEngine.dartExecutor.binaryMessenger)

        // Can a full-screen reminder actually launch over the top of another app?
        // On Android 14+ (API 34) USE_FULL_SCREEN_INTENT is user-revocable for a
        // non-alarm app, so holding the manifest permission is not enough — the
        // real answer is `NotificationManager.canUseFullScreenIntent()`. Below 34
        // the permission is granted at install, so the capability is always true.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FSI_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != FSI_METHOD) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val allowed =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                            as NotificationManager
                        nm.canUseFullScreenIntent()
                    } else {
                        true
                    }
                result.success(allowed)
            }

        // Start / stop the alarm sound, and drive the window flags that make the
        // alarm UI show over the lock screen and stay lit while it rings.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        showOverLockAndWake(true)
                        AlarmSoundService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        AlarmSoundService.stop(this)
                        showOverLockAndWake(false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // A name mismatch here would answer notImplemented(), which Dart
                // surfaces as MissingPluginException — caught in secure_window.dart
                // and logged "expected off Android". That benign-sounding line IS
                // the bug this file fixes, so it must never be reachable on Android.
                if (call.method != METHOD) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                // Dart sends a bare bool, not a map (`invokeMethod<void>(METHOD, value)`).
                // Reading it as a named argument would yield null and no-op in silence.
                val enable = call.arguments as? Boolean
                if (enable == null) {
                    result.error(
                        "bad_args",
                        "$METHOD expects a boolean, got ${call.arguments}",
                        null,
                    )
                    return@setMethodCallHandler
                }

                // Handler callbacks arrive on the platform (main) thread, which is
                // where window flags must be set — no explicit hop needed.
                if (enable) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }

                // Read the flag back off the window rather than trusting the call.
                // No unit test can prove a native window effect, so this is the only
                // in-process check that the request actually landed; the log line is
                // ground truth for the on-device verification run (`adb logcat -s $TAG`).
                val applied =
                    (window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
                Log.i(TAG, "$METHOD($enable) → FLAG_SECURE applied=$applied")

                if (applied != enable) {
                    // Fail loudly. A silent mismatch is the failure mode that let a
                    // dead channel look healthy for the life of the feature.
                    result.error(
                        "not_applied",
                        "FLAG_SECURE requested=$enable but window reports applied=$applied",
                        null,
                    )
                } else {
                    result.success(null)
                }
            }
    }

    /**
     * Show this activity over the lock screen, turn the screen on for it, and
     * keep it lit while the alarm rings.
     *
     * KEEP_SCREEN_ON keeps the alarm UI visible; it is NOT what keeps the sound
     * going — [AlarmSoundService]'s wake lock does that, independent of the
     * screen. On API 27+ the show/turn-on flags are Activity setters; below that
     * they are window flags. Runs on the platform thread (a channel callback), so
     * the window can be touched directly.
     */
    private fun showOverLockAndWake(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
