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
import com.timeapp.time_app.reminders.RingQueuePolicy.Segment
import com.timeapp.time_app.reminders.RingQueuePolicy.Sound

/**
 * Owns the alarm SOUND so it is independent of the screen, and runs the ring
 * queue (2026-10-05): DECISIONS.md "Ring queue: new alarms first, repeats
 * fill the gaps".
 *
 * Every live alarm sits in [AlarmDeliveryStore] with its counted rings. When
 * something is due, this foreground service — holding a PARTIAL_WAKE_LOCK so
 * the sound carries on with the screen off — asks [RingQueuePolicy] what to
 * play, plays that segment (one new alarm's ring, or a batch of repeats), and
 * asks again when it ends. A new alarm coming due mid-segment cuts in under
 * the policy's rules. When nothing is due the service stops; the next look is
 * an exact OS alarm ([AlarmDeliveryScheduler.armQueueWake]), so the phone
 * sleeps between rings.
 *
 * Scheduled notifications are deliberately silent: this service is the one
 * place alarm audio comes from.
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
        private const val ACTION_STOP_ITEM = "com.timeapp.time_app.ALARM_STOP_ITEM"
        private const val ACTION_LEAVE_ITEM = "com.timeapp.time_app.ALARM_LEAVE_ITEM"
        private const val ACTION_VOLUME_SILENCE =
            "com.timeapp.time_app.ALARM_VOLUME_SILENCE"
        private const val ACTION_NOTIFICATION_DISMISS =
            "com.timeapp.time_app.ALARM_NOTIFICATION_DISMISS"
        private const val EXTRA_ITEM_ID = "item_id"
        private const val MISSED_CHANNEL_ID = "time_app_missed_alarms"
        private const val WAITING_CHANNEL_ID = "time_app_alarm_quiet"

        private const val CHANNEL_ID = "time_app_alarm_ringing_v2"
        private const val LEGACY_CHANNEL_ID = "time_app_alarm_ringing"
        // Fixed id: one segment rings at a time, and re-posting under the same
        // id updates the one notification rather than stacking them.
        private const val NOTIF_ID = 0x7A1A
        private const val WAKE_TAG = "time_app:alarm_sound"
        private const val TAG = "AlarmSound"

        /** Extra wake-lock time past a segment's planned end. */
        private const val WAKE_SLACK_MS = 60_000L

        /** The fallback look after a segment, should the process die. */
        private const val SAFETY_WAKE_MS = 5_000L

        @Volatile private var ringing = false

        /** The service is alive and owns the queue right now. */
        @Volatile private var running = false

        /** The plan whose sound is playing now, for an app opened mid-ring (R5). */
        @Volatile private var ringingItem: String? = null

        /** Every alarm in the segment ringing now, in its order. */
        @Volatile private var ringingItems: List<String> = emptyList()

        /**
         * itemId → "{planner} planned {task} for you". Stored with the alarm,
         * so the heads-up, the lock-screen AlarmScreen and the missed notice
         * all name who and what from the first frame.
         */
        private val headlines = java.util.concurrent.ConcurrentHashMap<String, String>()

        fun headlineFor(context: Context, itemId: String): String? =
            headlines[itemId]
                ?: AlarmDeliveryStore.load(context).firstOrNull { it.itemId == itemId }
                    ?.headline?.takeIf { it.isNotBlank() }

        private fun remember(rows: List<AlarmDeliveryStore.Pending>) {
            rows.forEach { if (it.headline.isNotBlank()) headlines[it.itemId] = it.headline }
        }

        /** True only while this process owns active alarm playback. */
        fun isRinging(): Boolean = ringing

        /** The item sounding now, or null (R5). */
        fun ringingItemId(): String? = if (ringing) ringingItem else null

        /** Every alarm in the segment ringing now. */
        fun ringingItemIds(): List<String> = if (ringing) ringingItems else emptyList()

        /** The segment ringing now, for forecasts made from outside. */
        @Volatile private var playingSegment: Segment? = null

        /** Which ring each alarm in [playingSegment] is on. */
        @Volatile private var playingRings: Map<String, Int> = emptyMap()

        /**
         * Every alarm in the segment ringing now, for the alarm screen's rows
         * (2026-10-05): who and what (the stored sentence), the plan's time,
         * which ring, whether it is a voice note and whether it is the one
         * sounding. All from the store, so a cold start has it at once.
         */
        fun segmentDetails(context: Context): List<Map<String, Any>> {
            if (!ringing) return emptyList()
            val segment = playingSegment ?: return emptyList()
            val rows = AlarmDeliveryStore.load(context).associateBy { it.itemId }
            val sounding = ringingItem
            return segment.itemIds.map { id ->
                val row = rows[id]
                mapOf(
                    "itemId" to id,
                    "headline" to (row?.headline ?: headlines[id]).orEmpty(),
                    "scheduledAtMillis" to (row?.scheduledEpoch ?: 0L),
                    "ring" to (playingRings[id] ?: 1),
                    "voice" to (row?.voice != null),
                    "sounding" to (id == sounding),
                )
            }
        }

        /**
         * When [itemId] rings next if nothing new is planned, or null when it
         * is not in the queue. While it rings, this is the ring after.
         */
        fun nextRingAt(context: Context, itemId: String): Long? {
            val rows = AlarmDeliveryStore.load(context)
            if (rows.none { it.itemId == itemId }) return null
            return RingQueuePolicy.forecast(
                rows.map { it.toAlarm() },
                System.currentTimeMillis(),
                playingSegment,
            )[itemId]
        }

        /**
         * Look at the queue now: an OS alarm fired (a plan's time, or the
         * queue's own wake-up), or the queue changed. Starts the service when
         * something is due; otherwise arms the next wake-up. Returns false
         * only when a due alarm could not start its service.
         */
        fun kick(context: Context): Boolean {
            if (running) {
                return try {
                    context.startService(
                        Intent(context, AlarmSoundService::class.java).setAction(ACTION_START),
                    )
                    true
                } catch (error: Throwable) {
                    Log.e(TAG, "failed to reach the running service", error)
                    false
                }
            }
            val now = System.currentTimeMillis()
            val rows = loadQueue(context, now)
            val alarms = rows.map { it.toAlarm() }
            if (RingQueuePolicy.nextSegment(alarms, now) == null) {
                planIdle(context, rows, alarms, now, null)
                return true
            }
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, AlarmSoundService::class.java).setAction(ACTION_START),
                )
                true
            } catch (error: Throwable) {
                Log.e(TAG, "failed to request alarm service start", error)
                false
            }
        }

        /**
         * The alarm screen opened [itemId] (R5 / UI fallback): make sure it is
         * in the queue, then look. A plan the native side never armed joins
         * as a new alarm at its own time.
         */
        fun startForItem(context: Context, itemId: String, headline: String, scheduledEpoch: Long) {
            if (itemId.isEmpty()) return
            if (headline.isNotBlank()) headlines[itemId] = headline
            val rows = AlarmDeliveryStore.load(context)
            if (rows.none { it.itemId == itemId }) {
                AlarmDeliveryStore.put(
                    context,
                    AlarmDeliveryStore.Pending(
                        id = ("ui:$itemId").hashCode() and 0x7FFF_FFFF,
                        itemId = itemId,
                        scheduledEpoch = if (scheduledEpoch > 0) scheduledEpoch else System.currentTimeMillis(),
                        exact = true,
                        headline = headline,
                    ),
                )
            }
            kick(context)
        }

        /**
         * Dismiss from the app (the alarm screen): [itemId] leaves the queue
         * and stops if it is ringing; the rest carry on. The app records the
         * dismissal itself.
         */
        fun stopForItem(context: Context, itemId: String) {
            if (itemId.isEmpty()) return
            if (running) {
                context.startService(
                    Intent(context, AlarmSoundService::class.java)
                        .setAction(ACTION_STOP_ITEM)
                        .putExtra(EXTRA_ITEM_ID, itemId),
                )
                return
            }
            AlarmDeliveryStore.removeItems(context, listOf(itemId))
            kick(context)
        }

        /**
         * The plan is no longer wanted (answered, withdrawn, dismissed between
         * rings): already removed from the store by the caller. Stop it if it
         * is ringing, and re-plan the rest.
         */
        fun leaveQueue(context: Context, itemId: String) {
            if (running) {
                try {
                    context.startService(
                        Intent(context, AlarmSoundService::class.java)
                            .setAction(ACTION_LEAVE_ITEM)
                            .putExtra(EXTRA_ITEM_ID, itemId),
                    )
                } catch (_: Throwable) {
                }
                return
            }
            kick(context)
        }

        /**
         * Reads the queue: stale plans pruned, and any voice note whose length
         * never arrived measured from its file and recorded (2026-10-05).
         */
        private fun loadQueue(context: Context, now: Long): List<AlarmDeliveryStore.Pending> {
            val rows = pruneStale(context, AlarmDeliveryStore.load(context), now)
            val measured = AlarmDeliveryStore.withMeasuredVoices(rows, VoiceNoteLength::measure)
            if (measured != rows) AlarmDeliveryStore.save(context, measured)
            remember(measured)
            return measured
        }

        /** Plans whose first ring is a day overdue end as missed, unrung. */
        private fun pruneStale(
            context: Context,
            rows: List<AlarmDeliveryStore.Pending>,
            now: Long,
        ): List<AlarmDeliveryStore.Pending> {
            val stale = AlarmDeliveryStore.stale(rows, now)
            if (stale.isEmpty()) return rows
            AlarmDeliveryStore.removeItems(context, stale.map { it.itemId })
            stale.forEach {
                missWithoutRinging(context, it.itemId, it.headline, now, it.scheduledEpoch)
            }
            return rows.filterNot { row -> stale.any { it.itemId == row.itemId } }
        }

        /**
         * Nothing to ring now: arm the next look, and keep each waiting alarm's
         * "Rings again at …" notice current.
         */
        private fun planIdle(
            context: Context,
            rows: List<AlarmDeliveryStore.Pending>,
            alarms: List<RingQueuePolicy.Alarm>,
            now: Long,
            current: Segment?,
        ) {
            if (current == null) {
                val next = RingQueuePolicy.nextWakeAt(alarms, now)
                if (next == null) {
                    AlarmDeliveryScheduler.cancelQueueWake(context)
                } else {
                    val itemId = alarms.firstOrNull { it.dueAt == next }?.itemId.orEmpty()
                    val armed = AlarmDeliveryScheduler.armQueueWake(context, next, itemId)
                    ReminderAuditLog.write(
                        context,
                        event = "QUEUE_WAKE",
                        itemId = itemId,
                        atEpoch = next,
                        note = if (armed) "armed" else "arm_failed",
                    )
                }
            }
            refreshWaitingNotices(context, rows, alarms, now, current)
        }

        /**
         * An alarm whose first ring is long gone ends exactly as an unanswered
         * ring does, but without a sound: the missed notice, the timeout row
         * (the app's missed popup) and the planner's "unavailable" push.
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

        private fun waitingNoticeId(notificationId: Int): Int =
            ("quiet:$notificationId").hashCode()

        fun cancelWaitingNotice(context: Context, notificationId: Int) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                nm.cancel(waitingNoticeId(notificationId))
            } catch (_: Throwable) {
            }
        }

        /**
         * One ongoing notice per alarm waiting for a repeat: "Rings again at
         * {forecast}" with Dismiss. Alarms not waiting (ringing now, or not
         * rung yet) have none.
         */
        private fun refreshWaitingNotices(
            context: Context,
            rows: List<AlarmDeliveryStore.Pending>,
            alarms: List<RingQueuePolicy.Alarm>,
            now: Long,
            current: Segment?,
        ) {
            val forecast = RingQueuePolicy.forecast(alarms, now, current)
            val inSegment = current?.itemIds.orEmpty().toSet()
            rows.forEach { row ->
                val at = forecast[row.itemId]
                if (row.ringsDone >= 1 && row.itemId !in inSegment && at != null) {
                    postWaitingNotice(context, row, at)
                } else {
                    cancelWaitingNotice(context, row.id)
                }
            }
        }

        private fun postWaitingNotice(
            context: Context,
            row: AlarmDeliveryStore.Pending,
            nextAt: Long,
        ) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    nm.getNotificationChannel(WAITING_CHANNEL_ID) == null
                ) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            WAITING_CHANNEL_ID,
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
                val noticeId = waitingNoticeId(row.id)
                val open = PendingIntent.getActivity(
                    context,
                    noticeId,
                    Intent(context, MainActivity::class.java).apply {
                        action = "SELECT_NOTIFICATION"
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        putExtra("notificationId", row.id)
                        putExtra("payload", row.itemId)
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val dismiss = PendingIntent.getBroadcast(
                    context,
                    noticeId,
                    Intent(context, AlarmQuietDismissReceiver::class.java)
                        .putExtra(AlarmQuietDismissReceiver.EXTRA_ID, row.id)
                        .putExtra(AlarmQuietDismissReceiver.EXTRA_ITEM, row.itemId),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val notification = NotificationCompat.Builder(context, WAITING_CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(AlarmSoundPolicy.ringingTitle(row.headline))
                    .setContentText(AlarmSoundPolicy.quietText(time))
                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    // Only Dismiss ends it; a swipe would hide the one way to.
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setContentIntent(open)
                    .addAction(R.drawable.ic_notification, "Dismiss", dismiss)
                    .build()
                nm.notify(noticeId, notification)
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
    private val handler = Handler(Looper.getMainLooper())

    /** The segment ringing now, and the plan time of its first alarm. */
    private var current: Segment? = null
    private var currentScheduledAt = 0L

    /** Which ring each alarm in [current] is on (1, 2 or 3). */
    private var ringNumbers: Map<String, Int> = emptyMap()

    /** Every timer of [current]: sound starts and stops, and its end. */
    private val timers = mutableListOf<Runnable>()

    /** The alarm whose sound is playing now. */
    private var soundingItem: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Started with startForegroundService: promote at once, whatever the
        // action, or Android ends the app for not doing so.
        ensureForeground()
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "stop all")
                finish()
            }
            ACTION_STOP_ITEM -> {
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID).orEmpty()
                Log.i(TAG, "dismissed in app: $itemId")
                takeOut(listOf(itemId))
            }
            ACTION_LEAVE_ITEM -> {
                val itemId = intent.getStringExtra(EXTRA_ITEM_ID).orEmpty()
                Log.i(TAG, "left the queue: $itemId")
                takeOut(listOf(itemId))
            }
            ACTION_VOLUME_SILENCE -> {
                // Volume Down silences EVERY alarm ringing now (2026-10-04).
                val ids = current?.itemIds.orEmpty()
                recordDismissal("VOLUME_SILENCED", "foreground_activity", ids)
                takeOut(ids)
            }
            ACTION_NOTIFICATION_DISMISS -> {
                // The notification names the alarm that is sounding; Dismiss
                // answers that one. The rest of the segment carries on.
                val itemId = soundingItem ?: current?.itemIds?.firstOrNull()
                if (itemId == null) {
                    tick()
                } else {
                    recordDismissal("NOTIFICATION_DISMISSED", "notification_action", listOf(itemId))
                    takeOut(listOf(itemId))
                }
            }
            else -> tick()
        }
        // NOT sticky: a silent restart with no wake lock and no UI must never
        // resurrect an alarm. The queue's OS alarms bring it back instead.
        return START_NOT_STICKY
    }

    /** Looks at the queue: cut in for a newly due alarm, play, or go idle. */
    private fun tick() {
        val now = System.currentTimeMillis()
        val rows = loadQueue(this, now)
        val alarms = rows.map { it.toAlarm() }
        val playing = current
        if (playing != null) {
            val incoming = alarms
                .filter { it.isFresh && it.scheduledAt <= now && it.itemId !in playing.itemIds }
                .maxByOrNull { it.scheduledAt }
            if (incoming != null && RingQueuePolicy.interrupts(playing, currentScheduledAt, incoming)) {
                val cut = RingQueuePolicy.cutAt(playing, now)
                Log.i(TAG, "${incoming.itemId} cuts in at $cut")
                cancelTimers()
                postAt(cut) { endSegment() }
            }
            planIdle(this, rows, alarms, now, playing)
            return
        }
        val segment = RingQueuePolicy.nextSegment(alarms, now)
        if (segment == null) {
            planIdle(this, rows, alarms, now, null)
            finish()
            return
        }
        play(segment, rows, now)
        planIdle(this, rows, alarms, now, segment)
    }

    private fun play(segment: Segment, rows: List<AlarmDeliveryStore.Pending>, now: Long) {
        val byItem = rows.associateBy { it.itemId }
        current = segment
        currentScheduledAt = byItem[segment.itemIds.first()]?.scheduledEpoch ?: now
        ringNumbers = segment.itemIds.associateWith { (byItem[it]?.ringsDone ?: 0) + 1 }
        ringing = true
        acquireWake(segment.endsAt - now + WAKE_SLACK_MS)
        if (segment.fresh) {
            byItem[segment.itemIds.first()]?.let { suppressScheduledDuplicate(it.id) }
        }
        for (sound in segment.sounds) {
            postAt(sound.from) { startSound(sound, byItem) }
            if (sound is Sound.Tone) postAt(sound.to) { releasePlayer() }
        }
        postAt(segment.endsAt) { endSegment() }
        // If this process dies mid-ring, the queue still looks again just
        // after the segment would have ended; a normal end re-arms it anyway.
        AlarmDeliveryScheduler.armQueueWake(
            this,
            segment.endsAt + SAFETY_WAKE_MS,
            segment.itemIds.first(),
        )
        publish()
        // The planner's card: which ring, from when, until when (2026-10-05).
        RingRecordReporter.report(
            this,
            segment.itemIds.map { id ->
                RingRecordReporter.Record(
                    itemId = id,
                    ring = ringNumbers[id] ?: 1,
                    times = buildMap {
                        put("ringAt", segment.startsAt)
                        put("ringEndsAt", segment.endsAt)
                        put("nextRingAt", null)
                        if (segment.fresh) put("rangAt", segment.startsAt)
                    },
                )
            },
        )
        ReminderAuditLog.write(
            this,
            event = if (segment.fresh) "RING_FIRST" else "RING_REPEAT",
            itemId = segment.itemIds.joinToString(","),
            atEpoch = segment.startsAt,
            note = "until ${segment.endsAt}, ${segment.sounds.size} sound(s)",
        )
        // R5: tell the open app which plan is ringing, so it shows the alarm.
        sendBroadcast(
            Intent(ACTION_RINGING_STARTED)
                .setPackage(packageName)
                .putExtra(EXTRA_RINGING_ITEM, segment.itemIds.first()),
        )
    }

    /** Gives the speaker to one sound: a voice note's single play, or the tone. */
    private fun startSound(sound: Sound, byItem: Map<String, AlarmDeliveryStore.Pending>) {
        releasePlayer()
        when (sound) {
            is Sound.Voice -> {
                soundingItem = sound.itemId
                val voice = byItem[sound.itemId]?.voice
                // Only the exact file the plan was made with; anything else
                // rings the tone for the same span (never silence) and tells
                // the planner, once.
                if (voice == null || !VoiceAlarmPolicy.verify(voice) || !startVoiceOnce(voice)) {
                    recordVoiceFallback(sound.itemId)
                    startRingtoneNow()
                    postAt(sound.to) { releasePlayer() }
                }
            }
            is Sound.Tone -> {
                soundingItem = sound.itemIds.first()
                startRingtoneNow()
            }
        }
        publish()
        updateNotification()
    }

    /** The segment ran its course (or was cut): count its rings, look again. */
    private fun endSegment() {
        val segment = current ?: return
        val at = System.currentTimeMillis()
        cancelTimers()
        releasePlayer()
        current = null
        soundingItem = null
        val rows = AlarmDeliveryStore.load(this)
        val credit = RingQueuePolicy.credit(rows.map { it.toAlarm() }, segment, at)
        AlarmDeliveryStore.save(this, AlarmDeliveryStore.withRings(rows, credit.alarms))
        if (credit.missed.isNotEmpty()) {
            // The last ring ended unanswered: tell the person, even if the app
            // is dead. Tapping opens the app, whose missed-alarm review offers
            // Done / Skip.
            credit.missed.forEach { itemId ->
                rows.firstOrNull { it.itemId == itemId }?.let { cancelWaitingNotice(this, it.id) }
                postMissedNotice(this, itemId)
                AlarmLifecycleStore.record(this, itemId, AlarmLifecycleStore.KIND_TIMEOUT, at)
                ReminderAuditLog.write(this, event = "AUDIO_TIMEOUT", itemId = itemId, atEpoch = at)
            }
            // Tell the planners now, not when the app is next opened.
            MissedAlarmReporter.report(this, credit.missed, at)
            AlarmLifecycleChannel.notifyChanged()
        }
        Log.i(TAG, "ring ended for ${segment.itemIds}; missed ${credit.missed}")
        // The planner's card: when this ring really ended, and when the next
        // is expected for each alarm still waiting (a forecast).
        val stillLive = credit.alarms.filter { !it.isOver }
        val forecast = RingQueuePolicy.forecast(stillLive, at)
        RingRecordReporter.report(
            this,
            segment.itemIds
                .filter { id -> rows.any { it.itemId == id } }
                .map { id ->
                    RingRecordReporter.Record(
                        itemId = id,
                        times = mapOf("ringEndsAt" to at, "nextRingAt" to forecast[id]),
                    )
                },
        )
        tick()
    }

    /**
     * [itemIds] leave the queue now (dismissed, answered, cancelled). If any
     * is in the segment ringing, that segment ends here — what played still
     * counts for the others — and the queue looks again.
     */
    private fun takeOut(itemIds: List<String>) {
        val ids = itemIds.filter { it.isNotEmpty() }
        val rows = AlarmDeliveryStore.load(this)
        rows.filter { it.itemId in ids }.forEach { cancelWaitingNotice(this, it.id) }
        AlarmDeliveryStore.removeItems(this, ids)
        val playing = current
        if (playing != null && playing.itemIds.any { it in ids }) {
            endSegment()
        } else {
            tick()
        }
    }

    private fun postAt(atEpoch: Long, block: () -> Unit) {
        val runnable = Runnable { block() }
        timers += runnable
        handler.postDelayed(runnable, (atEpoch - System.currentTimeMillis()).coerceAtLeast(0L))
    }

    private fun cancelTimers() {
        timers.forEach(handler::removeCallbacks)
        timers.clear()
    }

    /** What the app asks for: which alarms ring now, and which one sounds. */
    private fun publish() {
        ringingItem = soundingItem ?: current?.itemIds?.firstOrNull()
        ringingItems = current?.itemIds.orEmpty()
        playingSegment = current
        playingRings = ringNumbers
    }

    /**
     * The foreground notification: the whole point is to keep the CPU (and
     * therefore audio) alive with the screen off.
     */
    private fun ensureForeground() {
        if (foreground) return
        createChannel()
        val type =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            else 0
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(), type)
        foreground = true
    }

    /** Each segment re-arms the lock's timeout, so a leak cannot outlive it. */
    private fun acquireWake(forMs: Long) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = wakeLock ?: pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
        }.also { wakeLock = it }
        lock.acquire(forMs.coerceAtLeast(WAKE_SLACK_MS))
    }

    private fun updateNotification() {
        if (!foreground) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
    }

    private fun releasePlayer() {
        player?.let {
            try {
                if (it.isPlaying) it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
    }

    /** One play of [voice] on the alarm stream; the queue times the next. */
    private fun startVoiceOnce(voice: VoiceAlarmSpec): Boolean = try {
        player = MediaPlayer().apply {
            setAudioAttributes(alarmAttributes())
            setDataSource(voice.path)
            isLooping = false
            prepare()
            start()
        }
        ReminderAuditLog.write(this, event = "VOICE_PLAYING", note = "${player!!.duration}ms")
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
        if (!AlarmSoundPolicy.shouldStartPlayer(player != null)) return
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
            Log.e(TAG, "failed to start alarm playback: $e")
            releasePlayer()
        }
    }

    /**
     * ONE notification per alarm (device report 2026-09-25). The scheduled
     * reminder notification shares the plan's id and fires from a separate
     * OS alarm at the same instant; once this service rings, its own
     * notification says everything, so the scheduled one is removed — now and
     * again shortly after, because the two alarms can land in either order.
     */
    private fun suppressScheduledDuplicate(notificationId: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notificationId)
        AlarmSoundPolicy.DUPLICATE_RECHECK_MS.forEach { delay ->
            handler.postDelayed({ if (ringing) nm.cancel(notificationId) }, delay)
        }
    }

    private fun recordDismissal(event: String, note: String, itemIds: Collection<String>) {
        val at = System.currentTimeMillis()
        itemIds.forEach { itemId ->
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

    /** Nothing rings: release everything and stop. The queue lives on in the store. */
    private fun finish() {
        cancelTimers()
        releasePlayer()
        ringing = false
        current = null
        soundingItem = null
        publish()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        foreground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        sendBroadcast(Intent(ACTION_RINGING_ENDED).setPackage(packageName))
    }

    override fun onDestroy() {
        // Belt and braces — a destroyed service must not leave the wake lock
        // held or the tone playing.
        running = false
        if (current != null || player != null) finish()
        super.onDestroy()
    }

    private fun alarmUri(): Uri =
        RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: Settings.System.DEFAULT_ALARM_ALERT_URI

    /**
     * A SILENT, HIGH channel — the service plays the sound, so the notification
     * must not add a second one. High importance lets its full-screen intent or
     * heads-up Dismiss fallback remain visible.
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

    /** The plan's time in the phone's own clock format, from the store. */
    private fun plannedTimeOf(itemId: String): String? {
        val at = AlarmDeliveryStore.load(this).firstOrNull { it.itemId == itemId }
            ?.scheduledEpoch ?: return null
        return android.text.format.DateFormat.getTimeFormat(this).format(java.util.Date(at))
    }

    private fun currentItemId(): String =
        soundingItem ?: current?.itemIds?.firstOrNull().orEmpty()

    // With the phone unlocked Android shows this as a heads-up instead of the
    // full-screen alarm, so the heads-up itself must say who planned what.
    private fun buildNotification(): android.app.Notification {
        val itemId = currentItemId()
        return NotificationCompat.Builder(this, CHANNEL_ID)
            // Android small icons are monochrome silhouettes. The launcher icon
            // becomes a solid blob here; this resource is the Mind Time mark
            // specifically drawn for the notification tray.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(
                AlarmSoundPolicy.ringingTitle(headlines[itemId], ringNumbers[itemId] ?: 1),
            )
            .setContentText(
                AlarmSoundPolicy.ringingText(
                    plannedTimeOf(itemId),
                    (current?.itemIds?.size ?: 1) - 1,
                ),
            )
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(launchAlarmUi(itemId))
            .setFullScreenIntent(launchAlarmUi(itemId), true)
            .addAction(
                R.drawable.ic_notification,
                "Dismiss",
                dismissFromNotification(),
            )
            .build()
    }

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
     * same AlarmScreen.
     */
    private fun launchAlarmUi(itemId: String): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = "SELECT_NOTIFICATION"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("notificationId", NOTIF_ID)
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
