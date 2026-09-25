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

        val restored = AlarmDeliveryStore.futureOnly(listOf(armed), nowEpoch = 1_000L)

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
    fun `reboot restores only strictly future alarms and preserves precision`() {
        val past = pending(1, "past", 999L)
        val dueNow = pending(2, "now", 1_000L)
        val exactFuture = pending(3, "exact", 1_001L)
        val inexactFuture = pending(4, "inexact", 2_000L, exact = false)

        val result = AlarmDeliveryStore.futureOnly(
            listOf(past, dueNow, exactFuture, inexactFuture),
            nowEpoch = 1_000L,
        )

        assertEquals(listOf(exactFuture, inexactFuture), result)
        assertTrue(result.first().exact)
        assertFalse(result.last().exact)
    }
}
