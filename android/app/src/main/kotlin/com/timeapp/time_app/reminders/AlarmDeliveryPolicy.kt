package com.timeapp.time_app.reminders

/** Stable PendingIntent identity: re-arming one id updates, never duplicates. */
internal object AlarmDeliveryIdentity {
    fun requestCode(id: Int): Int = (id xor 0x41A2_6D37) and 0x7FFF_FFFF

    fun action(id: Int): String = "com.timeapp.time_app.ALARM_DELIVERY.$id"
}

/** The exact AlarmManager call selected for an arm request. */
internal enum class AlarmDeliveryMode {
    ALARM_CLOCK,
    INEXACT_ALLOW_IDLE,
    INEXACT,
}

internal fun alarmDeliveryMode(exact: Boolean, sdkInt: Int): AlarmDeliveryMode =
    when {
        exact -> AlarmDeliveryMode.ALARM_CLOCK
        sdkInt >= 23 -> AlarmDeliveryMode.INEXACT_ALLOW_IDLE
        else -> AlarmDeliveryMode.INEXACT
    }

/**
 * How long an alarm keeps trying (2026-10-04, user-directed: like a phone's
 * own alarm). Ring 5 minutes, quiet 5, three times — rings start at 0, 10 and
 * 20 minutes — and give up at 25: only then is it missed. An alarm the OS
 * delivered late joins whichever ring or quiet spell it lands in.
 *
 * Dart's `ring_cycle.dart` applies the same numbers; keep them equal.
 */
internal object RingCyclePolicy {
    const val RING_MS = 5 * 60_000L
    const val GAP_MS = 5 * 60_000L
    const val RINGS = 3
    const val TOTAL_MS = RINGS * RING_MS + (RINGS - 1) * GAP_MS

    sealed class Phase {
        data class Ring(val index: Int, val endsAt: Long) : Phase()
        data class Gap(val nextIndex: Int, val nextAt: Long) : Phase()
        object Over : Phase()
    }

    fun ringStart(scheduledEpoch: Long, index: Int): Long =
        scheduledEpoch + (index - 1) * (RING_MS + GAP_MS)

    /** Where an alarm at [scheduledEpoch] is at [nowEpoch]. */
    fun phaseAt(scheduledEpoch: Long, nowEpoch: Long): Phase {
        // No known time (a UI-only start): one full ring from now.
        if (scheduledEpoch <= 0) return Phase.Ring(1, nowEpoch + RING_MS)
        val elapsed = nowEpoch - scheduledEpoch
        if (elapsed >= TOTAL_MS) return Phase.Over
        if (elapsed < 0) return Phase.Ring(1, scheduledEpoch + RING_MS)
        val period = RING_MS + GAP_MS
        val index = (elapsed / period).toInt()
        val within = elapsed % period
        return if (within < RING_MS) {
            Phase.Ring(index + 1, ringStart(scheduledEpoch, index + 1) + RING_MS)
        } else {
            Phase.Gap(index + 2, ringStart(scheduledEpoch, index + 2))
        }
    }

    /** Still worth re-arming after a reboot: the cycle has not run out. */
    fun isLive(scheduledEpoch: Long, nowEpoch: Long): Boolean =
        scheduledEpoch + TOTAL_MS > nowEpoch
}
