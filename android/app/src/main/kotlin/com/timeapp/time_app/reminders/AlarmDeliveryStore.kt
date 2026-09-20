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
                },
            )
        }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    fun put(context: Context, item: Pending) {
        save(context, load(context).filterNot { it.id == item.id } + item)
    }

    fun remove(context: Context, id: Int) {
        save(context, load(context).filterNot { it.id == id })
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }
}
