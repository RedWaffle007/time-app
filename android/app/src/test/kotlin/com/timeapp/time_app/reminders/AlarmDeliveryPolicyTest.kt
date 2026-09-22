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
    fun `modern Android uses idle-safe exact and fallback calls`() {
        assertEquals(
            AlarmDeliveryMode.EXACT_ALLOW_IDLE,
            alarmDeliveryMode(exact = true, sdkInt = 23),
        )
        assertEquals(
            AlarmDeliveryMode.INEXACT_ALLOW_IDLE,
            alarmDeliveryMode(exact = false, sdkInt = 23),
        )
    }

    @Test
    fun `pre-Marshmallow keeps the equivalent non-idle calls`() {
        assertEquals(
            AlarmDeliveryMode.EXACT,
            alarmDeliveryMode(exact = true, sdkInt = 22),
        )
        assertEquals(
            AlarmDeliveryMode.INEXACT,
            alarmDeliveryMode(exact = false, sdkInt = 22),
        )
    }
}
