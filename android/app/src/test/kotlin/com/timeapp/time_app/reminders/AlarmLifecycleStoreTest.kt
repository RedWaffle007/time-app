package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AlarmLifecycleStoreTest {
    @Test
    fun `recording the same durable event is idempotent`() {
        val event = AlarmLifecycleStore.Event("item-a", 1000L, "timeout")
        val events = AlarmLifecycleStore.upsert(
            AlarmLifecycleStore.upsert(emptyList(), event),
            event,
        )

        assertEquals(listOf(event), events)
    }

    @Test
    fun `processing flags survive an upsert-free lifecycle`() {
        val event = AlarmLifecycleStore.Event("item-a", 1000L, "timeout")
            .copy(
                outcomeRecorded = true,
                notificationDelivered = true,
                reviewed = true,
                reviewChoice = "done",
                reviewNotificationDelivered = true,
            )

        assertTrue(event.outcomeRecorded)
        assertTrue(event.notificationDelivered)
        assertTrue(event.reviewed)
        assertEquals("done", event.reviewChoice)
        assertTrue(event.reviewNotificationDelivered)
        assertTrue(AlarmLifecycleStore.withoutKey(listOf(event), event.key).isEmpty())
    }

    @Test
    fun `duplicate native record cannot erase review progress`() {
        val reviewed = AlarmLifecycleStore.Event("item-a", 1000L, "timeout").copy(
            outcomeRecorded = true,
            notificationDelivered = true,
            reviewed = true,
            reviewChoice = "done",
            reviewNotificationDelivered = true,
        )

        val replayed = AlarmLifecycleStore.upsert(
            listOf(reviewed),
            AlarmLifecycleStore.Event("item-a", 1000L, "timeout"),
        ).single()

        assertEquals(reviewed, replayed)
    }
}
