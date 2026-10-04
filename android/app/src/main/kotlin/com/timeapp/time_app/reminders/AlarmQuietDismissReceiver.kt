package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Dismiss on the "Rings again at …" notice (2026-10-04): the alarm is
 * answered between rings. Cancels the next ring and records a dismissal,
 * exactly like Dismiss while it rings — the app turns that into the
 * planner's "dismissed" (or a voice note's "heard").
 */
class AlarmQuietDismissReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_ID = "quiet_notification_id"
        const val EXTRA_ITEM = "quiet_item_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(EXTRA_ID, -1)
        val itemId = intent.getStringExtra(EXTRA_ITEM).orEmpty()
        if (id < 0 || itemId.isEmpty()) return
        val at = System.currentTimeMillis()
        AlarmDeliveryScheduler.cancel(context, id)
        AlarmLifecycleStore.record(context, itemId, AlarmLifecycleStore.KIND_DISMISSED, at)
        ReminderAuditLog.write(
            context,
            event = "QUIET_DISMISSED",
            itemId = itemId,
            notificationId = id,
            atEpoch = at,
            note = "notification_action",
        )
        AlarmLifecycleChannel.notifyChanged()
    }
}
