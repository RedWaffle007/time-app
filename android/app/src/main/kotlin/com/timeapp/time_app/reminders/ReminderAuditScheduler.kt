package com.timeapp.time_app.reminders

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Arms and cancels the SILENT shadow alarm that measures fire timing.
 *
 * It posts nothing and shows nothing. Its only effect is one CSV row in
 * [ReminderAuditLog] at the instant the OS delivers it — which, because it is
 * armed at the same instant and with the same mechanism as the reminder it
 * shadows (`setExactAndAllowWhileIdle`, matching
 * `AndroidScheduleMode.exactAllowWhileIdle`), is a faithful stand-in for when
 * the reminder itself fired.
 *
 * Why a shadow at all: flutter_local_notifications posts its notification from
 * its own native receiver without ever starting Dart, so there is no callback
 * anywhere in which the app could observe its own fire time. The choice is
 * between a second alarm and no measurement.
 */
object ReminderAuditScheduler {

    private const val EXTRA_ID = "audit_id"
    private const val EXTRA_ITEM = "audit_item_id"
    private const val EXTRA_SCHEDULED = "audit_scheduled_epoch"

    /**
     * Request codes are namespaced away from the notification ids so an audit
     * PendingIntent can never collide with anything the plugin registered.
     * `xor` keeps it a pure function of the id (cancel must reconstruct it) and
     * stays inside 31 bits.
     */
    private fun requestCode(id: Int) = (id xor 0x5EED_1234.toInt()) and 0x7FFF_FFFF

    private fun intent(context: Context, id: Int, itemId: String, scheduledEpoch: Long) =
        Intent(context, ReminderAuditReceiver::class.java).apply {
            // A distinct action per id: two Intents that differ only in their
            // extras are `filterEquals`, so PendingIntent would reuse the first
            // one's extras for every later alarm and every row would name the
            // same item.
            action = "com.timeapp.time_app.REMINDER_AUDIT.$id"
            putExtra(EXTRA_ID, id)
            putExtra(EXTRA_ITEM, itemId)
            putExtra(EXTRA_SCHEDULED, scheduledEpoch)
        }

    private fun pending(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        flags: Int,
    ): PendingIntent? = PendingIntent.getBroadcast(
        context,
        requestCode(id),
        intent(context, id, itemId, scheduledEpoch),
        flags or PendingIntent.FLAG_IMMUTABLE,
    )

    /** Returns "ok", or a short reason the caller can log. Never throws. */
    fun arm(context: Context, id: Int, itemId: String, scheduledEpoch: Long): String {
        return try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = pending(context, id, itemId, scheduledEpoch, PendingIntent.FLAG_UPDATE_CURRENT)
                ?: return "no_pending_intent"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, scheduledEpoch, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, scheduledEpoch, pi)
            }
            ReminderAuditStore.put(
                context,
                ReminderAuditStore.Pending(id, itemId, scheduledEpoch),
            )
            "ok"
        } catch (se: SecurityException) {
            // SCHEDULE_EXACT_ALARM revoked — the single most common cause of a
            // reminder that silently never arrives, and on this device every
            // reinstall causes it. Recorded so the CSV shows WHY nothing fired.
            ReminderAuditLog.write(
                context,
                event = "AUDIT_ARM_FAILED",
                itemId = itemId,
                notificationId = id,
                scheduledEpoch = scheduledEpoch,
                note = "SecurityException: ${se.message}",
            )
            "exact_alarm_denied"
        } catch (t: Throwable) {
            "error: ${t.javaClass.simpleName}"
        }
    }

    fun cancel(context: Context, id: Int) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // FLAG_NO_CREATE: if no such alarm exists there is nothing to cancel,
            // and we must not conjure one just to cancel it.
            pending(context, id, "", 0L, PendingIntent.FLAG_NO_CREATE)?.let {
                am.cancel(it)
                it.cancel()
            }
        } catch (t: Throwable) {
        } finally {
            ReminderAuditStore.remove(context, id)
        }
    }

    fun cancelAll(context: Context) {
        ReminderAuditStore.load(context).forEach { cancel(context, it.id) }
        ReminderAuditStore.clear(context)
    }

    fun readExtras(intent: Intent): Triple<Int, String, Long> = Triple(
        intent.getIntExtra(EXTRA_ID, -1),
        intent.getStringExtra(EXTRA_ITEM) ?: "",
        intent.getLongExtra(EXTRA_SCHEDULED, 0L),
    )
}
