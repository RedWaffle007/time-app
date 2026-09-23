package com.timeapp.time_app

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper

internal object CelebrationSoundPolicy {
    const val DURATION_MS = 1_500L
}

/** A short ascending completion flourish, bounded to the overlay's 1.5 seconds. */
class CelebrationSound(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val tone = ToneGenerator(AudioManager.STREAM_MUSIC, 90)
    private var generation = 0

    fun play() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        stop()
        val playGeneration = generation
        val notes = listOf(
            Triple(0L, ToneGenerator.TONE_DTMF_3, 170),
            Triple(230L, ToneGenerator.TONE_DTMF_6, 170),
            Triple(460L, ToneGenerator.TONE_DTMF_9, 190),
            Triple(720L, ToneGenerator.TONE_PROP_BEEP, 180),
            Triple(970L, ToneGenerator.TONE_PROP_ACK, 260),
            Triple(1_250L, ToneGenerator.TONE_PROP_ACK, 250),
        )
        for ((delay, toneType, duration) in notes) {
            handler.postDelayed({
                if (generation == playGeneration) tone.startTone(toneType, duration)
            }, delay)
        }
        handler.postDelayed({
            if (generation == playGeneration) tone.stopTone()
        }, CelebrationSoundPolicy.DURATION_MS)
    }

    fun stop() {
        generation += 1
        handler.removeCallbacksAndMessages(null)
        tone.stopTone()
    }
}
