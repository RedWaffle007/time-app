package com.timeapp.alarm_spike

import android.Manifest
import android.app.AlarmManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart side is a control panel and a log viewer, nothing more. Every
 * scheduling decision lives in Kotlin so that no measurement depends on a
 * Flutter engine being alive — which, during the interesting part of every
 * test, it deliberately is not.
 */
class MainActivity : FlutterActivity() {

    private val channel = "com.timeapp.alarm_spike/spike"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Notifications.ensureChannel(this)
        SpikeLog.write(this, event = "APP_OPEN")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(status())

                    "scheduleAt" -> {
                        val epoch = (call.argument<Any>("epochMillis") as Number).toLong()
                        result.success(AlarmScheduler.scheduleAll(this, epoch))
                    }

                    "cancelAll" -> {
                        AlarmScheduler.cancelAll(this)
                        result.success(true)
                    }

                    "readLog" -> result.success(SpikeLog.read(this))
                    "clearLog" -> { SpikeLog.clear(this); result.success(true) }
                    "logPath" -> result.success(SpikeLog.path(this))
                    "exportLog" -> result.success(SpikeLog.mirrorToExternal(this))

                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                        }
                        result.success(true)
                    }

                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            safeStart(
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(true)
                    }

                    "openBatteryOptimization" -> {
                        // The power allowlist is not just a Xiaomi nicety: an app on
                        // it is ALWAYS permitted to call setExact/setExactAndAllowWhileIdle,
                        // independent of the exact-alarm permission. That makes it a
                        // second, policy-free route to exact alarms and worth measuring.
                        safeStart(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName"))
                        )
                        result.success(true)
                    }

                    "openAutostart" -> { openAutostart(); result.success(true) }

                    "openAppDetails" -> {
                        safeStart(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        )
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun status(): Map<String, Any> {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "canScheduleExact" to AlarmScheduler.canScheduleExact(this),
            "battOptIgnored" to
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    pm.isIgnoringBatteryOptimizations(packageName)),
            "powerSave" to pm.isPowerSaveMode,
            "deviceIdle" to
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && pm.isDeviceIdleMode),
            "notificationsGranted" to
                (Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                    == PackageManager.PERMISSION_GRANTED),
            "nextAlarmClock" to (am.nextAlarmClock?.triggerTime ?: 0L),
            "logPath" to SpikeLog.path(this)
        )
    }

    /**
     * Xiaomi's Autostart screen is not a public API — it is an activity inside
     * the Security Center app, and the component name has moved between MIUI
     * versions. Try the known ones, then fall back to app details, which always
     * exists. Apps guide, they don't fight (DECISIONS.md).
     */
    private fun openAutostart() {
        val candidates = listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            ),
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity"
            )
        )
        for (c in candidates) {
            try {
                startActivity(Intent().setComponent(c).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (t: Throwable) { }
        }
        try {
            startActivity(Intent("miui.intent.action.OP_AUTO_START")
                .addCategory(Intent.CATEGORY_DEFAULT))
            return
        } catch (t: Throwable) { }
        safeStart(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$packageName"))
        )
    }

    private fun safeStart(intent: Intent) {
        try { startActivity(intent) } catch (t: Throwable) { }
    }
}
