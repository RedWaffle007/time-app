package com.timeapp.alarm_spike

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * Schedules FOUR mechanisms at the SAME target instant, so a single run
 * produces a directly comparable row per mechanism. Comparing them across
 * separate runs would be worthless — Doze depth, screen state and the OEM's
 * mood all differ minute to minute.
 */
object AlarmScheduler {

    /** setAlarmClock — the strongest primitive. Doze-exempt, shows the status-bar alarm icon. */
    const val ALARM_CLOCK = "ALARM_CLOCK"

    /** setExactAndAllowWhileIdle — exact, Doze-exempt, no alarm icon, no user-visible claim. */
    const val EXACT_IDLE = "EXACT_IDLE"

    /** setAndAllowWhileIdle — INEXACT baseline. Fires in Doze but rate-limited to ~1 per 9-15 min. */
    const val INEXACT_IDLE = "INEXACT_IDLE"

    /** WorkManager one-shot — the substrate DECISIONS.md proposed. Batched by JobScheduler. */
    const val WORKMANAGER = "WORKMANAGER"

    val ALL = listOf(ALARM_CLOCK, EXACT_IDLE, INEXACT_IDLE, WORKMANAGER)

    private const val WM_UNIQUE = "alarm_spike_wm"

    private fun requestCode(variant: String) = when (variant) {
        ALARM_CLOCK -> 1001
        EXACT_IDLE -> 1002
        INEXACT_IDLE -> 1003
        else -> 1009
    }

    private fun pendingIntent(context: Context, variant: String, scheduledEpoch: Long): PendingIntent {
        val i = Intent(context, AlarmReceiver::class.java).apply {
            action = "com.timeapp.alarm_spike.FIRE.$variant"
            putExtra(AlarmReceiver.EXTRA_VARIANT, variant)
            putExtra(AlarmReceiver.EXTRA_SCHEDULED, scheduledEpoch)
        }
        return PendingIntent.getBroadcast(
            context, requestCode(variant), i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    fun canScheduleExact(context: Context): Boolean {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) am.canScheduleExactAlarms() else true
    }

    /**
     * Schedules every variant at [scheduledEpoch] and records a SCHEDULED row per
     * variant, so the log is self-contained: you can reconstruct what was asked
     * for without the app, which matters when the interesting run is one you
     * slept through.
     */
    fun scheduleAll(context: Context, scheduledEpoch: Long): Map<String, String> {
        Notifications.ensureChannel(context)
        val results = mutableMapOf<String, String>()
        val pending = mutableListOf<SpikeStore.Pending>()

        for (variant in ALL) {
            val outcome = schedule(context, variant, scheduledEpoch)
            results[variant] = outcome
            if (outcome == "ok") pending.add(SpikeStore.Pending(variant, scheduledEpoch))
            SpikeLog.write(
                context,
                event = if (outcome == "ok") "SCHEDULED" else "SCHEDULE_FAILED",
                variant = variant,
                scheduledEpoch = scheduledEpoch,
                note = if (outcome == "ok") "" else outcome
            )
        }
        SpikeStore.save(context, pending)
        return results
    }

    /** Re-arms one variant without re-logging a whole run — used by BootReceiver. */
    fun schedule(context: Context, variant: String, scheduledEpoch: Long): String {
        return try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            when (variant) {
                ALARM_CLOCK -> {
                    val show = PendingIntent.getActivity(
                        context, 2001,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                    am.setAlarmClock(
                        AlarmManager.AlarmClockInfo(scheduledEpoch, show),
                        pendingIntent(context, variant, scheduledEpoch)
                    )
                }
                EXACT_IDLE -> am.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, scheduledEpoch,
                    pendingIntent(context, variant, scheduledEpoch)
                )
                INEXACT_IDLE -> am.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, scheduledEpoch,
                    pendingIntent(context, variant, scheduledEpoch)
                )
                WORKMANAGER -> {
                    val delay = (scheduledEpoch - System.currentTimeMillis()).coerceAtLeast(0)
                    val req = OneTimeWorkRequestBuilder<SpikeWorker>()
                        .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                        .setInputData(
                            Data.Builder()
                                .putLong(SpikeWorker.KEY_SCHEDULED, scheduledEpoch)
                                .build()
                        )
                        .build()
                    WorkManager.getInstance(context)
                        .enqueueUniqueWork(WM_UNIQUE, ExistingWorkPolicy.REPLACE, req)
                }
            }
            "ok"
        } catch (se: SecurityException) {
            // The exact-alarm permission is missing. This is the honest failure
            // mode we want recorded, not a crash.
            "SecurityException: ${se.message}"
        } catch (t: Throwable) {
            "${t.javaClass.simpleName}: ${t.message}"
        }
    }

    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        listOf(ALARM_CLOCK, EXACT_IDLE, INEXACT_IDLE).forEach {
            try { am.cancel(pendingIntent(context, it, 0L)) } catch (t: Throwable) { }
        }
        try { WorkManager.getInstance(context).cancelUniqueWork(WM_UNIQUE) } catch (t: Throwable) { }
        SpikeStore.clear(context)
        SpikeLog.write(context, event = "CANCELLED", note = "all variants")
    }
}
