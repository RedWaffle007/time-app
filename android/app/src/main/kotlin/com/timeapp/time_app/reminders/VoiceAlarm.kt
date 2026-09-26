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
     * User-directed (F5, 2026-09-26): shorter notes play more often. 15–20 s →
     * 3, 10–15 s → 4, 5–10 s → 5, under 5 s → 6. An exact boundary takes the
     * LONGER band's count (15.0 s → 3). Mirrored by `voicePlaysFor` in Dart.
     */
    fun playsFor(durationMs: Int): Int = when {
        durationMs >= 15_000 -> 3
        durationMs >= 10_000 -> 4
        durationMs >= 5_000 -> 5
        else -> 6
    }

    const val MAX_BYTES = 256L * 1024L

    /** Ring for every play plus a second of slack, never more. */
    fun capMs(durationMs: Int): Long = playsFor(durationMs) * durationMs.toLong() + 1_000L

    /** After [completedPlays] finished plays of a [durationMs] note, play again? */
    fun playAgain(completedPlays: Int, durationMs: Int): Boolean =
        completedPlays < playsFor(durationMs)

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
