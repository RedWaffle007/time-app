package com.timeapp.time_app.reminders

import android.content.Intent
import java.io.File
import java.security.MessageDigest

/**
 * A voice-note alarm's expected audio (item 32c-2): the app-private file the
 * target's phone downloaded, and the size + SHA-256 it must match. Travels
 * with the armed alarm (extras + the reboot store) exactly like the headline.
 */
data class VoiceAlarmSpec(val path: String, val sha256: String, val sizeBytes: Long) {
    fun putInto(intent: Intent, prefix: String): Intent = intent
        .putExtra("${prefix}voice_path", path)
        .putExtra("${prefix}voice_sha256", sha256)
        .putExtra("${prefix}voice_size", sizeBytes)

    companion object {
        fun from(intent: Intent?, prefix: String): VoiceAlarmSpec? = of(
            intent?.getStringExtra("${prefix}voice_path"),
            intent?.getStringExtra("${prefix}voice_sha256"),
            intent?.getLongExtra("${prefix}voice_size", 0L) ?: 0L,
        )

        /** A spec only when every part is present and well-formed. */
        fun of(path: String?, sha256: String?, sizeBytes: Long): VoiceAlarmSpec? {
            if (path.isNullOrBlank() || !path.startsWith("/") || !path.endsWith(".m4a")) return null
            if (sha256 == null || !Regex("^[0-9a-f]{64}$").matches(sha256)) return null
            if (sizeBytes <= 0 || sizeBytes > VoiceAlarmPolicy.MAX_BYTES) return null
            return VoiceAlarmSpec(path, sha256, sizeBytes)
        }
    }
}

/** The ring-time rules for a voice note, pure and unit-tested. */
internal object VoiceAlarmPolicy {
    /**
     * Matches the Worker's and the rules' 256 KB (2026-10-05: 25-second notes
     * at 32 kbps). Lower and a valid note would fail here and ring the tone.
     */
    const val MAX_BYTES = 256L * 1024L

    /**
     * User-directed (2026-10-04): the note repeats for the whole ring,
     * whatever its length, with this pause between plays so it never runs
     * together. The ring cap ends it, exactly like the ringtone.
     */
    const val REPLAY_GAP_MS = 1_000L

    /**
     * The file is exactly the note the plan was approved with. Anything else —
     * missing, truncated, swapped — rings the normal ringtone instead.
     */
    fun verify(spec: VoiceAlarmSpec): Boolean = try {
        val file = File(spec.path)
        if (!file.isFile || file.length() != spec.sizeBytes) {
            false
        } else {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) } == spec.sha256
        }
    } catch (_: Throwable) {
        false
    }
}

/**
 * The real length of a voice note on this phone (2026-10-05), read from the
 * file itself. The ring queue times every play by it, so an alarm whose
 * length never arrived (an older push) is measured, not guessed.
 */
internal object VoiceNoteLength {
    /** Milliseconds, or 0 when the file is missing or unreadable. */
    fun measure(path: String): Long {
        if (!java.io.File(path).exists()) return 0L
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.takeIf { it > 0 } ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }
}
