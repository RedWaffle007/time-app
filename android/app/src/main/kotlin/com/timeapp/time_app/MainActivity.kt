package com.timeapp.time_app

import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
}
