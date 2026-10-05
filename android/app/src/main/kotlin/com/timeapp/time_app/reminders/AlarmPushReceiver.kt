package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.firebase.auth.FirebaseAuth
import java.io.File

/**
 * Arms a "new alarm for you" push natively, the moment it lands (device
 * report 2026-10-05).
 *
 * With the app killed, firebase_messaging runs the Dart handler in a separate
 * background engine — and the app's own native channels (alarm arming, the
 * audit log) are registered only on the main screen's engine. So that handler
 * could never arm the native alarm: a plan made while the app was closed rang
 * only once the person opened the app. This receiver sits beside the plugin's
 * own (FCM delivers its broadcast to every matching receiver in the package),
 * reads the same `scheduleReminder` data and arms the alarm with its voice
 * note — no Dart needed. The Dart handler still shows the notice and fetches
 * the note into the same file; the app's reconciler re-arms under the same id.
 */
class AlarmPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        val data = extras.keySet().associateWith { extras.get(it)?.toString().orEmpty() }
        val now = System.currentTimeMillis()
        val push = AlarmPushPolicy.parse(data, now) ?: return
        val uid = try {
            FirebaseAuth.getInstance().currentUser?.uid
        } catch (_: Throwable) {
            null
        }
        // Only the signed-in person's own alarm.
        if (uid == null || uid != push.targetUid) return
        val voice = push.voiceSha256?.let { sha ->
            VoiceAlarmSpec.of(
                File(File(context.filesDir, "voice-notes"), "${push.itemId}.m4a").path,
                sha,
                push.voiceSizeBytes,
            )
        }
        val id = AlarmPushPolicy.notificationId(push.itemId)
        val result = AlarmDeliveryScheduler.arm(
            context,
            id,
            push.itemId,
            push.fireAtEpoch,
            exact = true,
            headline = push.title,
            voice = voice,
            voiceMs = push.voiceDurationMs,
        )
        ReminderAuditLog.write(
            context,
            event = if (result == "ok") "PUSH_ARMED" else "PUSH_ARM_FAILED",
            itemId = push.itemId,
            notificationId = id,
            scheduledEpoch = push.fireAtEpoch,
            note = if (voice != null) "voice $result" else result,
        )
    }
}

/** The `scheduleReminder` push, parsed. Pure, so it is unit-tested. */
internal object AlarmPushPolicy {
    data class Push(
        val itemId: String,
        val targetUid: String,
        val fireAtEpoch: Long,
        val title: String,
        val voiceSha256: String?,
        val voiceSizeBytes: Long,
        val voiceDurationMs: Long,
    )

    fun parse(data: Map<String, String>, nowEpoch: Long): Push? {
        if (data["command"] != "scheduleReminder") return null
        val itemId = data["itemId"].orEmpty()
        val target = data["targetUid"].orEmpty()
        val title = data["title"].orEmpty()
        if (itemId.isEmpty() || target.isEmpty() || title.isEmpty()) return null
        val fireAt = try {
            java.time.Instant.parse(data["fireAtUtc"].orEmpty()).toEpochMilli()
        } catch (_: Exception) {
            return null
        }
        if (fireAt <= nowEpoch) return null
        val sha = data["voiceSha256"]?.takeIf { Regex("^[0-9a-f]{64}$").matches(it) }
        val size = data["voiceSizeBytes"]?.toLongOrNull() ?: 0L
        return Push(
            itemId,
            target,
            fireAt,
            title,
            if (sha != null && size > 0) sha else null,
            size,
            data["voiceDurationMs"]?.toLongOrNull()?.coerceAtLeast(0L) ?: 0L,
        )
    }

    /**
     * The same id Dart's `reminderNotificationId` gives (32-bit FNV-1a over
     * the UTF-8 item id, kept to 31 bits), so the app's later arming
     * replaces this one instead of adding a second alarm.
     */
    fun notificationId(itemId: String): Int {
        var hash = 0x811c9dc5L
        for (b in itemId.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (b.toLong() and 0xFF)
            hash = (hash * 0x01000193L) and 0xFFFFFFFFL
        }
        return (hash and 0x7FFFFFFFL).toInt()
    }
}
