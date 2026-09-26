package com.timeapp.time_app.reminders

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.timeapp.time_app.MainActivity

/** Arms the OS alarm whose receiver starts audio without launching Flutter. */
object AlarmDeliveryScheduler {
    private const val EXTRA_ID = "delivery_id"
    private const val EXTRA_ITEM = "delivery_item_id"
    private const val EXTRA_SCHEDULED = "delivery_scheduled_epoch"
    private const val EXTRA_HEADLINE = "delivery_headline"

    private const val VOICE_PREFIX = "delivery_"

    private fun intent(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        headline: String,
        voice: VoiceAlarmSpec? = null,
    ) =
        Intent(context, AlarmDeliveryReceiver::class.java).apply {
            action = AlarmDeliveryIdentity.action(id)
            putExtra(EXTRA_ID, id)
            putExtra(EXTRA_ITEM, itemId)
            putExtra(EXTRA_SCHEDULED, scheduledEpoch)
            putExtra(EXTRA_HEADLINE, headline)
            // The voice note travels with the alarm like the headline (32c-2).
            voice?.putInto(this, VOICE_PREFIX)
        }

    private fun pending(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        flags: Int,
        headline: String = "",
        voice: VoiceAlarmSpec? = null,
    ): PendingIntent? = PendingIntent.getBroadcast(
        context,
        AlarmDeliveryIdentity.requestCode(id),
        intent(context, id, itemId, scheduledEpoch, headline, voice),
        flags or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun showPending(context: Context, id: Int, itemId: String): PendingIntent =
        PendingIntent.getActivity(
            context,
            AlarmDeliveryIdentity.requestCode(id),
            Intent(context, MainActivity::class.java).apply {
                action = "SELECT_NOTIFICATION"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("notificationId", id)
                putExtra("payload", itemId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Returns a short result for Dart diagnostics and never throws. */
    fun arm(
        context: Context,
        id: Int,
        itemId: String,
        scheduledEpoch: Long,
        exact: Boolean,
        headline: String = "",
        voice: VoiceAlarmSpec? = null,
    ): String = try {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // FLAG_UPDATE_CURRENT replaces the extras, so a changed headline (e.g.
        // the planner's name resolving) reaches the already-armed alarm.
        val operation = pending(
            context,
            id,
            itemId,
            scheduledEpoch,
            PendingIntent.FLAG_UPDATE_CURRENT,
            headline,
            voice,
        ) ?: return "no_pending_intent"

        when (alarmDeliveryMode(exact, Build.VERSION.SDK_INT)) {
            AlarmDeliveryMode.ALARM_CLOCK ->
                manager.setAlarmClock(
                    AlarmManager.AlarmClockInfo(
                        scheduledEpoch,
                        showPending(context, id, itemId),
                    ),
                    operation,
                )
            AlarmDeliveryMode.INEXACT_ALLOW_IDLE ->
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, scheduledEpoch, operation)
            AlarmDeliveryMode.INEXACT ->
                manager.set(AlarmManager.RTC_WAKEUP, scheduledEpoch, operation)
        }
        AlarmDeliveryStore.put(
            context,
            AlarmDeliveryStore.Pending(id, itemId, scheduledEpoch, exact, headline, voice),
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

    fun readHeadline(intent: Intent): String =
        intent.getStringExtra(EXTRA_HEADLINE) ?: ""

    fun readVoice(intent: Intent): VoiceAlarmSpec? =
        VoiceAlarmSpec.from(intent, VOICE_PREFIX)
}
