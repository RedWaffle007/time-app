package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AlarmDeliveryStoreTest {
    private fun pending(
        id: Int,
        itemId: String,
        at: Long,
        exact: Boolean = true,
    ) = AlarmDeliveryStore.Pending(id, itemId, at, exact)

    private val voice = VoiceAlarmSpec("/data/note.m4a", "a".repeat(64), 90_000L)

    @Test
    fun `arming the same notification id replaces rather than duplicates it`() {
        val original = pending(7, "old-item", 1_000L)
        val replacement = pending(7, "new-item", 2_000L, exact = false)

        val result = AlarmDeliveryStore.upsert(listOf(original), replacement)

        assertEquals(listOf(replacement), result)
    }

    @Test
    fun `re-arming an alarm already in the queue keeps its counted rings`() {
        val ringing = pending(7, "item", 1_000L).copy(ringsDone = 1, lastRingAt = 1_000L)
        val rearmed = pending(7, "item", 1_000L).copy(headline = "New sentence")

        val result = AlarmDeliveryStore.upsert(listOf(ringing), rearmed).single()

        assertEquals("New sentence", result.headline)
        assertEquals(1, result.ringsDone)
        assertEquals(1_000L, result.lastRingAt)
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
    fun `the queue state, sentence and voice note survive a reboot`() {
        val row = AlarmDeliveryStore.Pending(
            5, "item", 1_000L, true, "Test Planner sent you a voice alarm", voice, 21_000L,
            ringsDone = 2, lastRingAt = 611_000L,
        )
        val decoded = AlarmDeliveryStore.decode(AlarmDeliveryStore.encode(listOf(row)))
        assertEquals(listOf(row), decoded)
    }

    @Test
    fun `rows written before the queue decode as never rung`() {
        val legacy = AlarmDeliveryStore.decode(
            "[{\"id\":1,\"itemId\":\"a\",\"scheduledEpoch\":7,\"exact\":true,\"triggerEpoch\":9}]",
        ).single()
        assertEquals(0, legacy.ringsDone)
        assertEquals(0L, legacy.lastRingAt)
        assertEquals("", legacy.headline)
    }

    @Test
    fun `counted rings are written back, and an alarm whose rings are done leaves`() {
        val a = pending(1, "a", 1_000L)
        val b = pending(2, "b", 2_000L).copy(ringsDone = 2, lastRingAt = 5_000L)
        val c = pending(3, "c", 3_000L)
        val alarms = listOf(
            a.toAlarm().copy(ringsDone = 1, lastRingAt = 1_000L),
            b.toAlarm().copy(ringsDone = 3, lastRingAt = 9_000L),
        )

        val result = AlarmDeliveryStore.withRings(listOf(a, b, c), alarms)

        assertEquals(listOf("a", "c"), result.map { it.itemId })
        assertEquals(1, result[0].ringsDone)
        assertEquals(c, result[1])
    }

    @Test
    fun `a plan never rung a day after its time is stale, repeats never are`() {
        val day = AlarmDeliveryStore.STALE_FIRST_RING_MS
        val now = 10 * day
        val stale = pending(1, "stale", now - day - 1)
        val recent = pending(2, "recent", now - day + 1)
        val repeating = pending(3, "repeating", now - 3 * day).copy(ringsDone = 1, lastRingAt = now - 3 * day)

        assertEquals(listOf(stale), AlarmDeliveryStore.stale(listOf(stale, recent, repeating), now))
    }

    @Test
    fun `a voice note's length reaches the queue, or the longest when unknown`() {
        val known = AlarmDeliveryStore.Pending(1, "a", 0L, true, "", voice, 12_000L)
        val unknown = AlarmDeliveryStore.Pending(2, "b", 0L, true, "", voice)
        assertEquals(12_000L, known.toAlarm().voiceMs)
        assertEquals(AlarmDeliveryStore.DEFAULT_VOICE_MS, unknown.toAlarm().voiceMs)
        assertNull(pending(3, "c", 0L).toAlarm().voiceMs)
    }

    @Test
    fun `a voice note with no known length is measured once and recorded`() {
        val unknown = AlarmDeliveryStore.Pending(1, "a", 0L, true, "", voice)
        val known = AlarmDeliveryStore.Pending(2, "b", 0L, true, "", voice, 9_000L)
        val notYetDownloaded = AlarmDeliveryStore.Pending(3, "c", 0L, true, "", voice.copy(path = "/data/later.m4a"))
        val measured = mutableListOf<String>()
        val result = AlarmDeliveryStore.withMeasuredVoices(listOf(unknown, known, notYetDownloaded, pending(4, "d", 0L))) {
            measured += it
            if (it == voice.path) 21_400L else 0L
        }
        assertEquals(listOf(21_400L, 9_000L, 0L, 0L), result.map { it.voiceMs })
        // Known lengths and tone alarms are never measured.
        assertEquals(listOf(voice.path, "/data/later.m4a"), measured)
    }
}
