package com.timeapp.time_app

import org.junit.Assert.assertEquals
import org.junit.Test

class CelebrationSoundPolicyTest {
    @Test
    fun `celebration sound is capped at one and a half seconds`() {
        assertEquals(1_500L, CelebrationSoundPolicy.DURATION_MS)
    }
}
