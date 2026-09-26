package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regressions from the 2026-09-25 device pass. */
class AlarmSoundPolicyTest {
    @Test
    fun `alarms have no ting - the ting belongs to app start only`() {
        // User-directed 2026-09-26: the ringtone (or, later, the voice note)
        // starts the moment the alarm fires. The policy no longer has any
        // ting lead to wait for.
        val members = AlarmSoundPolicy::class.java.declaredFields.map { it.name } +
            AlarmSoundPolicy::class.java.declaredMethods.map { it.name }
        assertFalse(members.any { it.contains("TING", ignoreCase = true) })
        assertFalse(members.any { it.contains("ringtoneDelay", ignoreCase = true) })
    }

    @Test
    fun `the alarm service never loads the ting sound`() {
        val source = java.io.File(
            "src/main/kotlin/com/timeapp/time_app/reminders/AlarmSoundService.kt",
        ).readText()
        assertFalse(source.contains("R.raw.tick"))
        assertFalse(source.contains("tingPlayer"))
        // The splash still owns the ting.
        val splash = java.io.File(
            "src/main/kotlin/com/timeapp/time_app/SplashSound.kt",
        ).readText()
        assertTrue(splash.contains("R.raw.tick"))
    }

    @Test
    fun `a ringing player counts as playing, so a second start cannot restart it`() {
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
