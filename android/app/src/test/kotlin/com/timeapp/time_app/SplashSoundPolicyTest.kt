package com.timeapp.time_app

import org.junit.Assert.assertEquals
import org.junit.Test

class SplashSoundPolicyTest {
    @Test
    fun `clock ting stops at one and a half seconds`() {
        assertEquals(1_500L, SplashSoundPolicy.MAX_PLAYBACK_MS)
    }
}
