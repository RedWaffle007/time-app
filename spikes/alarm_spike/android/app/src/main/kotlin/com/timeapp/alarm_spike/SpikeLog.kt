package com.timeapp.alarm_spike

import android.content.Context
import android.os.Build
import android.os.PowerManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Append-only CSV log. THE ENTIRE POINT OF THE SPIKE.
 *
 * Two constraints drove this shape:
 *
 *  1. It must be written by code running while the app is DEAD (a BroadcastReceiver
 *     woken by the OS). So no Flutter, no plugins, no Dart isolate — plain Kotlin
 *     and a file. A Dart callback isolate would add its own startup latency to
 *     every measurement, which is exactly the number we are trying to measure.
 *
 *  2. It must survive a reboot AND be writable before the first unlock, because
 *     BootReceiver runs on LOCKED_BOOT_COMPLETED. That means DEVICE-PROTECTED
 *     storage — credential-protected storage is not readable until the user
 *     types their PIN, and a write there before unlock throws.
 */
object SpikeLog {

    private const val FILE_NAME = "alarm_spike_log.csv"
    private const val HEADER =
        "epoch_millis,local_time,event,variant,scheduled_epoch,scheduled_local,delay_seconds,idle,power_save,batt_opt_ignored,interactive,note"

    /**
     * Device-protected storage: available before first unlock, survives reboot.
     * Every read and write in the spike goes through this one context so the
     * log can never split into two files depending on who wrote it.
     */
    fun deviceCtx(context: Context): Context =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
            context.createDeviceProtectedStorageContext()
        else context

    private fun file(context: Context): File {
        val dir = deviceCtx(context).filesDir
        if (!dir.exists()) dir.mkdirs()
        return File(dir, FILE_NAME)
    }

    private val fmt: SimpleDateFormat
        get() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    fun localTime(millis: Long): String = fmt.format(Date(millis))

    /**
     * One row. [scheduledEpoch] is null for events that aren't a fire (BOOT,
     * CANCELLED, APP_OPEN); when present, delay_seconds is the measurement —
     * positive means the OS delivered LATE.
     */
    fun write(
        context: Context,
        event: String,
        variant: String = "",
        scheduledEpoch: Long? = null,
        firedEpoch: Long = System.currentTimeMillis(),
        note: String = ""
    ) {
        try {
            val f = file(context)
            val fresh = !f.exists() || f.length() == 0L
            val delay = scheduledEpoch?.let {
                String.format(Locale.US, "%.3f", (firedEpoch - it) / 1000.0)
            } ?: ""
            val s = state(context)
            val row = listOf(
                firedEpoch.toString(),
                localTime(firedEpoch),
                event,
                variant,
                scheduledEpoch?.toString() ?: "",
                scheduledEpoch?.let { localTime(it) } ?: "",
                delay,
                s.idle,
                s.powerSave,
                s.battOptIgnored,
                s.interactive,
                note.replace(',', ';').replace('\n', ' ')
            ).joinToString(",")
            f.appendText((if (fresh) HEADER + "\n" else "") + row + "\n")
        } catch (t: Throwable) {
            // A spike that crashes the receiver measures nothing. Swallow.
        }
    }

    fun read(context: Context): String =
        try { file(context).takeIf { it.exists() }?.readText() ?: "" } catch (t: Throwable) { "" }

    fun clear(context: Context) {
        try { file(context).delete() } catch (t: Throwable) { }
    }

    fun path(context: Context): String = file(context).absolutePath

    /**
     * Best-effort mirror to the external files dir so the log can be pulled with
     * `adb pull` without reading it off the screen. Only possible after unlock,
     * and some ROMs restrict /sdcard/Android/data — hence best-effort, and the
     * in-app viewer stays the primary readout.
     */
    fun mirrorToExternal(context: Context): String? = try {
        val ext = context.getExternalFilesDir(null)
        if (ext == null) null else {
            val out = File(ext, FILE_NAME)
            out.writeText(read(context))
            out.absolutePath
        }
    } catch (t: Throwable) { null }

    data class State(
        val idle: String,
        val powerSave: String,
        val battOptIgnored: String,
        val interactive: String
    )

    /**
     * Captured AT FIRE TIME, which is the only moment it means anything. If an
     * alarm lands 40 minutes late we need to know whether the phone was in Doze
     * when it finally arrived, otherwise the number is uninterpretable.
     */
    fun state(context: Context): State {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            State(
                idle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    b(pm.isDeviceIdleMode) else "?",
                powerSave = b(pm.isPowerSaveMode),
                battOptIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    b(pm.isIgnoringBatteryOptimizations(context.packageName)) else "?",
                interactive = b(pm.isInteractive)
            )
        } catch (t: Throwable) {
            State("?", "?", "?", "?")
        }
    }

    private fun b(v: Boolean) = if (v) "1" else "0"
}
