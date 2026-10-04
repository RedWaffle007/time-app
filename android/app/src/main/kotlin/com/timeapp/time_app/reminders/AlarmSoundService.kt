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
 * on dismiss). Each ring is capped at 5 minutes so a missed dismiss cannot ring
 * — or hold the wake lock — indefinitely. Between rings (2026-10-04) nothing
 * runs at all: the next ring is an exact OS alarm, and a quiet notice with
 * Dismiss stands in for it ([enterQuiet]).
 */
class AlarmSoundService : Service() {

    companion object {
        const val ACTION_START = "com.timeapp.time_app.ALARM_START"
        const val ACTION_STOP = "com.timeapp.time_app.ALARM_STOP"
        const val ACTION_RINGING_ENDED = "com.timeapp.time_app.ALARM_RINGING_ENDED"

        /**
         * R5 (2026-10-02): an alarm started ringing ([EXTRA_RINGING_ITEM]
         * says which). The open app shows its own alarm screen on this, so the
         * details never depend on an OEM letting the heads-up through.
         */
        const val ACTION_RINGING_STARTED = "com.timeapp.time_app.ALARM_RINGING_STARTED"
        const val EXTRA_RINGING_ITEM = "itemId"
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
        private const val EXTRA_SCHEDULED = "scheduled_epoch"
        private const val EXTRA_RING_INDEX = "ring_index"
        private const val EXTRA_RING_ENDS = "ring_ends_epoch"
        private const val MISSED_CHANNEL_ID = "time_app_missed_alarms"
        private const val QUIET_CHANNEL_ID = "time_app_alarm_quiet"

        private const val CHANNEL_ID = "time_app_alarm_ringing_v2"
        private const val LEGACY_CHANNEL_ID = "time_app_alarm_ringing"
        // Fixed id: there is only ever one alarm ringing, and re-posting under the
        // same id updates the one notification rather than stacking them.
        private const val NOTIF_ID = 0x7A1A
        private const val WAKE_TAG = "time_app:alarm_sound"
        private const val TAG = "AlarmSound"
        @Volatile private var ringing = false

        /** The plan ringing now, for an app opened mid-ring (R5). */
        @Volatile private var ringingItem: String? = null

        /**
         * itemId → "{planner} planned {task} for you". Delivered with the alarm itself,
         * so the heads-up, the lock-screen AlarmScreen and the missed notice all
         * name who and what from the first frame — no item/profile read needed.
         */
        private val headlines = java.util.concurrent.ConcurrentHashMap<String, String>()

        fun headlineFor(itemId: String): String? = headlines[itemId]

        /** Where a ringing item is in its cycle (2026-10-04), so the end of
         *  this ring knows whether another follows. */
        private data class Cycle(
            val notificationId: Int,
            val scheduledEpoch: Long,
            val ringIndex: Int,
            val voice: VoiceAlarmSpec?,
        )

        private val cycles = java.util.concurrent.ConcurrentHashMap<String, Cycle>()

        fun start(
            context: Context,
            notificationId: Int,
            itemId: String,
            headline: String = "",
            voice: VoiceAlarmSpec? = null,
            scheduledEpoch: Long = 0L,
            ringIndex: Int = 0,
            ringEndsEpoch: Long = 0L,
        ): Boolean {
            if (itemId.isNotEmpty() && headline.isNotBlank()) {
                headlines[itemId] = headline
            }
            val intent = Intent(context, AlarmSoundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_NOTIFICATION_ID, notificationId)
                .putExtra(EXTRA_ITEM_ID, itemId)
                .putExtra(EXTRA_HEADLINE, headline)
                .putExtra(EXTRA_SCHEDULED, scheduledEpoch)
                .putExtra(EXTRA_RING_INDEX, ringIndex)
                .putExtra(EXTRA_RING_ENDS, ringEndsEpoch)
            voice?.putInto(intent, "")
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

        /** The item ringing now, or null (R5). */
        fun ringingItemId(): String? = if (ringing) ringingItem else null

        /** Every alarm in a ring now, oldest first (2026-10-04). */
        @Volatile private var ringingItems: List<String> = emptyList()

        fun ringingItemIds(): List<String> = if (ringing) ringingItems else emptyList()

        /**
         * An alarm delivered after its whole ring cycle ran out
         * ([RingCyclePolicy]) ends exactly as an unanswered ring does, but
         * without a sound: the missed notice, the timeout row (the app's
         * missed popup) and the planner's "unavailable" push.
         */
        fun missWithoutRinging(
            context: Context,
            itemId: String,
            headline: String,
            atEpochMs: Long,
            scheduledEpoch: Long? = null,
        ) {
            if (itemId.isEmpty()) return
            if (headline.isNotBlank()) headlines[itemId] = headline
            postMissedNotice(context, itemId)
            AlarmLifecycleStore.record(
                context,
                itemId,
                AlarmLifecycleStore.KIND_TIMEOUT,
                atEpochMs,
            )
            ReminderAuditLog.write(
                context,
                event = "AUDIO_LATE_MISSED",
                itemId = itemId,
                scheduledEpoch = scheduledEpoch,
                atEpoch = atEpochMs,
                note = "too_late_to_ring",
            )
            MissedAlarmReporter.report(context, listOf(itemId), atEpochMs)
            AlarmLifecycleChannel.notifyChanged()
        }

        /**
         * Between rings (2026-10-04): arm ring [nextIndex] at [nextAt] and show
         * "Rings again at …" with Dismiss. Nothing runs meanwhile, so the
         * phone sleeps. False if the next ring could not be armed — the
         * caller then ends the alarm as missed rather than lose it silently.
         */
        fun enterQuiet(
            context: Context,
            notificationId: Int,
            itemId: String,
            scheduledEpoch: Long,
            nextIndex: Int,
            nextAt: Long,
            headline: String,
            voice: VoiceAlarmSpec?,
        ): Boolean {
            if (itemId.isEmpty() || notificationId < 0) return false
            if (headline.isNotBlank()) headlines[itemId] = headline
            val armed = AlarmDeliveryScheduler.arm(
                context,
                notificationId,
                itemId,
                scheduledEpoch,
                exact = true,
                headline = headline.ifBlank { headlines[itemId].orEmpty() },
                voice = voice,
                triggerEpoch = nextAt,
            )
            ReminderAuditLog.write(
                context,
                event = "RING_QUIET",
                itemId = itemId,
                notificationId = notificationId,
                scheduledEpoch = scheduledEpoch,
                note = "next ring $nextIndex at $nextAt: $armed",
            )
            if (armed != "ok") return false
            postQuietNotice(context, notificationId, itemId, nextAt)
            return true
        }

        private fun quietNoticeId(notificationId: Int): Int =
            ("quiet:$notificationId").hashCode()

        fun cancelQuietNotice(context: Context, notificationId: Int) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                nm.cancel(quietNoticeId(notificationId))
            } catch (_: Throwable) {
            }
        }

