package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts alarm audio at fire time, regardless of notification/UI treatment. */
class AlarmDeliveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val (id, itemId, scheduledEpoch) = AlarmDeliveryScheduler.readExtras(intent)
        if (id < 0 || itemId.isEmpty()) return

        ReminderAuditLog.write(
            context,
            event = "AUDIO_FIRED",
            itemId = itemId,
            notificationId = id,
            scheduledEpoch = scheduledEpoch.takeIf { it > 0 },
            note = "native_receiver",
        )
        AlarmDeliveryStore.remove(context, id)
        val started = AlarmSoundService.start(context, id, itemId)
        ReminderAuditLog.write(
            context,
            event = if (started) "AUDIO_START_REQUESTED" else "AUDIO_START_FAILED",
            itemId = itemId,
            notificationId = id,
            scheduledEpoch = scheduledEpoch.takeIf { it > 0 },
            note = "native_receiver",
        )
    }
}
