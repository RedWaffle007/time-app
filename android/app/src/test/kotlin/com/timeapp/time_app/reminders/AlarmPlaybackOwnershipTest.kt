package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AlarmPlaybackOwnershipTest {
    @Test
    fun `a repeated native delivery remains one owner`() {
        val ownership = AlarmPlaybackOwnership()

        ownership.claimNotification(41, "item-a")
        ownership.claimNotification(41, "item-a")
        ownership.releaseNotification(41)

        assertFalse(ownership.hasOwners)
    }

    @Test
    fun `the UI handoff survives notification cancellation`() {
        val ownership = AlarmPlaybackOwnership()

        ownership.claimNotification(41, "item-a")
        ownership.claimUi("item-a")
        ownership.releaseNotification(41)

        assertTrue(ownership.hasOwners)
        assertEquals("item-a", ownership.latestUiItem())

        ownership.releaseItem("item-a")
        assertFalse(ownership.hasOwners)
    }

    @Test
    fun `dismissing one item does not silence another active alarm`() {
        val ownership = AlarmPlaybackOwnership()
        ownership.claimNotification(41, "item-a")
        ownership.claimNotification(42, "item-b")

        ownership.releaseItem("item-a")

        assertTrue(ownership.hasOwners)
        assertEquals(42 to "item-b", ownership.latestNotification())
    }

    @Test
    fun `stop all clears both ownership routes`() {
        val ownership = AlarmPlaybackOwnership()
        ownership.claimNotification(41, "item-a")
        ownership.claimUi("item-a")

        ownership.clear()

        assertFalse(ownership.hasOwners)
        assertNull(ownership.latestNotification())
        assertNull(ownership.latestUiItem())
    }

    @Test
    fun `the playback policy loops a complete tone for one 5-minute ring`() {
        assertTrue(AlarmSoundPolicy.LOOP_WHOLE_TONE)
        assertEquals(5 * 60_000L, AlarmSoundPolicy.MAX_RING_DURATION_MS)
    }

    @Test
    fun `timeout sees every item that still owns playback`() {
        val ownership = AlarmPlaybackOwnership()
        ownership.claimNotification(41, "item-a")
        ownership.claimUi("item-a")
        ownership.claimNotification(42, "item-b")

        assertEquals(setOf("item-a", "item-b"), ownership.itemIds())
        assertEquals(setOf(41, 42), ownership.notificationIds())
    }

    @Test
    fun `an existing player is never restarted by another start command`() {
        assertTrue(AlarmSoundPolicy.shouldStartPlayer(playerAlreadyExists = false))
        assertFalse(AlarmSoundPolicy.shouldStartPlayer(playerAlreadyExists = true))
    }
}

/** 2026-10-04: several alarms in a ring at once. */
class AlarmRingSetTest {
    @Test
    fun `the newest alarm has the speaker, the one before takes it back`() {
        val rings = AlarmRingSet()
        rings.add("a", 100L)
        rings.add("b", 200L)
        rings.add("c", 300L)
        assertEquals("c", rings.sounding())
        assertEquals(listOf("a", "b", "c"), rings.ids())

        assertTrue(rings.remove("c"))
        assertEquals("b", rings.sounding())
        // Removing one that is not sounding leaves the speaker where it is.
        assertTrue(rings.remove("a"))
        assertEquals("b", rings.sounding())
        assertFalse(rings.remove("a"))
    }

    @Test
    fun `each alarm keeps its own end, a repeat start changes nothing`() {
        val rings = AlarmRingSet()
        rings.add("a", 100L)
        rings.add("b", 200L)
        rings.add("a", 999L)
        assertEquals(100L, rings.endsAt("a"))
        assertEquals("a repeat does not take the speaker", "b", rings.sounding())
    }

    @Test
    fun `notification owners can be found per alarm`() {
        val ownership = AlarmPlaybackOwnership()
        ownership.claimNotification(1, "a")
        ownership.claimNotification(2, "b")
        assertEquals("a", ownership.itemForNotification(1))
        assertEquals(setOf(2), ownership.notificationIdsOf("b"))
        assertNull(ownership.itemForNotification(3))
    }
}
