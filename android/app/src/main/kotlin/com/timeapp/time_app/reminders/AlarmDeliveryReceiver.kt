package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * An OS alarm fired: a plan's time, or the ring queue's own wake-up
 * (2026-10-05). Either way the queue looks now and decides what rings — no
 * Dart, no UI, so a dead app still rings.
 */
class AlarmDeliveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val queueWake = intent.action == AlarmDeliveryScheduler.ACTION_QUEUE_WAKE
        val (id, itemId, scheduledEpoch) = AlarmDeliveryScheduler.readExtras(intent)
        if (!queueWake && (id < 0 || itemId.isEmpty())) return
        ReminderAuditLog.write(
            context,
            event = if (queueWake) "QUEUE_WOKE" else "AUDIO_FIRED",
            itemId = itemId,
            notificationId = id.takeIf { it >= 0 },
            scheduledEpoch = scheduledEpoch.takeIf { it > 0 },
            note = "native_receiver",
        )
        val started = AlarmSoundService.kick(context)
        if (!started) {
            ReminderAuditLog.write(
                context,
                event = "AUDIO_START_FAILED",
                itemId = itemId,
                notificationId = id.takeIf { it >= 0 },
                note = "native_receiver",
            )
        }
    }
}
