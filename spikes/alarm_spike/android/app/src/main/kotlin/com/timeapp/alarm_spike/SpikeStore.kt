package com.timeapp.alarm_spike

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * The pending-alarm set, in DEVICE-PROTECTED SharedPreferences.
 *
 * This exists because `AlarmManager` holds nothing across a reboot — the OS
 * drops every registered alarm on shutdown, silently. Without a durable record
 * of what SHOULD be scheduled, a boot receiver has nothing to re-register, and
 * the user loses every future reminder with no error and no signal. That is
 * the exact failure DECISIONS.md calls a correctness failure, not polish.
 *
 * Device-protected so BootReceiver can read it on LOCKED_BOOT_COMPLETED, i.e.
 * before the user has unlocked the phone after a reboot.
 */
object SpikeStore {

    private const val PREFS = "alarm_spike_pending"
    private const val KEY = "pending"

    private fun prefs(context: Context) =
        SpikeLog.deviceCtx(context).getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** A single scheduled test: which mechanism, and the instant it should fire. */
    data class Pending(val variant: String, val scheduledEpoch: Long)

    fun save(context: Context, items: List<Pending>) {
        val arr = JSONArray()
        items.forEach {
            arr.put(JSONObject().apply {
                put("variant", it.variant)
                put("scheduledEpoch", it.scheduledEpoch)
            })
        }
        prefs(context).edit().putString(KEY, arr.toString()).apply()
    }

    fun load(context: Context): List<Pending> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                Pending(o.getString("variant"), o.getLong("scheduledEpoch"))
            }
        } catch (t: Throwable) {
            emptyList()
        }
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    /** Drops one variant once it has fired, so a later boot doesn't resurrect it. */
    fun remove(context: Context, variant: String) {
        save(context, load(context).filterNot { it.variant == variant })
    }
}
