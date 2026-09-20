package com.timeapp.time_app.reminders

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Arms the OS alarm whose receiver starts audio without launching Flutter. */
object AlarmDeliveryScheduler {
    private const val EXTRA_ID = "delivery_id"
    private const val EXTRA_ITEM = "delivery_item_id"
    private const val EXTRA_SCHEDULED = "delivery_scheduled_epoch"

    private fun requestCode(id: Int) = (id xor 0x41A2_6D37) and 0x7FFF_FFFF

    private fun intent(context: Context, id: Int, itemId: String, scheduledEpoch: Long) =
        Intent(context, AlarmDeliveryReceiver::class.java).apply {
            action = "com.timeapp.time_app.ALARM_DELIVERY.$id"
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

    /** Returns a short result for Dart diagnostics and never throws. */
    fun arm(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        exact: Boolean,
    ): String = try {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val operation = pending(
            context,
            id,
            itemId,
            scheduledEpoch,
            PendingIntent.FLAG_UPDATE_CURRENT,
        ) ?: return "no_pending_intent"

        when {
            exact && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                manager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    scheduledEpoch,
                    operation,
                )
            exact -> manager.setExact(AlarmManager.RTC_WAKEUP, scheduledEpoch, operation)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, scheduledEpoch, operation)
            else -> manager.set(AlarmManager.RTC_WAKEUP, scheduledEpoch, operation)
        }
        AlarmDeliveryStore.put(
            context,
            AlarmDeliveryStore.Pending(id, itemId, scheduledEpoch, exact),
        )
        "ok"
    } catch (_: SecurityException) {
        "exact_alarm_denied"
    } catch (error: Throwable) {
        "error: ${error.javaClass.simpleName}"
    }

    fun cancel(context: Context, id: Int) {
        try {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            pending(context, id, "", 0L, PendingIntent.FLAG_NO_CREATE)?.let { operation ->
                manager.cancel(operation)
                operation.cancel()
            }
        } catch (_: Throwable) {
        } finally {
            AlarmDeliveryStore.remove(context, id)
            // If it already fired, the PendingIntent is gone but its service may
            // still be ringing. A future alarm with another id is unaffected.
            AlarmSoundService.stopForNotification(context, id)
        }
    }

    fun cancelAll(context: Context) {
        AlarmDeliveryStore.load(context).forEach { cancel(context, it.id) }
        AlarmDeliveryStore.clear(context)
        // This owns alarms that have not fired yet. A delivery removes itself
        // from the store before starting playback, so bulk schedule cleanup
        // must not silence an alarm that is already ringing. The alarm UI's
        // explicit stop-for-item action owns that lifecycle.
    }

    fun readExtras(intent: Intent): Triple<Int, String, Long> = Triple(
        intent.getIntExtra(EXTRA_ID, -1),
        intent.getStringExtra(EXTRA_ITEM) ?: "",
        intent.getLongExtra(EXTRA_SCHEDULED, 0L),
    )
}
