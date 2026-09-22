package com.timeapp.time_app.reminders

/** Stable PendingIntent identity: re-arming one id updates, never duplicates. */
internal object AlarmDeliveryIdentity {
    fun requestCode(id: Int): Int = (id xor 0x41A2_6D37) and 0x7FFF_FFFF

    fun action(id: Int): String = "com.timeapp.time_app.ALARM_DELIVERY.$id"
}

/** The exact AlarmManager call selected for an arm request. */
internal enum class AlarmDeliveryMode {
    EXACT_ALLOW_IDLE,
    EXACT,
    INEXACT_ALLOW_IDLE,
    INEXACT,
}

internal fun alarmDeliveryMode(exact: Boolean, sdkInt: Int): AlarmDeliveryMode =
    when {
        exact && sdkInt >= 23 -> AlarmDeliveryMode.EXACT_ALLOW_IDLE
        exact -> AlarmDeliveryMode.EXACT
        sdkInt >= 23 -> AlarmDeliveryMode.INEXACT_ALLOW_IDLE
        else -> AlarmDeliveryMode.INEXACT
    }
