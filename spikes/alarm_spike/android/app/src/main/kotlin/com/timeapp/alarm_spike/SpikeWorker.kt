package com.timeapp.alarm_spike

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * The WorkManager arm of the comparison. Kept deliberately identical in what it
 * records so the WORKMANAGER row is comparable to the three AlarmManager rows.
 *
 * Note what this arm CANNOT do: WorkManager is not direct-boot aware, so after
 * a reboot it cannot run until the user unlocks. That is a real difference from
 * the AlarmManager arms re-armed by LOCKED_BOOT_COMPLETED, and the reboot test
 * is where it will show up.
 */
class SpikeWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    companion object {
        const val KEY_SCHEDULED = "scheduled"
    }

    override fun doWork(): Result {
        val firedAt = System.currentTimeMillis()
        val scheduled = inputData.getLong(KEY_SCHEDULED, 0L)

        SpikeLog.write(
            applicationContext,
            event = "FIRED",
            variant = AlarmScheduler.WORKMANAGER,
            scheduledEpoch = if (scheduled > 0) scheduled else null,
            firedEpoch = firedAt,
            note = "worker"
        )
        SpikeStore.remove(applicationContext, AlarmScheduler.WORKMANAGER)

        val delay = if (scheduled > 0) (firedAt - scheduled) / 1000.0 else 0.0
        Notifications.show(applicationContext, AlarmScheduler.WORKMANAGER, delay)
        return Result.success()
    }
}
