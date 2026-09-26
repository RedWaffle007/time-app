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
 * Scheduled notifications are deliberately silent. Repetition is owned only
 * here instead of by notification audio or FLAG_INSISTENT: some Android
 * variants restart notification sound on a short cadence without waiting for
 * the source to finish. A foreground service holding a PARTIAL_WAKE_LOCK and
 * playing a looping [MediaPlayer] on USAGE_ALARM finishes the selected tone
 * before each replay and keeps ringing with the screen off until dismissal.
 *
 * Lifecycle is driven from Dart over `time_app/alarm_sound` (start on mount, stop
 * on dismiss), with a one-minute cap so a missed dismiss cannot ring — or hold
 * the wake lock — indefinitely.
 */
class AlarmSoundService : Service() {

    companion object {
        const val ACTION_START = "com.timeapp.time_app.ALARM_START"
        const val ACTION_STOP = "com.timeapp.time_app.ALARM_STOP"
        const val ACTION_RINGING_ENDED = "com.timeapp.time_app.ALARM_RINGING_ENDED"
        private const val ACTION_STOP_NOTIFICATION =
            "com.timeapp.time_app.ALARM_STOP_NOTIFICATION"
        private const val ACTION_STOP_ITEM = "com.timeapp.time_app.ALARM_STOP_ITEM"
        private const val ACTION_VOLUME_SILENCE =
            "com.timeapp.time_app.ALARM_VOLUME_SILENCE"
        private const val ACTION_NOTIFICATION_DISMISS =
            "com.timeapp.time_app.ALARM_NOTIFICATION_DISMISS"
        private const val EXTRA_NOTIFICATION_ID = "notification_id"
        private const val EXTRA_ITEM_ID = "item_id"
        private const val EXTRA_HEADLINE = "headline"
        private const val MISSED_CHANNEL_ID = "time_app_missed_alarms"

        private const val CHANNEL_ID = "time_app_alarm_ringing_v2"
        private const val LEGACY_CHANNEL_ID = "time_app_alarm_ringing"
        // Fixed id: there is only ever one alarm ringing, and re-posting under the
        // same id updates the one notification rather than stacking them.
        private const val NOTIF_ID = 0x7A1A
        private const val WAKE_TAG = "time_app:alarm_sound"
        private const val TAG = "AlarmSound"
        @Volatile private var ringing = false

        /**
         * itemId → "{planner} planned {task} for you". Delivered with the alarm itself,
         * so the heads-up, the lock-screen AlarmScreen and the missed notice all
         * name who and what from the first frame — no item/profile read needed.
         */
        private val headlines = java.util.concurrent.ConcurrentHashMap<String, String>()

        fun headlineFor(itemId: String): String? = headlines[itemId]

        fun start(
            context: Context,
            notificationId: Int,
            itemId: String,
            headline: String = "",
        ): Boolean {
            if (itemId.isNotEmpty() && headline.isNotBlank()) {
                headlines[itemId] = headline
            }
            val intent = Intent(context, AlarmSoundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                .putExtra(EXTRA_ITEM_ID, itemId)
                .putExtra(EXTRA_HEADLINE, headline)
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (error: Throwable) {
                Log.e(TAG, "failed to request alarm service start", error)
                false
            }
        }

        /** UI fallback when native delivery did not run first. */
        fun startForItem(context: Context, itemId: String, headline: String = "") =
            start(context, -1, itemId, headline)

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
        fun silenceFromVolumeDown(context: Context): Boolean {
            if (!ringing) return false
            return try {
                context.startService(
                    Intent(context, AlarmSoundService::class.java)
                        .setAction(ACTION_VOLUME_SILENCE),
                )
                true
            } catch (error: Throwable) {
                Log.e(TAG, "failed to request Volume Down silence", error)
                false
            }
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
            // The alarm gave up on its own: tell the person, even if the app is
            // dead. Tapping opens the app, whose missed-alarm review offers
            // Done / Skip for exactly this task.
            postMissedNotification(itemId)
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
                recordDismissal("VOLUME_SILENCED", "foreground_activity")
                stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_NOTIFICATION_DISMISS -> {
                recordDismissal("NOTIFICATION_DISMISSED", "notification_action")
                stopAlarm()
                return START_NOT_STICKY
            }
            else -> {
                val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, -1) ?: -1
                val itemId = intent?.getStringExtra(EXTRA_ITEM_ID) ?: ""
                val headline = intent?.getStringExtra(EXTRA_HEADLINE).orEmpty()
                if (itemId.isNotEmpty() && headline.isNotBlank()) {
                    headlines[itemId] = headline
                }
                if (itemId.isNotEmpty()) {
                    if (notificationId >= 0) {
                        Log.i(TAG, "claim notification owner $notificationId")
                        ownership.claimNotification(notificationId, itemId)
                        suppressScheduledDuplicate(notificationId)
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
        if (!AlarmSoundPolicy.shouldStartPlayer(player != null)) {
            return
        }

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

        // The ringtone starts at once. The ting belongs to app start only
        // (user-directed 2026-09-26) and stays suppressed while this rings.
        ringing = true
        startRingtoneNow()
        handler.postDelayed(autoStop, AlarmSoundPolicy.MAX_RING_DURATION_MS)
    }

    private fun alarmAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    private fun startRingtoneNow() {
        if (player != null) return
        try {
            player = MediaPlayer().apply {
                setAudioAttributes(alarmAttributes())
                setDataSource(this@AlarmSoundService, alarmUri())
                isLooping = AlarmSoundPolicy.LOOP_WHOLE_TONE
                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "MediaPlayer error $what/$extra")
                    false
                }
                prepare()
                start()
            }
            Log.i(TAG, "alarm ringing")
        } catch (e: Exception) {
            // If playback cannot start there is nothing to keep foreground for.
            Log.e(TAG, "failed to start alarm playback: $e")
            stopAlarm()
        }
    }

    /** One per item, replacing itself; auto-cancelled when tapped. */
    private fun postMissedNotification(itemId: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm.getNotificationChannel(MISSED_CHANNEL_ID) == null
            ) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        MISSED_CHANNEL_ID,
                        "Missed alarms",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = "When an alarm stopped without a response."
                    },
                )
            }
            val launch = packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val open = launch?.let {
                PendingIntent.getActivity(
                    this,
                    ("missed:$itemId").hashCode(),
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            val text = AlarmSoundPolicy.missedText(headlines[itemId])
            val notification = NotificationCompat.Builder(this, MISSED_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(AlarmSoundPolicy.MISSED_TITLE)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .apply { if (open != null) setContentIntent(open) }
                .build()
            nm.notify(("missed:$itemId").hashCode(), notification)
        } catch (e: Exception) {
            Log.e(TAG, "failed to post missed-alarm notification: $e")
        }
    }

    /**
     * ONE notification per alarm (device report 2026-09-25). The scheduled
     * reminder notification shares [notificationId] and fires from a separate
     * OS alarm at the same instant; once this service rings, its own
     * notification says everything, so the scheduled one is removed — now and
     * again shortly after, because the two alarms can land in either order.
     * Cancelled on the NotificationManager directly: going through Dart's
     * cancel path would release the notification owner and stop the ring.
     * If native delivery never runs, nothing cancels it and it stays as the
     * fallback.
     */
    private fun suppressScheduledDuplicate(notificationId: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notificationId)
        AlarmSoundPolicy.DUPLICATE_RECHECK_MS.forEach { delay ->
            handler.postDelayed({
                if (ringing && notificationId in ownership.notificationIds()) {
                    nm.cancel(notificationId)
                }
            }, delay)
        }
    }

    /** A capped/silenced alarm must not remain tappable and restart playback. */
    private fun cancelOwningNotifications() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ownership.notificationIds().forEach(manager::cancel)
    }

    private fun recordDismissal(event: String, note: String) {
        val at = System.currentTimeMillis()
        cancelOwningNotifications()
        ownership.itemIds().forEach { itemId ->
            AlarmLifecycleStore.record(
                this,
                itemId,
                AlarmLifecycleStore.KIND_DISMISSED,
                at,
            )
            ReminderAuditLog.write(
                this,
                event = event,
                itemId = itemId,
                atEpoch = at,
                note = note,
            )
        }
        AlarmLifecycleChannel.notifyChanged()
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
        sendBroadcast(Intent(ACTION_RINGING_ENDED).setPackage(packageName))
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
     * A SILENT, HIGH channel — the service plays the sound, so the notification
     * must not add a second one. High importance lets its full-screen intent or
     * heads-up Dismiss fallback remain visible when the scheduled notification
     * path is suppressed.
     */
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.deleteNotificationChannel(LEGACY_CHANNEL_ID)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Alarm ringing",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Shown while a reminder alarm is sounding."
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun currentItemId(): String =
        ownership.latestNotification()?.second ?: ownership.latestUiItem().orEmpty()

    // With the phone unlocked Android shows this as a heads-up instead of the
    // full-screen alarm, so the heads-up itself must say who planned what.
    private fun buildNotification() =
        NotificationCompat.Builder(this, CHANNEL_ID)
            // Android small icons are monochrome silhouettes. The launcher icon
            // becomes a solid blob here; this resource is the Checkmate mark
            // specifically drawn for the notification tray.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(AlarmSoundPolicy.ringingTitle(headlines[currentItemId()]))
            .setContentText(AlarmSoundPolicy.RINGING_TEXT)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(launchAlarmUi())
            .setFullScreenIntent(launchAlarmUi(), true)
            .addAction(
                R.drawable.ic_notification,
                "Dismiss",
                dismissFromNotification(),
            )
            .build()

    private fun dismissFromNotification(): PendingIntent =
        PendingIntent.getService(
            this,
            NOTIF_ID,
            Intent(this, AlarmSoundService::class.java)
                .setAction(ACTION_NOTIFICATION_DISMISS),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

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
