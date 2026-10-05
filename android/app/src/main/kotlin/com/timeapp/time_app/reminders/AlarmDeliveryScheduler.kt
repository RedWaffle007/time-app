package com.timeapp.time_app.reminders

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.timeapp.time_app.MainActivity

/**
 * Arms the OS alarms whose receiver starts audio without launching Flutter:
 * one per plan, at its time (ring 1), plus ONE queue wake-up for whatever
 * the ring queue needs next — a repeat (2026-10-05). Repeats are never armed
 * one by one: their times move as new plans arrive.
 */
object AlarmDeliveryScheduler {
    private const val EXTRA_ID = "delivery_id"
    private const val EXTRA_ITEM = "delivery_item_id"
    private const val EXTRA_SCHEDULED = "delivery_scheduled_epoch"

    /** The queue's own wake-up: one PendingIntent, re-armed in place. */
    const val ACTION_QUEUE_WAKE = "com.timeapp.time_app.ALARM_QUEUE_WAKE"
    private const val QUEUE_WAKE_REQUEST = 0x51E7

    private fun intent(context: Context, id: Int, itemId: String, scheduledEpoch: Long) =
        Intent(context, AlarmDeliveryReceiver::class.java).apply {
            action = AlarmDeliveryIdentity.action(id)
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
        AlarmDeliveryIdentity.requestCode(id),
        intent(context, id, itemId, scheduledEpoch),
        flags or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun showPending(context: Context, requestCode: Int, itemId: String): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode,
            Intent(context, MainActivity::class.java).apply {
                action = "SELECT_NOTIFICATION"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("payload", itemId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun setAt(
        context: Context,
        exact: Boolean,
        triggerEpoch: Long,
        operation: PendingIntent,
        show: PendingIntent,
    ) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        when (alarmDeliveryMode(exact, Build.VERSION.SDK_INT)) {
            AlarmDeliveryMode.ALARM_CLOCK ->
                manager.setAlarmClock(AlarmManager.AlarmClockInfo(triggerEpoch, show), operation)
            AlarmDeliveryMode.INEXACT_ALLOW_IDLE ->
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerEpoch, operation)
            AlarmDeliveryMode.INEXACT ->
                manager.set(AlarmManager.RTC_WAKEUP, triggerEpoch, operation)
        }
    }

    /**
     * Arms a plan's first ring and records it in the queue. Returns a short
     * result for Dart diagnostics and never throws.
     */
    fun arm(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        exact: Boolean,
        headline: String = "",
        voice: VoiceAlarmSpec? = null,
        voiceMs: Long = 0L,
    ): String = try {
        // FLAG_UPDATE_CURRENT replaces the extras in place.
        val operation = pending(context, id, itemId, scheduledEpoch, PendingIntent.FLAG_UPDATE_CURRENT)
            ?: return "no_pending_intent"
        setAt(
            context,
            exact,
            scheduledEpoch,
            operation,
            showPending(context, AlarmDeliveryIdentity.requestCode(id), itemId),
        )
        AlarmDeliveryStore.put(
            context,
            AlarmDeliveryStore.Pending(id, itemId, scheduledEpoch, exact, headline, voice, voiceMs),
        )
        "ok"
    } catch (_: SecurityException) {
        "exact_alarm_denied"
    } catch (error: Throwable) {
        "error: ${error.javaClass.simpleName}"
    }

    /** The queue's next look, at [atEpoch]; replaces any earlier one. */
    fun armQueueWake(context: Context, atEpoch: Long, itemId: String): Boolean = try {
        val operation = PendingIntent.getBroadcast(
            context,
            QUEUE_WAKE_REQUEST,
            Intent(context, AlarmDeliveryReceiver::class.java).setAction(ACTION_QUEUE_WAKE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        setAt(context, true, atEpoch, operation, showPending(context, QUEUE_WAKE_REQUEST, itemId))
        true
    } catch (_: SecurityException) {
        false
    } catch (_: Throwable) {
        false
    }

    fun cancelQueueWake(context: Context) {
        try {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            PendingIntent.getBroadcast(
                context,
                QUEUE_WAKE_REQUEST,
                Intent(context, AlarmDeliveryReceiver::class.java).setAction(ACTION_QUEUE_WAKE),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
            )?.let { operation ->
                manager.cancel(operation)
                operation.cancel()
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * The plan is no longer wanted (answered, dismissed, withdrawn): its OS
     * alarm goes, it leaves the queue, and if it is ringing it stops — the
     * rest of the queue carries on.
     */
    fun cancel(context: Context, id: Int) {
        val itemId = AlarmDeliveryStore.load(context).firstOrNull { it.id == id }?.itemId
        try {
            val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            pending(context, id, "", 0L, PendingIntent.FLAG_NO_CREATE)?.let { operation ->
                manager.cancel(operation)
                operation.cancel()
            }
        } catch (_: Throwable) {
        } finally {
            AlarmDeliveryStore.remove(context, id)
            AlarmSoundService.cancelWaitingNotice(context, id)
            if (itemId != null) AlarmSoundService.leaveQueue(context, itemId)
        }
    }

    fun cancelAll(context: Context) {
        AlarmDeliveryStore.load(context).forEach { cancel(context, it.id) }
        AlarmDeliveryStore.clear(context)
        cancelQueueWake(context)
    }

    fun readExtras(intent: Intent): Triple<Int, String, Long> = Triple(
        intent.getIntExtra(EXTRA_ID, -1),
        intent.getStringExtra(EXTRA_ITEM) ?: "",
        intent.getLongExtra(EXTRA_SCHEDULED, 0L),
    )
}
