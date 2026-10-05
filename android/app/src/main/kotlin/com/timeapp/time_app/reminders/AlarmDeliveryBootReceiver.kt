package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restores the ring queue after a reboot, package update or clock change:
 * every plan not yet rung gets its OS alarm back, and the queue's wake-up is
 * re-armed — soon, when something is already due (a foreground service may
 * not start from a boot broadcast on newer Android, but may from an alarm).
 */
class AlarmDeliveryBootReceiver : BroadcastReceiver() {
    companion object {
        private const val DUE_NOW_DELAY_MS = 2_000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        val rows = AlarmDeliveryStore.load(context)
        rows.filter { it.ringsDone == 0 && it.scheduledEpoch > now }.forEach { row ->
            AlarmDeliveryScheduler.arm(
                context,
                row.id,
                row.itemId,
                row.scheduledEpoch,
                row.exact,
                row.headline,
                row.voice,
                row.voiceMs,
            )
        }
        val alarms = rows.map { it.toAlarm() }
        val at = if (RingQueuePolicy.nextSegment(alarms, now) != null) {
            now + DUE_NOW_DELAY_MS
        } else {
            RingQueuePolicy.nextWakeAt(alarms, now)
        }
        if (at != null) AlarmDeliveryScheduler.armQueueWake(context, at, rows.firstOrNull()?.itemId.orEmpty())
    }
}
