package com.timeapp.time_app.reminders

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Device-protected mirror used to restore native audio alarms after reboot. */
object AlarmDeliveryStore {
    private const val PREFS = "alarm_delivery_pending"
    private const val KEY = "pending"

    data class Pending(
        val id: Int,
        val itemId: String,
        val scheduledEpoch: Long,
        val exact: Boolean,
        /** The sentence the alarm shows; survives reboot re-arming. */
        val headline: String = "",
    )

    private fun prefs(context: Context) =
        ReminderAuditLog.deviceCtx(context).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context): List<Pending> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
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
                )
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun save(context: Context, items: List<Pending>) {
        val array = JSONArray()
        items.forEach { item ->
            array.put(
                JSONObject().apply {
                    put("id", item.id)
                    put("itemId", item.itemId)
                    put("scheduledEpoch", item.scheduledEpoch)
                    put("exact", item.exact)
                    put("headline", item.headline)
                },
            )
        }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    fun put(context: Context, item: Pending) {
        save(context, upsert(load(context), item))
    }

    fun remove(context: Context, id: Int) {
        save(context, withoutId(load(context), id))
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    /** Pure collection rules used by the scheduler/boot receiver and JVM tests. */
    internal fun upsert(items: List<Pending>, item: Pending): List<Pending> =
        items.filterNot { it.id == item.id } + item

    internal fun withoutId(items: List<Pending>, id: Int): List<Pending> =
        items.filterNot { it.id == id }

    internal fun futureOnly(items: List<Pending>, nowEpoch: Long): List<Pending> =
        items.filter { it.scheduledEpoch > nowEpoch }
}
