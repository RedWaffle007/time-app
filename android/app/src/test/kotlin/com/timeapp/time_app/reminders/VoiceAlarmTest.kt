package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/** Item 32c-2 + F5 (2026-09-26): voice-note alarms at ring time. */
class VoiceAlarmTest {
    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun noteFile(bytes: ByteArray): File =
        File.createTempFile("note", ".m4a").apply { writeBytes(bytes) }

    @Test
    fun `plays scale with length - boundaries take the longer band`() {
        val cases = mapOf(
            20_500 to 3, 20_000 to 3, 15_001 to 3, 15_000 to 3,
            14_999 to 4, 10_000 to 4,
            9_999 to 5, 5_000 to 5,
            4_999 to 6, 1_000 to 6, 1 to 6,
        )
        for ((ms, plays) in cases) assertEquals("$ms ms", plays, VoiceAlarmPolicy.playsFor(ms))
    }

    @Test
    fun `play again until the band's count, then stop`() {
        for ((ms, plays) in mapOf(18_000 to 3, 12_000 to 4, 7_000 to 5, 2_000 to 6)) {
            for (done in 0 until plays) assertTrue("$ms after $done", VoiceAlarmPolicy.playAgain(done, ms))
            assertFalse("$ms after $plays", VoiceAlarmPolicy.playAgain(plays, ms))
            assertFalse(VoiceAlarmPolicy.playAgain(plays + 1, ms))
        }
    }

    @Test
    fun `the cap is plays x duration plus a second, inside the wake lock`() {
        assertEquals(26_000L, VoiceAlarmPolicy.capMs(5_000)) // 5 s x 5
        assertEquals(30_994L, VoiceAlarmPolicy.capMs(4_999)) // 4.999 s x 6
        assertEquals(61_000L, VoiceAlarmPolicy.capMs(20_000)) // 20 s x 3
        assertEquals(49_000L, VoiceAlarmPolicy.capMs(12_000)) // 12 s x 4
        // Every length the Worker accepts (1 s .. 20.5 s) ends before the
        // wake lock (MAX_RING_DURATION_MS + 5 s) is released.
        for (ms in 1_000..20_500 step 1) {
            assertTrue("$ms", VoiceAlarmPolicy.capMs(ms) < AlarmSoundPolicy.MAX_RING_DURATION_MS + 5_000L)
        }
    }

    @Test
    fun `only the exact approved file is played`() {
        val bytes = ByteArray(4096) { (it % 251).toByte() }
        val file = noteFile(bytes)
        try {
            val spec = VoiceAlarmSpec(file.absolutePath, sha(bytes), bytes.size.toLong())
            assertTrue(VoiceAlarmPolicy.verify(spec))
            // Wrong size, wrong hash, missing file → the ringtone, never silence.
            assertFalse(VoiceAlarmPolicy.verify(spec.copy(sizeBytes = 10)))
            assertFalse(VoiceAlarmPolicy.verify(spec.copy(sha256 = "0".repeat(64))))
            assertFalse(VoiceAlarmPolicy.verify(spec.copy(path = file.absolutePath + ".gone.m4a")))
            file.writeBytes(bytes.copyOf(4095) + byteArrayOf(9)) // same size, altered
            assertFalse(VoiceAlarmPolicy.verify(spec))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a spec is only built from complete, well-formed parts`() {
        val sha = "a".repeat(64)
        assertEquals(VoiceAlarmSpec("/d/x.m4a", sha, 10), VoiceAlarmSpec.of("/d/x.m4a", sha, 10))
        assertNull(VoiceAlarmSpec.of(null, sha, 10))
        assertNull(VoiceAlarmSpec.of("relative.m4a", sha, 10))
        assertNull(VoiceAlarmSpec.of("/d/x.mp3", sha, 10))
        assertNull(VoiceAlarmSpec.of("/d/x.m4a", "ABC", 10))
        assertNull(VoiceAlarmSpec.of("/d/x.m4a", sha, 0))
        assertNull(VoiceAlarmSpec.of("/d/x.m4a", sha, VoiceAlarmPolicy.MAX_BYTES + 1))
    }

    @Test
    fun `the voice note survives a reboot in the delivery store`() {
        val voice = VoiceAlarmSpec("/data/voice-notes/i1.m4a", "b".repeat(64), 9000)
        val items = listOf(
            AlarmDeliveryStore.Pending(1, "i1", 1_000L, true, "Test Planner planned Walk for you", voice),
            AlarmDeliveryStore.Pending(2, "i2", 2_000L, false, "You planned Read"),
        )
        val restored = AlarmDeliveryStore.decode(AlarmDeliveryStore.encode(items))
        assertEquals(items, restored)
        // A store written before voice notes existed still loads, voice-less.
        val legacy = """[{"id":3,"itemId":"i3","scheduledEpoch":5,"exact":true,"headline":"h"}]"""
        assertEquals(
            listOf(AlarmDeliveryStore.Pending(3, "i3", 5L, true, "h", null)),
            AlarmDeliveryStore.decode(legacy),
        )
        assertEquals(emptyList<AlarmDeliveryStore.Pending>(), AlarmDeliveryStore.decode("not json"))
    }

    @Test
    fun `the ringing service verifies before playing and records a fallback`() {
        val source = File(
            "src/main/kotlin/com/timeapp/time_app/reminders/AlarmSoundService.kt",
        ).readText()
        assertTrue(source.contains("VoiceAlarmPolicy.verify(voice) && startVoiceNow(voice)"))
        assertTrue(source.contains("AlarmLifecycleStore.KIND_VOICE_FALLBACK"))
        // Voice plays on the ALARM stream, never looping on its own.
        val voice = source.substringAfter("private fun startVoiceNow").substringBefore("private fun recordVoiceFallback")
        assertTrue(voice.contains("setAudioAttributes(alarmAttributes())"))
        assertTrue(voice.contains("isLooping = false"))
    }
}
