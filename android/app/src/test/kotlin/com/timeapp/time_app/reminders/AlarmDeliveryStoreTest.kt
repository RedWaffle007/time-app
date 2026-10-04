package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlarmDeliveryStoreTest {
    private fun pending(
        id: Int,
        itemId: String,
        at: Long,
        exact: Boolean = true,
    ) = AlarmDeliveryStore.Pending(id, itemId, at, exact)

    @Test
    fun `arming the same notification id replaces rather than duplicates it`() {
        val original = pending(7, "old-item", 1_000L)
        val replacement = pending(7, "new-item", 2_000L, exact = false)

        val result = AlarmDeliveryStore.upsert(listOf(original), replacement)

        assertEquals(listOf(replacement), result)
    }

    @Test
    fun `reboot re-arming keeps the alarm sentence`() {
        val armed = AlarmDeliveryStore.Pending(
            7,
            "item-a",
            2_000L,
            true,
            "Test Planner planned Walk for you",
        )

        val restored = AlarmDeliveryStore.stillLive(listOf(armed), nowEpoch = 1_000L)

        assertEquals("Test Planner planned Walk for you", restored.single().headline)
        // Rows written before the sentence existed still restore.
        assertEquals("", pending(8, "legacy", 2_000L).headline)
    }

    @Test
    fun `arming another id preserves both alarms`() {
        val first = pending(7, "item-a", 1_000L)
        val second = pending(8, "item-b", 2_000L)

        val result = AlarmDeliveryStore.upsert(listOf(first), second)

        assertEquals(listOf(first, second), result)
    }

    @Test
    fun `cancel removes only the matching id`() {
        val first = pending(7, "item-a", 1_000L)
        val second = pending(8, "item-b", 2_000L)

        val result = AlarmDeliveryStore.withoutId(listOf(first, second), 7)

        assertEquals(listOf(second), result)
    }

    @Test
    fun `reboot restores every alarm whose ring cycle is still running`() {
        val now = 100_000_000L
        val over = pending(1, "over", now - RingCyclePolicy.TOTAL_MS)
        val midCycle = pending(2, "mid", now - 12 * 60_000L)
        val exactFuture = pending(3, "exact", now + 1)
        val inexactFuture = pending(4, "inexact", now + 2_000L, exact = false)

        val result = AlarmDeliveryStore.stillLive(
            listOf(over, midCycle, exactFuture, inexactFuture),
            nowEpoch = now,
        )

        assertEquals(listOf(midCycle, exactFuture, inexactFuture), result)
        assertTrue(result[1].exact)
        assertFalse(result.last().exact)
    }

    @Test
    fun `a later ring keeps the plan's time and its own trigger through a reboot`() {
        val ring2 = AlarmDeliveryStore.Pending(
            5, "item", 1_000L, true, "h", null, triggerEpoch = 601_000L,
        )
        val decoded = AlarmDeliveryStore.decode(AlarmDeliveryStore.encode(listOf(ring2)))
        assertEquals(1_000L, decoded.single().scheduledEpoch)
        assertEquals(601_000L, decoded.single().triggerEpoch)
        // Rows written before triggers existed fire at the plan's time.
        val legacy = AlarmDeliveryStore.decode(
            "[{\"id\":1,\"itemId\":\"a\",\"scheduledEpoch\":7,\"exact\":true}]",
        )
        assertEquals(7L, legacy.single().triggerEpoch)
    }
}
