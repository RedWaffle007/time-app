package com.timeapp.time_app.voice

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Voice-note PREVIEW playback (item 32b): the planner after recording, the
 * target before approving. MEDIA stream, one player at a time, plays once.
 * Ring-time playback is AlarmSoundService's job on the alarm stream (32c) —
 * never this.
 */
class VoicePreviewChannel {
    private var channel: MethodChannel? = null
    private var player: MediaPlayer? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        val path = call.argument<String>("path")
                        if (!VoicePreviewPolicy.isPlayablePath(path)) {
                            result.error("bad-path", "No such voice note", null)
                        } else {
                            try {
                                play(path!!)
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(TAG, "preview failed: $e")
                                release()
                                result.error("play-failed", "Could not play", null)
                            }
                        }
                    }
                    "stop" -> {
                        release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun play(path: String) {
        release()
        player = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            setDataSource(path)
            isLooping = false
            setOnCompletionListener {
                release()
                channel?.invokeMethod("completed", null)
            }
            prepare()
            start()
        }
    }

    fun release() {
        player?.let {
            try {
                if (it.isPlaying) it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
    }

    companion object {
        const val CHANNEL = "time_app/voice_player"
        private const val TAG = "VoicePreview"
    }
}

/** Pure checks, unit-tested without a device. */
internal object VoicePreviewPolicy {
    /** Only an existing, app-written .m4a file; never a URL or content:// uri. */
    fun isPlayablePath(path: String?): Boolean {
        if (path.isNullOrBlank() || !path.startsWith("/") || !path.endsWith(".m4a")) {
            return false
        }
        val file = File(path)
        return file.isFile && file.length() > 0
    }
}
