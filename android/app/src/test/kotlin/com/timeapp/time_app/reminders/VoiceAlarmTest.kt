package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/** Item 32c-2 (2026-09-26) + 2026-10-04: voice-note alarms at ring time. */
class VoiceAlarmTest {
    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun noteFile(bytes: ByteArray): File =
        File.createTempFile("note", ".m4a").apply { writeBytes(bytes) }

    @Test
    fun `a note repeats for the whole ring with a short pause (2026-10-04)`() {
        assertEquals(1_000L, VoiceAlarmPolicy.REPLAY_GAP_MS)
        // Must match the Worker's MAX_VOICE_BYTES and the rules' 262144, or a
        // valid 25-second note fails the ring-time check and rings the tone.
        assertEquals(262_144L, VoiceAlarmPolicy.MAX_BYTES)
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
        assertTrue(source.contains("!VoiceAlarmPolicy.verify(voice) || !startVoiceOnce(voice)"))
        assertTrue(source.contains("AlarmLifecycleStore.KIND_VOICE_FALLBACK"))
        // Voice plays on the ALARM stream, once per play: the ring queue
        // (2026-10-05) times every play, so the player never loops or
        // schedules its own replay.
        val voice = source.substringAfter("private fun startVoiceOnce").substringBefore("private fun recordVoiceFallback")
        assertTrue(voice.contains("setAudioAttributes(alarmAttributes())"))
        assertTrue(voice.contains("isLooping = false"))
        assertTrue(!voice.contains("postDelayed"))
        // Ending a segment releases the player.
        val end = source.substringAfter("private fun endSegment()").substringBefore("\n    }\n")
        assertTrue(end.contains("releasePlayer()"))
        val finish = source.substringAfter("private fun finish()").substringBefore("\n    }\n")
        assertTrue(finish.contains("releasePlayer()"))
    }

    @Test
    fun `the full-screen launch names the alarm, and every new ring wakes the screen (2026-10-05)`() {
        val source = File(
            "src/main/kotlin/com/timeapp/time_app/reminders/AlarmSoundService.kt",
        ).readText()
        val start = source.substringAfter("override fun onStartCommand").substringBefore("when (intent?.action)")
        // The item is known BEFORE the first (full-screen) notification posts.
        assertTrue(start.indexOf("launchItem = ") in 0 until start.indexOf("ensureForeground()"))
        // A ring for another alarm reposts under a new id, which re-fires the full-screen intent.
        val play = source.substringAfter("private fun play(").substringBefore("private fun startSound(")
        assertTrue(play.contains("repostForFullScreen()"))
        assertTrue(source.contains("ServiceCompat.startForeground(this, notifId, buildNotification(), type)"))
    }
}
