package com.timeapp.time_app

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.content.ContextCompat
import com.timeapp.time_app.reminders.AlarmDeliveryChannel
import com.timeapp.time_app.reminders.AlarmLifecycleChannel
import com.timeapp.time_app.reminders.AlarmSoundService
import com.timeapp.time_app.reminders.ReminderAuditChannel
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

    // Preloaded once so tick #1 has no file-open latency. Created lazily on first
    // use (channel call), which is the cold-start reveal mounting.
    private var splashSound: SplashSound? = null
    private var alarmKeyChannel: MethodChannel? = null
    private var alarmEndedReceiverRegistered = false
    private val alarmWakeWindow by lazy {
        AlarmWakeWindowController(
            sdkInt = Build.VERSION.SDK_INT,
            host = object : AlarmWakeWindowHost {
                override fun setModern(showWhenLocked: Boolean, turnScreenOn: Boolean) {
                    this@MainActivity.setShowWhenLocked(showWhenLocked)
                    this@MainActivity.setTurnScreenOn(turnScreenOn)
                }

                override fun setLegacy(enabled: Boolean) {
                    @Suppress("DEPRECATION")
                    val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    if (enabled) window.addFlags(flags) else window.clearFlags(flags)
                }

                override fun setKeepScreenOn(enabled: Boolean) {
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
            },
        )
    }
    private val alarmEndedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AlarmSoundService.ACTION_RINGING_ENDED) {
                showOverLockAndWake(false)
            }
        }
    }

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
        const val ALARM_KEY_CHANNEL = "time_app/alarm_keys"

        // The cold-start reveal's clock ting. Fired once from Dart as the black
        // splash mounts; duration + the mute-switch check live in [SplashSound].
        const val SPLASH_SOUND_CHANNEL = "time_app/splash_sound"

        // A reinstall boundary that Android Auto Backup cannot fake. Package
        // firstInstallTime survives updates but changes after uninstall, while
        // restored SharedPreferences may still claim onboarding was completed.
        const val INSTALL_IDENTITY_CHANNEL = "time_app/install_identity"

        // Battery / Doze exemption. `isIgnoring` reports the current state;
        // `request` fires the DIRECT system yes/no dialog (needs the
        // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission — see the manifest).
        const val BATTERY_CHANNEL = "time_app/battery"

        // OEM autostart. There is no standard permission and no guaranteed public
        // intent — each OEM buries it behind its own private Activity, and those
        // move between versions. So this NEVER blind-launches: it resolve-checks a
        // candidate component map against the PackageManager and only launches one
        // the device actually has. `canOpen` lets Dart decide between a deep-link
        // button and a purely-instructional guided card.
        const val AUTOSTART_CHANNEL = "time_app/autostart"

        // Candidate autostart / background-launch Activities, most-specific first.
        // Only the manufacturer's own package is installed on any given device, so
        // at most one of these resolves; the resolve-check is what makes trying
        // them all safe. This is the dontkillmyapp.com component list — kept here,
        // native, because resolving a ComponentName needs the PackageManager.
        val AUTOSTART_COMPONENTS = listOf(
            // Xiaomi / Redmi / Poco (MIUI / HyperOS)
            "com.miui.securitycenter" to
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // Oppo / Realme (ColorOS)
            "com.coloros.safecenter" to
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to
                "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to
                "com.oppo.safe.permission.startup.StartupAppListActivity",
            // Vivo / iQOO
            "com.vivo.permissionmanager" to
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to
                "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            // OnePlus (older OxygenOS; newer is ColorOS-based, covered above)
            "com.oneplus.security" to
                "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            // Huawei / Honor
            "com.huawei.systemmanager" to
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to
                "com.huawei.systemmanager.optimize.process.ProtectActivity",
        )
    }

    // Firebase App Distribution in-app update check. On each foreground of a
    // DEBUG tester build this pops the "New version available" dialog (and signs
    // the tester in on the first run); in a release build `AppDistributionUpdate`
    // is the no-op stub from src/release. See DECISIONS.md "Firebase App
    // Distribution".
    override fun onResume() {
        super.onResume()
        AppDistributionUpdate.checkForUpdate(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(
            this,
            alarmEndedReceiver,
            IntentFilter(AlarmSoundService.ACTION_RINGING_ENDED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        alarmEndedReceiverRegistered = true
        syncAlarmWake(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        syncAlarmWake(intent)
    }

    override fun onDestroy() {
        showOverLockAndWake(false)
        if (alarmEndedReceiverRegistered) {
            unregisterReceiver(alarmEndedReceiver)
            alarmEndedReceiverRegistered = false
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The reminder fire-timing audit (`reminder_audit_log.dart`). Registered
        // on `applicationContext`, not `this`: the alarms it arms outlive this
        // activity by hours, and holding an Activity in a PendingIntent's
        // context is how a leak becomes a crash on a 6am delivery.
        ReminderAuditChannel(applicationContext).register(flutterEngine.dartExecutor.binaryMessenger)
        // This is the due-time audio arm. Without registering the channel Dart
        // receives MissingPluginException, records AUDIO_ARM_FAILED, and no
        // native receiver exists until opening Flutter triggers the UI fallback.
        AlarmDeliveryChannel(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)
        AlarmLifecycleChannel(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)
        alarmKeyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ALARM_KEY_CHANNEL,
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_IDENTITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "current") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                @Suppress("DEPRECATION")
                val firstInstallTime =
                    packageManager.getPackageInfo(packageName, 0).firstInstallTime
                result.success(firstInstallTime.toString())
            }

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
                        AlarmSoundService.startForItem(
                            this,
                            call.argument<String>("itemId") ?: "",
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        AlarmSoundService.stopForItem(
                            this,
                            call.argument<String>("itemId") ?: "",
                        )
                        showOverLockAndWake(false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Battery / Doze exemption. `request` is the DIRECT dialog, chosen over
        // the battery-optimization list so the user taps once and stays in flow.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoring" -> result.success(isIgnoringBatteryOptimizations())
                    "request" -> result.success(requestIgnoreBatteryOptimizations())
                    else -> result.notImplemented()
                }
            }

        // OEM autostart. `open` resolve-checks and launches; `canOpen` only
        // reports whether a launchable component exists on THIS device, so Dart
        // can fall back to a guided card where it does not.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUTOSTART_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canOpen" -> result.success(resolveAutostartIntent() != null)
                    "open" -> result.success(openAutostartSettings())
                    else -> result.notImplemented()
                }
            }

        // The cold-start reveal's clock ting. Constructed HERE (engine config,
        // which runs before the Dart entrypoint) so the sample is preloaded well
        // before the splash mounts — otherwise the async SoundPool load would
        // race tick #1 and drop it.
        val splash = SplashSound(applicationContext).also { splashSound = it }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPLASH_SOUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> { splash.play(); result.success(null) }
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
     * Volume Down can silence only while this foreground Activity receives the
     * hardware event. Android may route it to system volume instead when the UI
     * is absent; no accessibility/global-key privilege is requested to bypass
     * that platform boundary.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (AlarmHardwareKeyPolicy.shouldSilence(
                keyCode = event.keyCode,
                action = event.action,
                repeatCount = event.repeatCount,
                ringing = AlarmSoundService.isRinging(),
                volumeDownKeyCode = KeyEvent.KEYCODE_VOLUME_DOWN,
                actionDown = KeyEvent.ACTION_DOWN,
            )
        ) {
            if (AlarmSoundService.silenceFromVolumeDown(this)) {
                Log.i(TAG, "Volume Down silenced active alarm")
                alarmKeyChannel?.invokeMethod("volumeSilenced", null)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * Whether this app is exempt from battery optimizations (Doze). Below
     * Android M there was no Doze, so nothing to be exempt from → report true.
     */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Fire the direct battery-optimization dialog for THIS app. Returns whether
     * the intent could be launched at all — never throws, so a locked-down OEM
     * that refuses the intent degrades to a guided fallback rather than crashing.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
            // Resolve-check first: some OEMs strip this action. Never blind-launch.
            if (intent.resolveActivity(packageManager) == null) {
                // Fall back to the whole battery-optimization list, which every
                // device with Doze has. Not the direct dialog, but it gets there.
                val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                if (list.resolveActivity(packageManager) == null) return false
                startActivity(list)
                return true
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "battery-exemption request failed: $e")
            false
        }
    }

    /**
     * The first autostart Activity from [AUTOSTART_COMPONENTS] that actually
     * resolves on this device, or null if none does (unknown OEM, or the OEM
     * moved/removed it). Resolving is the whole safety story — a ComponentName
     * that does not resolve is never launched.
     */
    private fun resolveAutostartIntent(): Intent? {
        for ((pkg, cls) in AUTOSTART_COMPONENTS) {
            val intent = Intent().apply {
                component = ComponentName(pkg, cls)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) return intent
        }
        return null
    }

    /** Launch the resolved autostart screen; false if none resolves or it throws. */
    private fun openAutostartSettings(): Boolean {
        val intent = resolveAutostartIntent() ?: return false
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            // A component can resolve and still refuse to launch (permission,
            // exported=false on a newer build). Report failure so Dart shows the
            // guided card instead of leaving the user staring at nothing.
            Log.w(TAG, "autostart launch failed: $e")
            false
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
        alarmWakeWindow.setEnabled(on)
    }

    private fun syncAlarmWake(launchIntent: Intent?) {
        val isAlarm = AlarmLaunchPolicy.isAlarmLaunch(
            action = launchIntent?.action,
            payload = launchIntent?.getStringExtra("payload"),
        )
        showOverLockAndWake(isAlarm)
    }
}
