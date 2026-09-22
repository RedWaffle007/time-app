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
    fun `the playback policy loops a complete tone for at most ten minutes`() {
        assertTrue(AlarmSoundPolicy.LOOP_WHOLE_TONE)
        assertEquals(10L * 60L * 1000L, AlarmSoundPolicy.MAX_RING_DURATION_MS)
    }

    @Test
    fun `an existing player is never restarted by another start command`() {
        assertTrue(AlarmSoundPolicy.shouldStartPlayer(playerAlreadyExists = false))
        assertFalse(AlarmSoundPolicy.shouldStartPlayer(playerAlreadyExists = true))
    }
}
