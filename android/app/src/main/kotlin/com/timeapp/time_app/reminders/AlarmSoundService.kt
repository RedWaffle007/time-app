package com.timeapp.time_app.reminders

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.timeapp.time_app.MainActivity
import com.timeapp.time_app.R

/**
 * Owns the alarm SOUND so it is independent of the screen.
 *
 * The reminder's notification carries a one-shot fallback tone. Repetition is
 * deliberately owned here instead of by FLAG_INSISTENT: some Android variants
 * restart notification audio on a short cadence without waiting for the source
 * to finish. A foreground service holding a PARTIAL_WAKE_LOCK and playing a
 * looping [MediaPlayer] on USAGE_ALARM finishes the selected tone before each
 * replay and keeps ringing with the screen off until the user dismisses.
 *
 * Lifecycle is driven from Dart over `time_app/alarm_sound` (start on mount, stop
 * on dismiss), with a one-minute cap so a missed dismiss cannot ring — or hold
 * the wake lock — indefinitely.
 */
class AlarmSoundService : Service() {

    companion object {
        const val ACTION_START = "com.timeapp.time_app.ALARM_START"
        const val ACTION_STOP = "com.timeapp.time_app.ALARM_STOP"
        private const val ACTION_STOP_NOTIFICATION =
            "com.timeapp.time_app.ALARM_STOP_NOTIFICATION"
        private const val ACTION_STOP_ITEM = "com.timeapp.time_app.ALARM_STOP_ITEM"
        private const val ACTION_VOLUME_SILENCE =
            "com.timeapp.time_app.ALARM_VOLUME_SILENCE"
        private const val EXTRA_NOTIFICATION_ID = "notification_id"
        private const val EXTRA_ITEM_ID = "item_id"

        private const val CHANNEL_ID = "time_app_alarm_ringing"
        // Fixed id: there is only ever one alarm ringing, and re-posting under the
        // same id updates the one notification rather than stacking them.
        private const val NOTIF_ID = 0x7A1A
        private const val WAKE_TAG = "time_app:alarm_sound"
        private const val TAG = "AlarmSound"
        @Volatile private var ringing = false

        fun start(context: Context, notificationId: Int, itemId: String) {
            val intent = Intent(context, AlarmSoundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                .putExtra(EXTRA_ITEM_ID, itemId)
            ContextCompat.startForegroundService(context, intent)
        }

        /** UI fallback when native delivery did not run first. */
        fun startForItem(context: Context, itemId: String) = start(context, -1, itemId)

        fun stopForItem(context: Context, itemId: String) {
            // Not startForeground: a stop must never (re)promote the service.
            val intent = Intent(context, AlarmSoundService::class.java)
                .setAction(ACTION_STOP_ITEM)
                .putExtra(EXTRA_ITEM_ID, itemId)
            context.startService(intent)
        }

        fun stopForNotification(context: Context, notificationId: Int) {
            val intent = Intent(context, AlarmSoundService::class.java)
                .setAction(ACTION_STOP_NOTIFICATION)
                .putExtra(EXTRA_NOTIFICATION_ID, notificationId)
            try {
                context.startService(intent)
            } catch (_: Throwable) {
                // If no service exists Android may reject a background start;
                // there is then no playback to stop.
            }
        }

        fun stopAll(context: Context) {
            val intent = Intent(context, AlarmSoundService::class.java).setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (_: Throwable) {
            }
        }

        /** True only while this process owns active alarm playback. */
        fun isRinging(): Boolean = ringing

        /** Called only from the foreground Activity's hardware-key dispatch. */
        fun silenceFromVolumeDown(context: Context) {
            if (!ringing) return
            context.startService(
                Intent(context, AlarmSoundService::class.java)
                    .setAction(ACTION_VOLUME_SILENCE),
            )
        }
    }

    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val ownership = AlarmPlaybackOwnership()
    private val handler = Handler(Looper.getMainLooper())
    private val autoStop = Runnable {
        val at = System.currentTimeMillis()
        cancelOwningNotifications()
        ownership.itemIds().forEach { itemId ->
            AlarmLifecycleStore.record(this, itemId, AlarmLifecycleStore.KIND_TIMEOUT, at)
            ReminderAuditLog.write(
                this,
                event = "AUDIO_TIMEOUT",
                itemId = itemId,
                atEpoch = at,
                note = "one_minute_cap",
            )
        }
        AlarmLifecycleChannel.notifyChanged()
        Log.i(TAG, "one-minute ring cap reached — stopping")
        stopAlarm()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "stop all")
                stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_STOP_NOTIFICATION -> {
                val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)
                Log.i(TAG, "release notification owner $notificationId")
                ownership.releaseNotification(notificationId)
                if (!ownership.hasOwners) stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_STOP_ITEM -> {
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID) ?: ""
                Log.i(TAG, "stop item $itemId")
                ownership.releaseItem(itemId)
                if (!ownership.hasOwners) stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_VOLUME_SILENCE -> {
                val at = System.currentTimeMillis()
                cancelOwningNotifications()
                ownership.itemIds().forEach { itemId ->
                    AlarmLifecycleStore.record(
                        this,
                        itemId,
                        AlarmLifecycleStore.KIND_VOLUME_SILENCED,
                        at,
                    )
                    ReminderAuditLog.write(
                        this,
                        event = "VOLUME_SILENCED",
                        itemId = itemId,
                        atEpoch = at,
                        note = "foreground_activity",
                    )
                }
                AlarmLifecycleChannel.notifyChanged()
                stopAlarm()
                return START_NOT_STICKY
            }
            else -> {
                val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, -1) ?: -1
                val itemId = intent?.getStringExtra(EXTRA_ITEM_ID) ?: ""
                if (itemId.isNotEmpty()) {
                    if (notificationId >= 0) {
                        Log.i(TAG, "claim notification owner $notificationId")
                        ownership.claimNotification(notificationId, itemId)
                    } else {
                        // AlarmScreen owns playback independently from the fired
                        // notification. It immediately cancels that notification
                        // to prevent a second tone; retaining this UI owner keeps
                        // the service ringing until the user actually dismisses.
                        Log.i(TAG, "claim UI owner $itemId")
                        ownership.claimUi(itemId)
                    }
                }
                startAlarm()
            }
        }
        // NOT sticky: if the system kills us under memory pressure we do not want
        // a silent restart with no wake lock and no UI resurrecting the alarm.
        return START_NOT_STICKY
    }

    private fun startAlarm() {
        // Idempotent — the UI can call start more than once (mount + resume).
        if (!AlarmSoundPolicy.shouldStartPlayer(player != null)) return

        createChannel()
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            else 0
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(), type)

        // The whole point: keep the CPU (and therefore audio) alive with the
        // screen off. Bounded by MAX_MS so a leak is impossible even if stop is
        // never called.
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            acquire(AlarmSoundPolicy.MAX_RING_DURATION_MS + 5_000L)
        }

        try {
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(this@AlarmSoundService, alarmUri())
                isLooping = AlarmSoundPolicy.LOOP_WHOLE_TONE
                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "MediaPlayer error $what/$extra")
                    false
                }
                prepare()
                start()
            }
            ringing = true
            Log.i(TAG, "alarm ringing")
        } catch (e: Exception) {
            // If playback cannot start there is nothing to keep foreground for.
            Log.e(TAG, "failed to start alarm playback: $e")
            stopAlarm()
            return
        }

        handler.postDelayed(autoStop, AlarmSoundPolicy.MAX_RING_DURATION_MS)
    }

    /** A capped/silenced alarm must not remain tappable and restart playback. */
    private fun cancelOwningNotifications() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ownership.notificationIds().forEach(manager::cancel)
    }

    private fun stopAlarm() {
        handler.removeCallbacks(autoStop)
        player?.let {
            try {
                if (it.isPlaying) it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
        ringing = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ownership.clear()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        // Belt and braces — a destroyed service must not leave the wake lock held
        // or the tone playing.
        stopAlarm()
        super.onDestroy()
    }

    private fun alarmUri(): Uri =
        RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: Settings.System.DEFAULT_ALARM_ALERT_URI

    /**
     * A SILENT channel — the service plays the sound, the notification must not
     * add a second one. IMPORTANCE_LOW keeps it out of the way while still
     * carrying the full-screen intent that can relaunch the alarm UI.
     */
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Alarm ringing",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while a reminder alarm is sounding."
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification() =
        NotificationCompat.Builder(this, CHANNEL_ID)
            // Android small icons are monochrome silhouettes. The launcher icon
            // becomes a solid blob here; this resource is the Checkmate mark
            // specifically drawn for the notification tray.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Reminder")
            .setContentText("Alarm ringing — tap to open")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(launchAlarmUi())
            .build()

    /**
     * Uses flutter_local_notifications' own tap contract so tapping either the
     * scheduled reminder or this foreground-service notification reaches the
     * same AlarmScreen. This matters when an OEM hides one of the two entries.
     */
    private fun launchAlarmUi(): PendingIntent {
        val alarm = ownership.latestNotification()
        val itemId = alarm?.second ?: ownership.latestUiItem().orEmpty()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "SELECT_NOTIFICATION"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("notificationId", alarm?.first ?: NOTIF_ID)
            putExtra("payload", itemId)
        }
        return PendingIntent.getActivity(
            this,
            NOTIF_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
