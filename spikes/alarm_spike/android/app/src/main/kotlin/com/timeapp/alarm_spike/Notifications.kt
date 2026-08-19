package com.timeapp.alarm_spike

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

/**
 * The visible half of a fire. The CSV row is the measurement; this is so the
 * tester can SEE that something happened without unlocking and opening the app
 * (and so an overnight run leaves a timestamped trace in the notification
 * shade as a cross-check on the log).
 */
object Notifications {

    const val CHANNEL_ID = "alarm_spike_fire"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Alarm spike fires",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "One notification per test alarm that actually fired."
            enableVibration(true)
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }
        nm.createNotificationChannel(channel)
    }

    fun show(context: Context, variant: String, delaySeconds: Double) {
        try {
            ensureChannel(context)
            val open = PendingIntent.getActivity(
                context, 9000,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val delayText = String.format("%+.1fs", delaySeconds)
            val n = android.app.Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("FIRED · $variant")
                .setContentText("delay $delayText · ${SpikeLog.localTime(System.currentTimeMillis())}")
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(variant.hashCode(), n)
        } catch (t: Throwable) {
            // Never let the notification path break the measurement.
        }
    }
}
