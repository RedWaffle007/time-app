package com.timeapp.time_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

internal object SplashSoundPolicy {
    const val MAX_PLAYBACK_MS = 1_500L
    const val FADE_DURATION_MS = 300L
    const val FADE_STEP_MS = 30L
    const val FADE_START_MS = MAX_PLAYBACK_MS - FADE_DURATION_MS

    fun remainingMs(requestedAtMs: Long, nowMs: Long): Long =
        (MAX_PLAYBACK_MS - (nowMs - requestedAtMs).coerceAtLeast(0L))
            .coerceAtLeast(0L)

    fun volumeScale(elapsedMs: Long): Float {
        if (elapsedMs <= FADE_START_MS) return 1f
        return ((MAX_PLAYBACK_MS - elapsedMs).toFloat() / FADE_DURATION_MS)
            .coerceIn(0f, 1f)
    }
}

/**
 * The cold-start pendulum-clock strike — ONE ring ("tunnn"), before the logo.
 *
 * A single synthesized wall-clock hour strike (`res/raw/tick.wav`, an original
 * sample, public domain), played ONCE at mount. Its final 300ms ramp smoothly
 * to silence while the unchanged 1.5-second loading surface fades away.
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
    private var requestedAtMs = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val fadePlayback = object : Runnable {
        override fun run() {
            val activeStream = streamId
            if (activeStream == 0) return
            val elapsed = SystemClock.uptimeMillis() - requestedAtMs
            val scale = SplashSoundPolicy.volumeScale(elapsed)
            soundPool.setVolume(activeStream, VOL * scale, VOL * scale)
            if (scale <= 0f) {
                soundPool.stop(activeStream)
                if (streamId == activeStream) streamId = 0
                return
            }
            val remaining = SplashSoundPolicy.remainingMs(
                requestedAtMs,
                SystemClock.uptimeMillis(),
            )
            handler.postDelayed(this, minOf(SplashSoundPolicy.FADE_STEP_MS, remaining))
        }
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
        requestedAtMs = SystemClock.uptimeMillis()
        if (!loaded) {
            pendingPlay = true
            return
        }
        playNow()
    }

    private fun playNow() {
        handler.removeCallbacks(fadePlayback)
        if (streamId != 0) soundPool.stop(streamId)
        streamId = 0
        val now = SystemClock.uptimeMillis()
        val remaining = SplashSoundPolicy.remainingMs(requestedAtMs, now)
        if (remaining == 0L) return
        val elapsed = SplashSoundPolicy.MAX_PLAYBACK_MS - remaining
        val volume = VOL * SplashSoundPolicy.volumeScale(elapsed)
        streamId = soundPool.play(soundId, volume, volume, 1, 0, 1f) // one shot
        if (streamId != 0) {
            handler.postDelayed(
                fadePlayback,
                (SplashSoundPolicy.FADE_START_MS - elapsed).coerceAtLeast(0L),
            )
        }
    }
}
