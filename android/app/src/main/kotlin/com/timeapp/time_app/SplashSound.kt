package com.timeapp.time_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool

/**
 * The cold-start pendulum-clock strike — ONE ring ("tunnn"), before the logo.
 *
 * A single synthesized wall-clock hour strike (`res/raw/tick.wav`, an original
 * sample, public domain), played ONCE at mount. No loop, no fades, no ducking —
 * it rings and rings out on its own long decay while the logo blooms over it.
 *
 * Native because it owns the mute check and the preload. Constructed in
 * [MainActivity]'s engine config so the sample is ready before the splash
 * mounts; a [pendingPlay] latch covers the case where the load has not finished
 * by the time `play` is called.
 */
class SplashSound(private val context: Context) {

    private val soundPool: SoundPool
    private var soundId: Int = 0
    @Volatile private var loaded = false
    private var pendingPlay = false

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
        soundPool.play(soundId, VOL, VOL, 1, 0, 1f) // loop 0 = one shot
    }
}
