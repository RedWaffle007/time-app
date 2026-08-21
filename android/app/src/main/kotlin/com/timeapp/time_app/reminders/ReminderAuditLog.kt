package com.timeapp.time_app.reminders

import android.content.Context
import android.os.Build
import android.os.PowerManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Append-only CSV of what the reminder layer actually did, on this phone.
 *
 * A direct port of `spikes/alarm_spike/.../SpikeLog.kt`, kept because the thing
 * it measures did not stop mattering when the spike ended. The spike answered
 * "can an exact alarm survive HyperOS" under laboratory conditions
 * (`run_2026-08-20_G2.csv`: +0.55s after a 4h39m screen-off window). This
 * answers the question that only real use can: does it keep doing that, on the
 * days nobody is watching.
 *
 * Two constraints drove the shape, and neither is negotiable:
 *
 *  1. **It is written while the app is DEAD.** The writer is a plain Kotlin
 *     BroadcastReceiver woken by the OS — no Flutter, no plugins, no Dart
 *     isolate. A Dart callback would add its own cold-start latency to every
 *     figure we are trying to measure, which is precisely the measurement.
 *
 *  2. **It must survive a reboot and be writable BEFORE the first unlock**,
 *     because [ReminderAuditBootReceiver] runs on LOCKED_BOOT_COMPLETED. That
 *     forces DEVICE-PROTECTED storage: credential-protected storage is not
 *     readable until the user types their PIN, and a write there before unlock
 *     throws.
 *
 * Nothing user-facing reads this. It is an instrument; see the manifest comment
 * for how to remove the whole thing.
 */
object ReminderAuditLog {

    private const val FILE_NAME = "reminder_audit.csv"
    private const val HEADER =
        "epoch_millis,local_time,event,item_id,notification_id,scheduled_epoch," +
            "scheduled_local,delay_seconds,idle,power_save,batt_opt_ignored,interactive,note"

    /**
     * Cap so a long-lived install cannot grow this without bound. When the file
     * passes the cap the OLDEST half is dropped and the header re-written —
     * recent rows are the ones that answer "is it still firing on time".
     */
    private const val MAX_BYTES = 512 * 1024

    /**
     * Device-protected storage: available before first unlock, survives reboot.
     * Every read and write goes through this one context so the log can never
     * split into two files depending on who wrote it.
     */
    fun deviceCtx(context: Context): Context =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }

    private fun file(context: Context): File {
        val dir = deviceCtx(context).filesDir
        if (!dir.exists()) dir.mkdirs()
        return File(dir, FILE_NAME)
    }

    private val fmt: SimpleDateFormat
        get() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    private fun localTime(millis: Long): String = fmt.format(Date(millis))

    /**
     * One row. [scheduledEpoch] is null for events that are not a fire (ARMED,
     * CANCELLED, BOOT, RECONCILE); when present, `delay_seconds` is the
     * measurement, and POSITIVE means the OS delivered LATE.
     */
    fun write(
        context: Context,
        event: String,
        itemId: String = "",
        notificationId: Int? = null,
        scheduledEpoch: Long? = null,
        atEpoch: Long = System.currentTimeMillis(),
        note: String = "",
    ) {
        try {
            val f = file(context)
            trimIfHuge(f)
            val fresh = !f.exists() || f.length() == 0L
            val delay = scheduledEpoch?.let {
                String.format(Locale.US, "%.3f", (atEpoch - it) / 1000.0)
            } ?: ""
            val s = state(context)
            val row = listOf(
                atEpoch.toString(),
                localTime(atEpoch),
                event,
                clean(itemId),
                notificationId?.toString() ?: "",
                scheduledEpoch?.toString() ?: "",
                scheduledEpoch?.let { localTime(it) } ?: "",
                delay,
                s.idle,
                s.powerSave,
                s.battOptIgnored,
                s.interactive,
                clean(note),
            ).joinToString(",")
            f.appendText((if (fresh) HEADER + "\n" else "") + row + "\n")
        } catch (t: Throwable) {
            // An instrument that crashes the receiver measures nothing, and this
            // receiver runs in the same process as a real reminder. Swallow.
        }
    }

    private fun clean(v: String) = v.replace(',', ';').replace('\n', ' ')

    private fun trimIfHuge(f: File) {
        try {
            if (!f.exists() || f.length() <= MAX_BYTES) return
            val lines = f.readLines()
            if (lines.size < 4) return
            val body = lines.drop(1).takeLast((lines.size - 1) / 2)
            f.writeText((listOf(HEADER) + body).joinToString("\n") + "\n")
        } catch (t: Throwable) {
        }
    }

    fun read(context: Context): String = try {
        file(context).takeIf { it.exists() }?.readText() ?: ""
    } catch (t: Throwable) {
        ""
    }

    fun clear(context: Context) {
        try {
            file(context).delete()
        } catch (t: Throwable) {
        }
    }

    fun path(context: Context): String = file(context).absolutePath

    data class State(
        val idle: String,
        val powerSave: String,
        val battOptIgnored: String,
        val interactive: String,
    )

    /**
     * Captured AT FIRE TIME, which is the only moment it means anything. If a
     * reminder lands 40 minutes late we need to know whether the phone was in
     * Doze when it finally arrived, otherwise the number says nothing about
     * whether the scheduling was at fault.
     */
    fun state(context: Context): State = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        State(
            idle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                b(pm.isDeviceIdleMode)
            } else {
                "?"
            },
            powerSave = b(pm.isPowerSaveMode),
            battOptIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                b(pm.isIgnoringBatteryOptimizations(context.packageName))
            } else {
                "?"
            },
            interactive = b(pm.isInteractive),
        )
    } catch (t: Throwable) {
        State("?", "?", "?", "?")
    }

    private fun b(v: Boolean) = if (v) "1" else "0"
}
