package com.timeapp.time_app.voice

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class VoicePreviewPolicyTest {
    @Test
    fun `only an existing non-empty m4a file path is playable`() {
        val file = File.createTempFile("voice", ".m4a").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val empty = File.createTempFile("voice", ".m4a")
        val wrong = File.createTempFile("voice", ".mp3").apply { writeBytes(byteArrayOf(1)) }
        try {
            assertTrue(VoicePreviewPolicy.isPlayablePath(file.absolutePath))
            assertFalse(VoicePreviewPolicy.isPlayablePath(empty.absolutePath))
            assertFalse(VoicePreviewPolicy.isPlayablePath(wrong.absolutePath))
            assertFalse(VoicePreviewPolicy.isPlayablePath(null))
            assertFalse(VoicePreviewPolicy.isPlayablePath(""))
            assertFalse(VoicePreviewPolicy.isPlayablePath("https://example.com/a.m4a"))
            assertFalse(VoicePreviewPolicy.isPlayablePath("content://media/a.m4a"))
            assertFalse(VoicePreviewPolicy.isPlayablePath("/no/such/file.m4a"))
        } finally {
            file.delete(); empty.delete(); wrong.delete()
        }
    }
}
