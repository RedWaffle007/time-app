package com.timeapp.time_app.reminders

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Durable native facts that Flutter must reconcile when authenticated again. */
object AlarmLifecycleStore {
    private const val PREFS = "alarm_lifecycle_events"
    private const val KEY = "events"

    const val KIND_TIMEOUT = "timeout"
    const val KIND_DISMISSED = "dismissed"
    // Read compatibility for item 21 builds installed before the generalized
    // dismissal event name. Dart accepts both values.
    const val KIND_VOLUME_SILENCED = "volume_silenced"

    data class Event(
        val itemId: String,
        val occurredAtEpoch: Long,
        val kind: String,
        val outcomeRecorded: Boolean = false,
        val notificationDelivered: Boolean = false,
        val reviewed: Boolean = false,
        val reviewChoice: String? = null,
        val reviewNotificationDelivered: Boolean = false,
    ) {
        val key: String get() = "$kind:$itemId:$occurredAtEpoch"
    }

    private fun prefs(context: Context) =
        ReminderAuditLog.deviceCtx(context)
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context): List<Event> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).map { index ->
                val value = array.getJSONObject(index)
                Event(
                    itemId = value.getString("itemId"),
                    occurredAtEpoch = value.getLong("occurredAtEpoch"),
                    kind = value.getString("kind"),
                    outcomeRecorded = value.optBoolean("outcomeRecorded"),
                    notificationDelivered = value.optBoolean("notificationDelivered"),
                    reviewed = value.optBoolean("reviewed"),
                    reviewChoice = value.optString("reviewChoice").ifEmpty { null },
                    reviewNotificationDelivered = value.optBoolean("reviewNotificationDelivered"),
                )
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun save(context: Context, events: List<Event>) {
        val array = JSONArray()
        events.forEach { event ->
            array.put(JSONObject().apply {
                put("itemId", event.itemId)
                put("occurredAtEpoch", event.occurredAtEpoch)
                put("kind", event.kind)
                put("outcomeRecorded", event.outcomeRecorded)
                put("notificationDelivered", event.notificationDelivered)
                put("reviewed", event.reviewed)
                event.reviewChoice?.let { put("reviewChoice", it) }
                put("reviewNotificationDelivered", event.reviewNotificationDelivered)
            })
        }
        // These rows are the recovery source after process death. Commit the
        // tiny local payload before returning so a review choice cannot be
        // lost between dismissing the popup and starting Firestore work.
        prefs(context).edit().putString(KEY, array.toString()).commit()
    }

    fun record(context: Context, itemId: String, kind: String, atEpoch: Long) {
        if (itemId.isEmpty()) return
        save(context, upsert(load(context), Event(itemId, atEpoch, kind)))
    }

    fun update(context: Context, key: String, transform: (Event) -> Event) {
        save(context, load(context).map { if (it.key == key) transform(it) else it })
    }

    fun remove(context: Context, key: String) {
        save(context, withoutKey(load(context), key))
    }

    internal fun upsert(events: List<Event>, event: Event): List<Event> {
        val previous = events.firstOrNull { it.key == event.key }
        val durable = if (previous == null) event else event.copy(
            outcomeRecorded = previous.outcomeRecorded,
            notificationDelivered = previous.notificationDelivered,
            reviewed = previous.reviewed,
            reviewChoice = previous.reviewChoice,
            reviewNotificationDelivered = previous.reviewNotificationDelivered,
        )
        return events.filterNot { it.key == event.key } + durable
    }

    internal fun withoutKey(events: List<Event>, key: String): List<Event> =
        events.filterNot { it.key == key }
}
