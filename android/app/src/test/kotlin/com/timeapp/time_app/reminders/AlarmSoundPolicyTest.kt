package com.timeapp.time_app.reminders

import com.timeapp.time_app.SplashSoundPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regressions from the 2026-09-25 device pass. */
class AlarmSoundPolicyTest {
    @Test
    fun `the ringtone always starts exactly when the ting ends`() {
        assertEquals(AlarmSoundPolicy.TING_LEAD_MS, AlarmSoundPolicy.ringtoneDelayMs(true))
        // The ting's audible length, fade included — never cut early or overlapped.
        assertEquals(SplashSoundPolicy.MAX_PLAYBACK_MS, AlarmSoundPolicy.TING_LEAD_MS)
        // A missing ting must not delay the alarm at all.
        assertEquals(0L, AlarmSoundPolicy.ringtoneDelayMs(false))
        assertTrue(AlarmSoundPolicy.TING_LEAD_MS < AlarmSoundPolicy.MAX_RING_DURATION_MS)
    }

    @Test
    fun `a ting in progress counts as playing, so a second start cannot restart it`() {
        assertFalse(AlarmSoundPolicy.shouldStartPlayer(true))
        assertTrue(AlarmSoundPolicy.shouldStartPlayer(false))
    }

    @Test
    fun `the unlocked heads-up says who planned what`() {
        assertEquals(
            "Test Planner planned Walk for you",
            AlarmSoundPolicy.ringingTitle("Test Planner planned Walk for you"),
        )
        assertEquals("Alarm", AlarmSoundPolicy.ringingTitle(null))
        assertEquals("Alarm", AlarmSoundPolicy.ringingTitle("  "))
    }

    @Test
    fun `the missed-alarm notice names the task when it is known`() {
        assertEquals(
            "You didn't respond: Test Planner planned Walk for you",
            AlarmSoundPolicy.missedText("Test Planner planned Walk for you"),
        )
        assertEquals(
            "You didn't respond to a planned task.",
            AlarmSoundPolicy.missedText(null),
        )
        assertEquals("Missed alarm", AlarmSoundPolicy.MISSED_TITLE)
    }
}

class DuplicateNotificationPolicyTest {
    @Test
    fun `the scheduled duplicate is re-removed quickly and only while ringing`() {
        val rechecks = AlarmSoundPolicy.DUPLICATE_RECHECK_MS
        assertEquals(rechecks.sorted(), rechecks)
        assertTrue(rechecks.all { it in 1 until AlarmSoundPolicy.MAX_RING_DURATION_MS })
        // A late duplicate must not linger for long.
        assertTrue(rechecks.first() <= 500L)
    }
}
