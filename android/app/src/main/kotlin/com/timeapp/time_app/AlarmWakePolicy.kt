package com.timeapp.time_app

/** Pure alarm-launch classification; kept Android-free for plain JVM tests. */
internal object AlarmLaunchPolicy {
    const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"

    fun isAlarmLaunch(action: String?, payload: String?): Boolean =
        action == SELECT_NOTIFICATION && !payload.isNullOrBlank()
}

/** Pure hardware-key gate used by MainActivity before consuming Volume Down. */
internal object AlarmHardwareKeyPolicy {
    fun shouldSilence(
        keyCode: Int,
        action: Int,
        repeatCount: Int,
        ringing: Boolean,
        volumeDownKeyCode: Int,
        actionDown: Int,
    ): Boolean =
        ringing &&
            keyCode == volumeDownKeyCode &&
            action == actionDown &&
            repeatCount == 0
}

/** The window side effects needed to wake without unlocking the device. */
internal interface AlarmWakeWindowHost {
    fun setModern(showWhenLocked: Boolean, turnScreenOn: Boolean)
    fun setLegacy(enabled: Boolean)
    fun setKeepScreenOn(enabled: Boolean)
}

/** Applies and clears the wake contract symmetrically across Android versions. */
internal class AlarmWakeWindowController(
    private val sdkInt: Int,
    private val host: AlarmWakeWindowHost,
) {
    companion object {
        const val MODERN_API = 27
    }

    var enabled: Boolean = false
        private set

    fun setEnabled(value: Boolean) {
        if (sdkInt >= MODERN_API) {
            host.setModern(showWhenLocked = value, turnScreenOn = value)
        } else {
            host.setLegacy(value)
        }
        host.setKeepScreenOn(value)
        enabled = value
    }
}