        private fun postQuietNotice(
            context: Context,
            notificationId: Int,
            itemId: String,
            nextAt: Long,
        ) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    nm.getNotificationChannel(QUIET_CHANNEL_ID) == null
                ) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            QUIET_CHANNEL_ID,
                            "Alarm between rings",
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            description = "An alarm that will ring again soon."
                            setSound(null, null)
                            enableVibration(false)
                            setShowBadge(false)
                        },
                    )
                }
                // The phone's own clock format (12/24 h, locale digits).
                val time = android.text.format.DateFormat.getTimeFormat(context)
                    .format(java.util.Date(nextAt))
                val open = PendingIntent.getActivity(
                    context,
                    quietNoticeId(notificationId),
                    Intent(context, MainActivity::class.java).apply {
                        action = "SELECT_NOTIFICATION"
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("notificationId", notificationId)
                        putExtra("payload", itemId)
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val dismiss = PendingIntent.getBroadcast(
                    context,
                    quietNoticeId(notificationId),
                    Intent(context, AlarmQuietDismissReceiver::class.java)
                        .putExtra(AlarmQuietDismissReceiver.EXTRA_ID, notificationId)
                        .putExtra(AlarmQuietDismissReceiver.EXTRA_ITEM, itemId),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val notification = NotificationCompat.Builder(context, QUIET_CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(AlarmSoundPolicy.ringingTitle(headlines[itemId]))
                    .setContentText(AlarmSoundPolicy.quietText(time))
                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    // Only Dismiss ends it; a swipe would hide the one way to.
                    .setOngoing(true)
                    .setContentIntent(open)
                    .addAction(R.drawable.ic_notification, "Dismiss", dismiss)
                    .build()
                nm.notify(quietNoticeId(notificationId), notification)
            } catch (e: Exception) {
                Log.e(TAG, "failed to post between-rings notification: $e")
            }
        }

        /** One per item, replacing itself; auto-cancelled when tapped. */
        private fun postMissedNotice(context: Context, itemId: String) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
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
                val launch = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)
                    ?.addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    )
                val open = launch?.let {
                    PendingIntent.getActivity(
                        context,
                        ("missed:$itemId").hashCode(),
                        it,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                }
                val text = AlarmSoundPolicy.missedText(headlines[itemId])
                val notification = NotificationCompat.Builder(context, MISSED_CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(AlarmSoundPolicy.missedTitle(headlines[itemId]))
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
    private var foreground = false
    private val ownership = AlarmPlaybackOwnership()
    private val handler = Handler(Looper.getMainLooper())

    /**
     * Every alarm in a ring right now, in the order they started (2026-10-04).
     * Each keeps its OWN end time; only the newest one makes a sound. When it
     * ends or is dismissed, the one before it takes the speaker back.
     */
    private val rings = AlarmRingSet()
    private val sounds = mutableMapOf<String, VoiceAlarmSpec?>()
    private val ringEnds = mutableMapOf<String, Runnable>()

    /** The alarm whose sound is playing now. */
    private var soundingItem: String? = null

    /** Voice-note plays completed in this ring (item 32c-2), for the audit. */
    private var voicePlays = 0

    /** Starts the next play of the voice note after [VoiceAlarmPolicy.REPLAY_GAP_MS]. */
    private val voiceReplay = Runnable {
        try {
            player?.let { it.seekTo(0); it.start() }
        } catch (e: IllegalStateException) {
            Log.e(TAG, "voice replay failed: $e")
        }
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
                val itemId = ownership.itemForNotification(notificationId)
                ownership.releaseNotification(notificationId)
                // That alarm ends only once nothing else (its screen) holds it.
                if (itemId != null && itemId !in ownership.itemIds()) dropItem(itemId)
                if (!ownership.hasOwners) stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_STOP_ITEM -> {
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID) ?: ""
                Log.i(TAG, "stop item $itemId")
                ownership.releaseItem(itemId)
                dropItem(itemId)
                if (!ownership.hasOwners) stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_VOLUME_SILENCE -> {
                // Volume Down silences EVERY alarm ringing now (2026-10-04).
                recordDismissal("VOLUME_SILENCED", "foreground_activity", rings.ids())
                stopAlarm()
                return START_NOT_STICKY
            }
            ACTION_NOTIFICATION_DISMISS -> {
                // The notification names the alarm that is sounding; Dismiss
                // answers that one. Any other alarm ringing takes over.
                val itemId = soundingItem
                if (itemId == null) {
                    stopAlarm()
                } else {
                    recordDismissal("NOTIFICATION_DISMISSED", "notification_action", listOf(itemId))
                    ownership.releaseItem(itemId)
                    dropItem(itemId)
                }
                return START_NOT_STICKY
            }
            else -> {
                val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, -1) ?: -1
                val itemId = intent?.getStringExtra(EXTRA_ITEM_ID) ?: ""
                val headline = intent?.getStringExtra(EXTRA_HEADLINE).orEmpty()
                val voice = VoiceAlarmSpec.from(intent, "")
                val scheduledEpoch = intent?.getLongExtra(EXTRA_SCHEDULED, 0L) ?: 0L
                val ringIndex = intent?.getIntExtra(EXTRA_RING_INDEX, 0) ?: 0
                val ringEndsAt = intent?.getLongExtra(EXTRA_RING_ENDS, 0L) ?: 0L
                if (itemId.isNotEmpty() && headline.isNotBlank()) {
                    headlines[itemId] = headline
                }
                if (itemId.isNotEmpty() && notificationId >= 0 && ringIndex > 0) {
                    cycles[itemId] = Cycle(notificationId, scheduledEpoch, ringIndex, voice)
                    cancelQuietNotice(this, notificationId)
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
                startRing(itemId, voice, ringEndsAt)
            }
        }
        // NOT sticky: if the system kills us under memory pressure we do not want
        // a silent restart with no wake lock and no UI resurrecting the alarm.
        return START_NOT_STICKY
    }

    /**
     * Adds [itemId] to the alarms ringing now and gives it the speaker. A
     * repeat start for an alarm already ringing (the screen mounting, a
     * resume) changes nothing.
     */
    private fun startRing(itemId: String, voice: VoiceAlarmSpec?, endsAt: Long) {
        ensureForeground()
        if (rings.contains(itemId)) return
        val now = System.currentTimeMillis()
        val ends = if (endsAt > 0) {
            endsAt.coerceIn(now + 1_000L, now + AlarmSoundPolicy.MAX_RING_DURATION_MS)
        } else {
            now + AlarmSoundPolicy.MAX_RING_DURATION_MS
        }
        rings.add(itemId, ends)
        sounds[itemId] = voice
        val end = Runnable { endRing(itemId) }
        ringEnds[itemId] = end
        handler.postDelayed(end, ends - now)

        // The sound starts at once. The ting belongs to app start only
        // (user-directed 2026-09-26) and stays suppressed while this rings.
        ringing = true
        publishRings()
        // R5: tell the open app which plan is ringing, so it shows the alarm.
        sendBroadcast(
            Intent(ACTION_RINGING_STARTED)
                .setPackage(packageName)
                .putExtra(EXTRA_RINGING_ITEM, itemId),
        )
        playFor(itemId)
    }

    /**
     * The foreground notification and the wake lock: the whole point is to
     * keep the CPU (and therefore audio) alive with the screen off. Each new
     * ring re-arms the lock's timeout, so a leak is impossible even if stop
     * is never called.
     */
    private fun ensureForeground() {
        if (!foreground) {
            createChannel()
            val type =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                else 0
            ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(), type)
            foreground = true
        }
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = wakeLock ?: pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
        }.also { wakeLock = it }
        lock.acquire(AlarmSoundPolicy.MAX_RING_DURATION_MS + 5_000L)
    }

    /** Gives the speaker to [itemId]: its voice note, else the ringtone. */
    private fun playFor(itemId: String) {
        releasePlayer()
        soundingItem = itemId
        publishRings()
        updateNotification()
        val voice = sounds[itemId]
        if (voice != null) {
            // A voice-note alarm repeats the note for the whole ring — but only
            // the exact file the plan was approved with. Anything else rings
            // the normal ringtone (never silence) and tells the planner, once.
            if (VoiceAlarmPolicy.verify(voice) && startVoiceNow(voice)) return
            recordVoiceFallback(itemId)
            sounds[itemId] = null
        }
        startRingtoneNow()
    }

    /** One alarm's ring ran its course: quiet until its next ring, or missed. */
    private fun endRing(itemId: String) {
        val at = System.currentTimeMillis()
        ringEnds.remove(itemId)
        cancelNotificationsOf(itemId)
        // 2026-10-04: a ring that is not the last goes quiet until the next
        // one. Only the last ring ending — or a next ring that could not be
        // armed — makes the alarm missed.
        val cycle = cycles[itemId]
        val quiet = cycle != null && cycle.ringIndex < RingCyclePolicy.RINGS && enterQuiet(
            this,
            cycle.notificationId,
            itemId,
            cycle.scheduledEpoch,
            cycle.ringIndex + 1,
            RingCyclePolicy.ringStart(cycle.scheduledEpoch, cycle.ringIndex + 1),
            headlines[itemId].orEmpty(),
            cycle.voice,
        )
        if (!quiet) {
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
                note = if (sounds[itemId] != null) "voice_cap x$voicePlays" else "ring_cap",
            )
            // Tell the planner now, not when the app is next opened (2026-09-27).
            MissedAlarmReporter.report(this, listOf(itemId), at)
        }
        AlarmLifecycleChannel.notifyChanged()
        Log.i(TAG, "ring ended for $itemId; ${if (quiet) "rings again" else "missed"}")
        ownership.releaseItem(itemId)
        dropItem(itemId)
    }

    /**
     * Takes [itemId] out of the ring. The last one out stops everything;
     * otherwise, if it had the speaker, the newest still ringing takes it.
     */
    private fun dropItem(itemId: String) {
        ringEnds.remove(itemId)?.let(handler::removeCallbacks)
        cycles.remove(itemId)
        sounds.remove(itemId)
        val wasSounding = soundingItem == itemId
        if (!rings.remove(itemId)) return
        if (rings.isEmpty) {
            stopAlarm()
            return
        }
        publishRings()
        if (wasSounding) rings.sounding()?.let(::playFor) else updateNotification()
    }

    /** What the app asks for: which alarms ring now, and which one sounds. */
    private fun publishRings() {
        ringingItem = soundingItem
        ringingItems = rings.ids()
    }

    private fun updateNotification() {
        if (!foreground) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
    }

    private fun releasePlayer() {
        handler.removeCallbacks(voiceReplay)
        player?.let {
            try {
                if (it.isPlaying) it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
    }

    /**
     * Plays [voice] on the alarm stream, again and again with a short pause
     * between plays, until its ring ends (2026-10-04).
     */
    private fun startVoiceNow(voice: VoiceAlarmSpec): Boolean = try {
        voicePlays = 0
        player = MediaPlayer().apply {
            setAudioAttributes(alarmAttributes())
            setDataSource(voice.path)
            isLooping = false
            setOnCompletionListener {
                voicePlays += 1
                handler.postDelayed(voiceReplay, VoiceAlarmPolicy.REPLAY_GAP_MS)
            }
            prepare()
        }
        val durationMs = player!!.duration.coerceAtLeast(1)
        player!!.start()
        ReminderAuditLog.write(this, event = "VOICE_PLAYING", note = "${durationMs}ms repeating")
        true
    } catch (e: Exception) {
        Log.e(TAG, "voice note failed, ringing instead: $e")
        releasePlayer()
        false
    }

    private fun recordVoiceFallback(itemId: String) {
        val at = System.currentTimeMillis()
        if (itemId.isNotEmpty()) {
            AlarmLifecycleStore.record(this, itemId, AlarmLifecycleStore.KIND_VOICE_FALLBACK, at)
        }
        ReminderAuditLog.write(
            this,
            event = "VOICE_FALLBACK",
            itemId = itemId,
            atEpoch = at,
            note = "ringtone",
        )
        AlarmLifecycleChannel.notifyChanged()
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
    private fun postMissedNotification(itemId: String) = postMissedNotice(this, itemId)

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

    /** An ended or silenced alarm must not remain tappable and restart playback. */
    private fun cancelNotificationsOf(itemId: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ownership.notificationIdsOf(itemId).forEach(manager::cancel)
    }

    private fun recordDismissal(event: String, note: String, itemIds: Collection<String>) {
        val at = System.currentTimeMillis()
        itemIds.forEach { itemId ->
            cancelNotificationsOf(itemId)
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
        ringEnds.values.forEach(handler::removeCallbacks)
        ringEnds.clear()
        releasePlayer()
        ringing = false
        rings.ids().forEach { cycles.remove(it) }
        ownership.itemIds().forEach { cycles.remove(it) }
        rings.clear()
        sounds.clear()
        soundingItem = null
        publishRings()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ownership.clear()
        foreground = false
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
        soundingItem ?: ownership.latestNotification()?.second ?: ownership.latestUiItem().orEmpty()

    // With the phone unlocked Android shows this as a heads-up instead of the
    // full-screen alarm, so the heads-up itself must say who planned what.
    private fun buildNotification() =
        NotificationCompat.Builder(this, CHANNEL_ID)
            // Android small icons are monochrome silhouettes. The launcher icon
            // becomes a solid blob here; this resource is the Mind Time mark
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
        val itemId = currentItemId()
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
