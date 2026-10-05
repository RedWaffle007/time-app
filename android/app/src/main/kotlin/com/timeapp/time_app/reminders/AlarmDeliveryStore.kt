package com.timeapp.time_app.reminders

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Device-protected record of every live alarm: the plans armed for this
 * phone and, since the ring queue (2026-10-05), where each stands — how many
 * of its rings have counted and when the last one started. An alarm stays
 * here from arming until it is answered, dismissed, cancelled or missed, so
 * the queue survives the process dying and the phone rebooting.
 */
object AlarmDeliveryStore {
    private const val PREFS = "alarm_delivery_pending"
    private const val KEY = "pending"

    /**
     * A plan that never rang this long after its time (the phone was off) is
     * not rung any more: it ends as missed. Repeats have no cut-off.
     */
    const val STALE_FIRST_RING_MS = 24 * 60 * 60_000L

    /** A voice note whose length was not passed in: plan for the longest. */
    const val DEFAULT_VOICE_MS = 25_000L

    data class Pending(
        val id: Int,
        val itemId: String,
        val scheduledEpoch: Long,
        val exact: Boolean,
        /** The sentence the alarm shows; survives reboot re-arming. */
        val headline: String = "",
        /** The voice note to play (32c-2); survives reboot re-arming too. */
        val voice: VoiceAlarmSpec? = null,
        /** The voice note's length (2026-10-05); 0 when unknown. */
        val voiceMs: Long = 0L,
        /** Rings that have counted (the ring queue, 2026-10-05). */
        val ringsDone: Int = 0,
        /** When the last counted ring started; 0 before the first. */
        val lastRingAt: Long = 0L,
    ) {
        internal fun toAlarm(): RingQueuePolicy.Alarm = RingQueuePolicy.Alarm(
            itemId = itemId,
            scheduledAt = scheduledEpoch,
            voiceMs = voice?.let { if (voiceMs > 0) voiceMs else DEFAULT_VOICE_MS },
            ringsDone = ringsDone,
            lastRingAt = lastRingAt,
        )
    }

    private fun prefs(context: Context) =
        ReminderAuditLog.deviceCtx(context).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context): List<Pending> =
        decode(prefs(context).getString(KEY, null))

    fun save(context: Context, items: List<Pending>) {
        // commit, not apply: a receiver or service may be killed right after.
        prefs(context).edit().putString(KEY, encode(items)).commit()
    }

    fun put(context: Context, item: Pending) {
        save(context, upsert(load(context), item))
    }

    fun remove(context: Context, id: Int) {
        save(context, withoutId(load(context), id))
    }

    fun removeItems(context: Context, itemIds: Collection<String>) {
        if (itemIds.isEmpty()) return
        save(context, load(context).filterNot { it.itemId in itemIds })
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).commit()
    }

    /** Pure JSON codec (JVM-tested): what survives a reboot. */
    internal fun decode(raw: String?): List<Pending> {
        if (raw == null) return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).map { index ->
                val value = array.getJSONObject(index)
                Pending(
                    value.getInt("id"),
                    value.optString("itemId"),
                    value.getLong("scheduledEpoch"),
                    value.optBoolean("exact", true),
                    value.optString("headline", ""),
                    VoiceAlarmSpec.of(
                        value.optString("voicePath", "").ifEmpty { null },
                        value.optString("voiceSha256", "").ifEmpty { null },
                        value.optLong("voiceSize", 0L),
                    ),
                    value.optLong("voiceMs", 0L),
                    value.optInt("ringsDone", 0),
                    value.optLong("lastRingAt", 0L),
                )
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    internal fun encode(items: List<Pending>): String {
        val array = JSONArray()
        items.forEach { item ->
            array.put(
                JSONObject().apply {
                    put("id", item.id)
                    put("itemId", item.itemId)
                    put("scheduledEpoch", item.scheduledEpoch)
                    put("exact", item.exact)
                    put("headline", item.headline)
                    put("voiceMs", item.voiceMs)
                    put("ringsDone", item.ringsDone)
                    put("lastRingAt", item.lastRingAt)
                    item.voice?.let {
                        put("voicePath", it.path)
                        put("voiceSha256", it.sha256)
                        put("voiceSize", it.sizeBytes)
                    }
                },
            )
        }
        return array.toString()
    }

    /**
     * Arming replaces the row with the same id. An alarm re-armed after it
     * started ringing (a changed sentence) keeps its place in the queue.
     */
    internal fun upsert(items: List<Pending>, item: Pending): List<Pending> {
        val existing = items.firstOrNull { it.id == item.id && it.itemId == item.itemId }
        val merged = if (existing == null) {
            item
        } else {
            item.copy(ringsDone = existing.ringsDone, lastRingAt = existing.lastRingAt)
        }
        return items.filterNot { it.id == item.id } + merged
    }

    internal fun withoutId(items: List<Pending>, id: Int): List<Pending> =
        items.filterNot { it.id == id }

    /** The queue's counted rings written back onto the stored rows. */
    internal fun withRings(items: List<Pending>, alarms: List<RingQueuePolicy.Alarm>): List<Pending> {
        val byItem = alarms.associateBy { it.itemId }
        return items.mapNotNull { item ->
            val alarm = byItem[item.itemId] ?: return@mapNotNull item
            if (alarm.isOver) null else item.copy(ringsDone = alarm.ringsDone, lastRingAt = alarm.lastRingAt)
        }
    }

    /**
     * Voice notes whose length is unknown, measured with [measure] and
     * recorded (2026-10-05). Only rows that changed are returned changed;
     * a file not downloaded yet stays unknown and is tried again next look.
     */
    internal fun withMeasuredVoices(
        items: List<Pending>,
        measure: (String) -> Long,
    ): List<Pending> = items.map { item ->
        val voice = item.voice
        if (voice == null || item.voiceMs > 0) return@map item
        val ms = measure(voice.path)
        if (ms > 0) item.copy(voiceMs = ms) else item
    }

    /** Plans whose first ring is so far past ([STALE_FIRST_RING_MS]) they end unrung. */
    internal fun stale(items: List<Pending>, nowEpoch: Long): List<Pending> =
        items.filter { it.ringsDone == 0 && nowEpoch - it.scheduledEpoch > STALE_FIRST_RING_MS }
}
