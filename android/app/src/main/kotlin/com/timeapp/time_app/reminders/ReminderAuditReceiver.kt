package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The measurement itself: one CSV row, at the instant the OS delivered the
 * shadow alarm.
 *
 * Plain Kotlin on purpose. This runs in a process the OS just woke from nothing,
 * and the number being recorded is the OS's delivery latency — starting a Dart
 * isolate here would fold Flutter's cold start into every reading and quietly
 * make the instrument report its own overhead as Xiaomi's.
 */
class ReminderAuditReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val at = System.currentTimeMillis()
        val (id, itemId, scheduledEpoch) = ReminderAuditScheduler.readExtras(intent)

        ReminderAuditLog.write(
            context,
            event = "FIRED",
            itemId = itemId,
            notificationId = if (id >= 0) id else null,
            scheduledEpoch = if (scheduledEpoch > 0) scheduledEpoch else null,
            atEpoch = at,
            note = "audit",
        )

        // Drop it from the pending set, so a later reboot cannot resurrect an
        // alarm that has already fired and log a phantom MISSED_AT_BOOT.
        if (id >= 0) ReminderAuditStore.remove(context, id)
    }
}
