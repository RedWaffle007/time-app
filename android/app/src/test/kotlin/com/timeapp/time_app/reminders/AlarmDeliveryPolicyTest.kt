package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class AlarmDeliveryPolicyTest {
    @Test
    fun `one notification id always maps to one pending-intent identity`() {
        val id = 91_337

        assertEquals(
            AlarmDeliveryIdentity.requestCode(id),
            AlarmDeliveryIdentity.requestCode(id),
        )
        assertEquals(
            AlarmDeliveryIdentity.action(id),
            AlarmDeliveryIdentity.action(id),
        )
        assertNotEquals(
            AlarmDeliveryIdentity.requestCode(id),
            AlarmDeliveryIdentity.requestCode(id + 1),
        )
        assertNotEquals(
            AlarmDeliveryIdentity.action(id),
            AlarmDeliveryIdentity.action(id + 1),
        )
    }

    @Test
    fun `exact delivery uses alarm-clock priority and fallback remains idle-safe`() {
        assertEquals(
            AlarmDeliveryMode.ALARM_CLOCK,
            alarmDeliveryMode(exact = true, sdkInt = 23),
        )
        assertEquals(
            AlarmDeliveryMode.INEXACT_ALLOW_IDLE,
            alarmDeliveryMode(exact = false, sdkInt = 23),
        )
    }

    @Test
    fun `pre-Marshmallow keeps alarm-clock exactness and basic fallback`() {
        assertEquals(
            AlarmDeliveryMode.ALARM_CLOCK,
            alarmDeliveryMode(exact = true, sdkInt = 22),
        )
        assertEquals(
            AlarmDeliveryMode.INEXACT,
            alarmDeliveryMode(exact = false, sdkInt = 22),
        )
    }
}

class AlarmLatenessPolicyTest {
    private val due = 1_790_000_000_000L

    @Test
    fun `on time and up to one full ring late still rings (R5)`() {
        assertEquals(false, AlarmLatenessPolicy.isTooLate(due, due))
        assertEquals(false, AlarmLatenessPolicy.isTooLate(due, due + 620))
        assertEquals(false, AlarmLatenessPolicy.isTooLate(due, due + 60_000))
        // Early delivery is never "late".
        assertEquals(false, AlarmLatenessPolicy.isTooLate(due, due - 5_000))
    }

    @Test
    fun `more than one minute late never rings, it becomes missed (R5)`() {
        assertEquals(true, AlarmLatenessPolicy.isTooLate(due, due + 60_001))
        assertEquals(true, AlarmLatenessPolicy.isTooLate(due, due + 110_000))
        assertEquals(true, AlarmLatenessPolicy.isTooLate(due, due + 3_600_000))
    }

    @Test
    fun `an alarm with no recorded time is not treated as late`() {
        assertEquals(false, AlarmLatenessPolicy.isTooLate(0L, due))
    }
}
