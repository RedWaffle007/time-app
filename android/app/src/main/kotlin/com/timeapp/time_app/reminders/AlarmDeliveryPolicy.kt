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
 * R5 (2026-10-02, user-directed: "we cannot tolerate even a single minute
 * delay"). An alarm delivered more than one full ring after its time does not
 * ring at all: it ends as missed, exactly like an unanswered ring. Exact
 * delivery lands within a second; this only catches an OS that held it back.
 */
internal object AlarmLatenessPolicy {
    const val MAX_LATE_MS = 60_000L

    fun isTooLate(scheduledEpoch: Long, nowEpoch: Long): Boolean =
        scheduledEpoch > 0 && nowEpoch - scheduledEpoch > MAX_LATE_MS
}
