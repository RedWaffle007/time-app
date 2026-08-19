package com.timeapp.alarm_spike

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms alarms after the OS threw them away.
 *
 * `AlarmManager` keeps scheduled alarms in volatile memory only — a reboot drops
 * every one, with no error to anyone. This receiver is the answer, and its
 * presence-or-absence in the log is itself a headline result: on Xiaomi,
 * BOOT_COMPLETED is blocked outright unless Autostart is enabled, so
 * **a reboot run with no BOOT row in the CSV is not a bug in this code — it is
 * the finding.**
 *
 * Registered for more than boot on purpose (per the nek12 reliability guide):
 * a package replace (app update) and a wall-clock/timezone change all invalidate
 * scheduled alarms in ways that are invisible until a reminder silently doesn't
 * arrive.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val at = System.currentTimeMillis()
        val action = intent.action ?: "unknown"

        SpikeLog.write(context, event = "BOOT", firedEpoch = at, note = action)

        val pending = SpikeStore.load(context)
        if (pending.isEmpty()) return

        val stillFuture = pending.filter { it.scheduledEpoch > at }
        val alreadyPast = pending.filter { it.scheduledEpoch <= at }

        alreadyPast.forEach {
            // The reboot ate it. Record it explicitly — a missed reminder that
            // leaves no trace is the failure mode this whole exercise is about.
            SpikeLog.write(
                context,
                event = "MISSED_AT_BOOT",
                variant = it.variant,
                scheduledEpoch = it.scheduledEpoch,
                firedEpoch = at,
                note = action
            )
        }

        stillFuture.forEach {
            val outcome = AlarmScheduler.schedule(context, it.variant, it.scheduledEpoch)
            SpikeLog.write(
                context,
                event = if (outcome == "ok") "REARMED" else "REARM_FAILED",
                variant = it.variant,
                scheduledEpoch = it.scheduledEpoch,
                firedEpoch = at,
                note = if (outcome == "ok") action else outcome
            )
        }

        SpikeStore.save(context, stillFuture)
    }
}
