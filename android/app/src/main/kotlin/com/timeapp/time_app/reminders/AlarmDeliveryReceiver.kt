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
        val now = System.currentTimeMillis()
        val headline = AlarmDeliveryScheduler.readHeadline(intent)
        val voice = AlarmDeliveryScheduler.readVoice(intent)
        // 2026-10-04: where this alarm is in its 25-minute cycle decides what
        // happens. On time, that is ring 1; a later ring was armed by the end
        // of the one before; a late delivery joins wherever it lands.
        val ring = when (val phase = RingCyclePolicy.phaseAt(scheduledEpoch, now)) {
            RingCyclePolicy.Phase.Over -> {
                AlarmSoundService.missWithoutRinging(context, itemId, headline, now, scheduledEpoch)
                return
            }
            is RingCyclePolicy.Phase.Gap -> {
                AlarmSoundService.enterQuiet(
                    context, id, itemId, scheduledEpoch, phase.nextIndex, phase.nextAt, headline, voice,
                )
                return
            }
            is RingCyclePolicy.Phase.Ring -> phase
        }
        val started = AlarmSoundService.start(
            context,
            id,
            itemId,
            headline,
            voice,
            scheduledEpoch,
            ring.index,
            ring.endsAt,
        )
        ReminderAuditLog.write(
            context,
            event = if (started) "AUDIO_START_REQUESTED" else "AUDIO_START_FAILED",
            itemId = itemId,
            notificationId = id,
            scheduledEpoch = scheduledEpoch.takeIf { it > 0 },
            note = "native_receiver ring ${ring.index}",
        )
    }
}
