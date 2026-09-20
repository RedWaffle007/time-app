package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restores native audio alarms after reboot, package update, or clock change. */
class AlarmDeliveryBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        val future = AlarmDeliveryStore.load(context).filter { it.scheduledEpoch > now }
        future.forEach { item ->
            AlarmDeliveryScheduler.arm(
                context,
                item.id,
                item.itemId,
                item.scheduledEpoch,
                item.exact,
            )
        }
        AlarmDeliveryStore.save(context, future)
    }
}
