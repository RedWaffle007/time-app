package com.timeapp.time_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SplashSoundPolicyTest {
    @Test
    fun `clock ting fades within the unchanged one and a half second deadline`() {
        assertEquals(1_500L, SplashSoundPolicy.MAX_PLAYBACK_MS)
        assertEquals(300L, SplashSoundPolicy.FADE_DURATION_MS)
        assertEquals(1_200L, SplashSoundPolicy.FADE_START_MS)
        assertEquals(1f, SplashSoundPolicy.volumeScale(1_200L))
        assertEquals(0.5f, SplashSoundPolicy.volumeScale(1_350L))
        assertEquals(0f, SplashSoundPolicy.volumeScale(1_500L))
    }

    @Test
    fun `fade volume is monotonic and clamped`() {
        val scales = (0L..1_800L step 30).map(SplashSoundPolicy::volumeScale)
        assertTrue(scales.zipWithNext().all { (before, after) -> after <= before })
        assertEquals(1f, SplashSoundPolicy.volumeScale(-100L))
        assertEquals(0f, SplashSoundPolicy.volumeScale(1_800L))
    }

    @Test
    fun `late preload uses only the original visual deadline`() {
        assertEquals(1_500L, SplashSoundPolicy.remainingMs(1_000L, 1_000L))
        assertEquals(200L, SplashSoundPolicy.remainingMs(1_000L, 2_300L))
        assertEquals(0L, SplashSoundPolicy.remainingMs(1_000L, 2_500L))
        assertEquals(0L, SplashSoundPolicy.remainingMs(1_000L, 3_000L))
    }
}
