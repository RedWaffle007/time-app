package com.timeapp.time_app.reminders

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * The audit layer's own pending set, in DEVICE-PROTECTED SharedPreferences.
 *
 * Deliberately SEPARATE from the Dart-side mirror
 * (`reminder_mirror_store.dart`, plain `shared_preferences`). They answer
 * different questions and are readable at different times: the Dart mirror is
 * what the app believes it has scheduled and is read on app start; this one is
 * what [ReminderAuditBootReceiver] must re-arm before the phone has even been
 * unlocked, and Dart is not running then. Merging them would put the boot
 * receiver's input behind credential-protected storage, where reading it throws.
 *
 * Keyed by notification id — the same deterministic id the notification itself
 * uses — so an audit alarm and the reminder it shadows are trivially paired in
 * the CSV.
 */
object ReminderAuditStore {

    private const val PREFS = "reminder_audit_pending"
    private const val KEY = "pending"

    private fun prefs(context: Context) =
        ReminderAuditLog.deviceCtx(context).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** One armed audit alarm: which reminder, and the instant it should fire. */
    data class Pending(val id: Int, val itemId: String, val scheduledEpoch: Long)

    fun load(context: Context): List<Pending> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                Pending(o.getInt("id"), o.optString("itemId"), o.getLong("scheduledEpoch"))
            }
        } catch (t: Throwable) {
            // A corrupt store must not wedge the boot receiver forever. Losing
            // audit rows costs a measurement; throwing here costs the reboot.
            emptyList()
        }
    }

    fun save(context: Context, items: List<Pending>) {
        val arr = JSONArray()
        items.forEach {
            arr.put(
                JSONObject().apply {
                    put("id", it.id)
                    put("itemId", it.itemId)
                    put("scheduledEpoch", it.scheduledEpoch)
                },
            )
        }
        prefs(context).edit().putString(KEY, arr.toString()).apply()
    }

    /** Upsert by id, so re-arming the same reminder replaces rather than doubles. */
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
