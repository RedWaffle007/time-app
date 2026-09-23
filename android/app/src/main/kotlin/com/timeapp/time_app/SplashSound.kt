package com.timeapp.time_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Handler
import android.os.Looper

internal object SplashSoundPolicy {
    const val MAX_PLAYBACK_MS = 1_500L
}

/**
 * The cold-start pendulum-clock strike — ONE ring ("tunnn"), before the logo.
 *
 * A single synthesized wall-clock hour strike (`res/raw/tick.wav`, an original
 * sample, public domain), played ONCE at mount. No loop or fade; playback is
 * capped at 1.5 seconds so its tail ends with the loading surface.
 *
 * Native because it owns the mute check and the preload. Constructed in
 * [MainActivity]'s engine config so the sample is ready before the splash
 * mounts; a [pendingPlay] latch covers the case where the load has not finished
 * by the time `play` is called.
 */
class SplashSound(private val context: Context) {

    private val soundPool: SoundPool
    private var soundId: Int = 0
    private var streamId: Int = 0
    @Volatile private var loaded = false
    private var pendingPlay = false
    private val handler = Handler(Looper.getMainLooper())
    private val stopPlayback = Runnable {
        if (streamId != 0) soundPool.stop(streamId)
        streamId = 0
    }

    private companion object {
        // The clip is baked at -6 dBFS; this is on top of that (pleasant, not
        // jarring).
        const val VOL = 0.6f
    }

    init {
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        soundPool = SoundPool.Builder()
            .setMaxStreams(1)
            .setAudioAttributes(attrs)
            .build()
        soundPool.setOnLoadCompleteListener { _, _, status ->
            loaded = status == 0
            if (loaded && pendingPlay) {
                pendingPlay = false
                playNow()
            }
        }
        soundId = soundPool.load(context, R.raw.tick, 1)
    }

    /** Ring once — but only if the ringer is in NORMAL mode (silent/vibrate → nothing). */
    fun play() {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return
        if (am.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        if (!loaded) {
            pendingPlay = true
            return
        }
        playNow()
    }

    private fun playNow() {
        handler.removeCallbacks(stopPlayback)
        if (streamId != 0) soundPool.stop(streamId)
        streamId = soundPool.play(soundId, VOL, VOL, 1, 0, 1f) // loop 0 = one shot
        if (streamId != 0) {
            handler.postDelayed(stopPlayback, SplashSoundPolicy.MAX_PLAYBACK_MS)
        }
    }
}
