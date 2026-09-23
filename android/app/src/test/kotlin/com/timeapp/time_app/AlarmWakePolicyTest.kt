package com.timeapp.time_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlarmWakePolicyTest {
    @Test
    fun `only a local reminder notification is an alarm launch`() {
        assertTrue(AlarmLaunchPolicy.isAlarmLaunch("SELECT_NOTIFICATION", "item-a"))
        assertFalse(AlarmLaunchPolicy.isAlarmLaunch(null, "item-a"))
        assertFalse(AlarmLaunchPolicy.isAlarmLaunch("MAIN", "item-a"))
        assertFalse(AlarmLaunchPolicy.isAlarmLaunch("SELECT_NOTIFICATION", null))
        assertFalse(AlarmLaunchPolicy.isAlarmLaunch("SELECT_NOTIFICATION", "  "))
    }

    @Test
    fun `volume down is consumed once only while an alarm is ringing`() {
        val volumeDown = 25
        val volumeUp = 24
        val keyDown = 0
        val keyUp = 1

        assertTrue(
            AlarmHardwareKeyPolicy.shouldSilence(
                volumeDown,
                keyDown,
                0,
                true,
                volumeDown,
                keyDown,
            ),
        )
        assertFalse(
            AlarmHardwareKeyPolicy.shouldSilence(
                volumeDown,
                keyDown,
                0,
                false,
                volumeDown,
                keyDown,
            ),
        )
        assertFalse(
            AlarmHardwareKeyPolicy.shouldSilence(
                volumeDown,
                keyDown,
                1,
                true,
                volumeDown,
                keyDown,
            ),
        )
        assertFalse(
            AlarmHardwareKeyPolicy.shouldSilence(
                volumeDown,
                keyUp,
                0,
                true,
                volumeDown,
                keyDown,
            ),
        )
        assertFalse(
            AlarmHardwareKeyPolicy.shouldSilence(
                volumeUp,
                keyDown,
                0,
                true,
                volumeDown,
                keyDown,
            ),
        )
    }

    @Test
    fun `modern wake state enables and clears every window behavior`() {
        val host = RecordingWakeHost()
        val controller = AlarmWakeWindowController(35, host)

        controller.setEnabled(true)
        controller.setEnabled(false)

        assertEquals(listOf(true to true, false to false), host.modern)
        assertTrue(host.legacy.isEmpty())
        assertEquals(listOf(true, false), host.keepScreenOn)
        assertFalse(controller.enabled)
    }

    @Test
    fun `legacy wake state enables and clears flags symmetrically`() {
        val host = RecordingWakeHost()
        val controller = AlarmWakeWindowController(26, host)

        controller.setEnabled(true)
        controller.setEnabled(false)

        assertTrue(host.modern.isEmpty())
        assertEquals(listOf(true, false), host.legacy)
        assertEquals(listOf(true, false), host.keepScreenOn)
    }
}

private class RecordingWakeHost : AlarmWakeWindowHost {
    val modern = mutableListOf<Pair<Boolean, Boolean>>()
    val legacy = mutableListOf<Boolean>()
    val keepScreenOn = mutableListOf<Boolean>()

    override fun setModern(showWhenLocked: Boolean, turnScreenOn: Boolean) {
        modern += showWhenLocked to turnScreenOn
    }

    override fun setLegacy(enabled: Boolean) {
        legacy += enabled
    }

    override fun setKeepScreenOn(enabled: Boolean) {
        keepScreenOn += enabled
    }
}
