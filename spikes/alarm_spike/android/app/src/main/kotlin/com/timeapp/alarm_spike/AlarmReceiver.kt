package com.timeapp.alarm_spike

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The fire handler. Runs with the app process dead — that is the whole point.
 *
 * The FIRST statement must be the clock read. Anything before it (a log line, a
 * context lookup) is added to every delay figure the spike produces.
 */
class AlarmReceiver : BroadcastReceiver() {

    companion object {
        const val EXTRA_VARIANT = "variant"
        const val EXTRA_SCHEDULED = "scheduled"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val firedAt = System.currentTimeMillis()

        val variant = intent.getStringExtra(EXTRA_VARIANT) ?: "UNKNOWN"
        val scheduled = intent.getLongExtra(EXTRA_SCHEDULED, 0L)

        SpikeLog.write(
            context,
            event = "FIRED",
            variant = variant,
            scheduledEpoch = if (scheduled > 0) scheduled else null,
            firedEpoch = firedAt,
            note = "receiver"
        )

        // Fired means done — a later reboot must not resurrect it.
        SpikeStore.remove(context, variant)

        val delay = if (scheduled > 0) (firedAt - scheduled) / 1000.0 else 0.0
        Notifications.show(context, variant, delay)
    }
}
