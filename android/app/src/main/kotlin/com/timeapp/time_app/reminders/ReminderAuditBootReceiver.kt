package com.timeapp.time_app.reminders

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms the shadow alarms the OS threw away, and — more importantly — records
 * that it got the chance to.
 *
 * `AlarmManager` keeps scheduled alarms in volatile memory only: a reboot drops
 * every one, with no error to anyone. flutter_local_notifications re-registers
 * its own notifications from its own store on BOOT_COMPLETED; this does the same
 * for the audit alarms, so the two stay paired and a post-reboot reminder still
 * produces a measurement.
 *
 * **The presence or absence of a BOOT row is itself a result.** On Xiaomi,
 * BOOT_COMPLETED is blocked outright unless Autostart is enabled — so a reboot
 * that produces no BOOT row here is not a bug in this file, it is the finding,
 * and it means flutter_local_notifications' boot receiver did not run either.
 * That single bit is the strongest evidence for or against needing an OEM
 * autostart primer, and Part 1 does not yet have it: the spike's reboot cell
 * (Run E) was never completed — the only BOOT rows in `run_2026-08-20_G2.csv`
 * are the install-time artifact its README warns about.
 *
 * Registered for more than boot on purpose: a package replace (an app update)
 * and a wall-clock or timezone change each invalidate scheduled alarms in ways
 * that are invisible until a reminder simply does not arrive.
 */
class ReminderAuditBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val at = System.currentTimeMillis()
        val action = intent.action ?: "unknown"

        ReminderAuditLog.write(context, event = "BOOT", atEpoch = at, note = action)

        val pending = ReminderAuditStore.load(context)
        if (pending.isEmpty()) return

        val stillFuture = pending.filter { it.scheduledEpoch > at }
        val alreadyPast = pending.filter { it.scheduledEpoch <= at }

        alreadyPast.forEach {
            // The reboot ate it. Recorded explicitly — a missed reminder that
            // leaves no trace is the exact failure this whole layer exists to
            // make impossible to miss.
            ReminderAuditLog.write(
                context,
                event = "MISSED_AT_BOOT",
                itemId = it.itemId,
                notificationId = it.id,
                scheduledEpoch = it.scheduledEpoch,
                atEpoch = at,
                note = action,
            )
        }

        stillFuture.forEach {
            val outcome = ReminderAuditScheduler.arm(context, it.id, it.itemId, it.scheduledEpoch)
            ReminderAuditLog.write(
                context,
                event = if (outcome == "ok") "REARMED" else "REARM_FAILED",
                itemId = it.itemId,
                notificationId = it.id,
                scheduledEpoch = it.scheduledEpoch,
                atEpoch = at,
                note = if (outcome == "ok") action else outcome,
            )
        }

        ReminderAuditStore.save(context, stillFuture)
    }
}
