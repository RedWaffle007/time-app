package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

class RingCyclePolicyTest {
    private val due = 1_790_000_000_000L
    private val min = 60_000L

    @Test
    fun `ring 5, quiet 5, three times, missed at 25 minutes (2026-10-04)`() {
        assertEquals(25 * min, RingCyclePolicy.TOTAL_MS)
        assertEquals(RingCyclePolicy.Phase.Ring(1, due + 5 * min), RingCyclePolicy.phaseAt(due, due))
        assertEquals(RingCyclePolicy.Phase.Ring(1, due + 5 * min), RingCyclePolicy.phaseAt(due, due + 5 * min - 1))
        assertEquals(RingCyclePolicy.Phase.Gap(2, due + 10 * min), RingCyclePolicy.phaseAt(due, due + 5 * min))
        assertEquals(RingCyclePolicy.Phase.Ring(2, due + 15 * min), RingCyclePolicy.phaseAt(due, due + 10 * min))
        assertEquals(RingCyclePolicy.Phase.Gap(3, due + 20 * min), RingCyclePolicy.phaseAt(due, due + 17 * min))
        assertEquals(RingCyclePolicy.Phase.Ring(3, due + 25 * min), RingCyclePolicy.phaseAt(due, due + 20 * min))
        assertEquals(RingCyclePolicy.Phase.Ring(3, due + 25 * min), RingCyclePolicy.phaseAt(due, due + 25 * min - 1))
        assertEquals(RingCyclePolicy.Phase.Over, RingCyclePolicy.phaseAt(due, due + 25 * min))
        assertEquals(RingCyclePolicy.Phase.Over, RingCyclePolicy.phaseAt(due, due + 60 * min))
    }

    @Test
    fun `a late delivery joins the ring it lands in, not a fresh full ring`() {
        // 3 minutes late: ring 1, ending at its own 5 minutes, not 8.
        assertEquals(RingCyclePolicy.Phase.Ring(1, due + 5 * min), RingCyclePolicy.phaseAt(due, due + 3 * min))
    }

    @Test
    fun `early delivery is ring 1, and an unknown time rings one full ring`() {
        assertEquals(RingCyclePolicy.Phase.Ring(1, due + 5 * min), RingCyclePolicy.phaseAt(due, due - 5_000))
        assertEquals(RingCyclePolicy.Phase.Ring(1, due + 5 * min), RingCyclePolicy.phaseAt(0L, due))
    }

    @Test
    fun `rings start at 0, 10 and 20 minutes`() {
        assertEquals(due, RingCyclePolicy.ringStart(due, 1))
        assertEquals(due + 10 * min, RingCyclePolicy.ringStart(due, 2))
        assertEquals(due + 20 * min, RingCyclePolicy.ringStart(due, 3))
    }

    @Test
    fun `the Dart cycle uses the same numbers`() {
        val dart = java.io.File(
            "../../lib/features/reminders/application/ring_cycle.dart",
        ).readText()
        assertTrue(dart.contains("kRingLength = Duration(minutes: 5)"))
        assertTrue(dart.contains("kRingGap = Duration(minutes: 5)"))
        assertTrue(dart.contains("kRingCount = 3"))
        assertTrue(dart.contains("kRingCycleTotal = Duration(minutes: 25)"))
    }
}
