package com.timeapp.time_app.reminders

/**
 * The ring queue (2026-10-05, user-directed): what sounds when, for every
 * alarm a person has live. A new alarm always rings at its time; a missed
 * alarm's repeats wait for free time and ring together. DECISIONS.md "Ring
 * queue: new alarms first, repeats fill the gaps".
 *
 * Pure and Android-free: no clock, no players, no storage. The native queue
 * asks [nextSegment] what to play, [cutAt] when a newly due alarm may
 * interrupt it, [credit] which rings the played sound counts as, and
 * [nextWakeAt] when to look again.
 */
internal object RingQueuePolicy {
    /** A new alarm's ring, at most. */
    const val FRESH_MAX_MS = 5 * 60_000L

    /** A batch of repeats. */
    const val REPEAT_MS = 2 * 60_000L

    /** From the start of one ring to when the next is due. */
    const val REPEAT_SPACING_MS = 10 * 60_000L

    /** Rings in all: the first plus two repeats. */
    const val RINGS = 3

    /** A tone counts, and may be cut, only after this long. */
    const val MIN_TONE_MS = 20_000L

    /** Between two different voice notes in a batch. */
    const val BATCH_VOICE_GAP_MS = 3_000L

    /** Between two plays of the same note in a new alarm's ring. */
    const val REPLAY_GAP_MS = 1_000L

    data class Alarm(
        val itemId: String,
        val scheduledAt: Long,
        /** The voice note's length; null for the default alarm tone. */
        val voiceMs: Long? = null,
        /** Rings that have counted so far, 0 to [RINGS]. */
        val ringsDone: Int = 0,
        /** When the last counted ring started; 0 before the first. */
        val lastRingAt: Long = 0L,
    ) {
        val isFresh: Boolean get() = ringsDone == 0
        val isVoice: Boolean get() = voiceMs != null
        val isOver: Boolean get() = ringsDone >= RINGS

        /** When its next ring is due. */
        val dueAt: Long
            get() = if (ringsDone == 0) scheduledAt else lastRingAt + REPEAT_SPACING_MS
    }

    sealed class Sound {
        abstract val from: Long
        abstract val to: Long

        /** One full play of one voice note. */
        data class Voice(val itemId: String, override val from: Long, override val to: Long) : Sound()

        /** The default tone, for every default alarm in the segment. */
        data class Tone(val itemIds: List<String>, override val from: Long, override val to: Long) : Sound()
    }

    /** One stretch of ringing: a new alarm's ring, or a batch of repeats. */
    data class Segment(val fresh: Boolean, val itemIds: List<String>, val sounds: List<Sound>) {
        val startsAt: Long get() = sounds.first().from
        val endsAt: Long get() = sounds.last().to
    }

    /**
     * What to ring from [now], or null when nothing is due (or a due repeat
     * cannot fit before the next new alarm). A due new alarm goes first, the
     * one scheduled latest first; then any due repeats, batched.
     */
    fun nextSegment(alarms: List<Alarm>, now: Long): Segment? {
        val live = alarms.filter { !it.isOver }
        val fresh = live.filter { it.isFresh && it.scheduledAt <= now }
            .maxWithOrNull(compareBy<Alarm> { it.scheduledAt }.thenBy { it.itemId })
        val nextFresh = nextFreshAfter(live, now)
        if (fresh != null) return planFresh(fresh, now, nextFresh)
        return planRepeats(live, now, nextFresh)
    }

    /** The earliest new alarm still to come after [now]. */
    fun nextFreshAfter(alarms: List<Alarm>, now: Long): Long? =
        alarms.filter { it.isFresh && it.scheduledAt > now }.minOfOrNull { it.scheduledAt }

    /**
     * A new alarm's ring from [startAt]: up to [FRESH_MAX_MS], ending when
     * [nextFreshAt] is due. A tone always gets [MIN_TONE_MS]; a voice note
     * always plays once and never starts a play it cannot finish in time.
     */
    fun planFresh(alarm: Alarm, startAt: Long, nextFreshAt: Long?): Segment {
        var limit = startAt + FRESH_MAX_MS
        if (nextFreshAt != null) limit = minOf(limit, nextFreshAt)
        val voiceMs = alarm.voiceMs
        val sounds = if (voiceMs == null) {
            listOf(Sound.Tone(listOf(alarm.itemId), startAt, maxOf(limit, startAt + MIN_TONE_MS)))
        } else {
            val plays = mutableListOf<Sound>(Sound.Voice(alarm.itemId, startAt, startAt + voiceMs))
            var next = startAt + voiceMs + REPLAY_GAP_MS
            while (next + voiceMs <= limit) {
                plays += Sound.Voice(alarm.itemId, next, next + voiceMs)
                next += voiceMs + REPLAY_GAP_MS
            }
            plays
        }
        return Segment(fresh = true, itemIds = listOf(alarm.itemId), sounds = sounds)
    }

    /**
     * Every repeat due at [now], as one batch that ends before [nextFreshAt]:
     * voice notes once each (oldest due first, 3 s apart), then one tone for
     * the default alarms that fills the rest of [REPEAT_MS]. A voice-only
     * batch cycles its notes until [REPEAT_MS]. What does not fit stays due.
     */
    fun planRepeats(alarms: List<Alarm>, now: Long, nextFreshAt: Long?): Segment? {
        if (nextFreshAt != null && nextFreshAt <= now) return null
        val order = compareBy<Alarm>({ it.dueAt }, { it.scheduledAt }, { it.itemId })
        val due = alarms.filter { !it.isFresh && !it.isOver && it.dueAt <= now }.sortedWith(order)
        if (due.isEmpty()) return null
        val windowEnd = nextFreshAt ?: Long.MAX_VALUE
        val sounds = mutableListOf<Sound>()
        val included = mutableListOf<String>()

        val voices = due.filter { it.isVoice }
        var t = now
        for (voice in voices) {
            val end = t + voice.voiceMs!!
            if (end > windowEnd) break
            sounds += Sound.Voice(voice.itemId, t, end)
            included += voice.itemId
            t = end + BATCH_VOICE_GAP_MS
        }

        val tones = due.filter { !it.isVoice }
        if (tones.isNotEmpty()) {
            val start = if (sounds.isEmpty()) now else t
            val end = minOf(maxOf(now + REPEAT_MS, start + MIN_TONE_MS), windowEnd)
            if (end - start >= MIN_TONE_MS) {
                val ids = tones.map { it.itemId }
                sounds += Sound.Tone(ids, start, end)
                included += ids
            }
        } else if (sounds.size == voices.size && sounds.isNotEmpty()) {
            // Every note has played once: go round again until the batch's
            // two minutes, never starting a play that would run past them or
            // into the next new alarm.
            val until = minOf(now + REPEAT_MS, windowEnd)
            var i = 0
            while (true) {
                val voice = voices[i % voices.size]
                val end = t + voice.voiceMs!!
                if (end > until) break
                sounds += Sound.Voice(voice.itemId, t, end)
                t = end + BATCH_VOICE_GAP_MS
                i++
            }
        }

        if (sounds.isEmpty()) return null
        return Segment(fresh = false, itemIds = included, sounds = sounds)
    }

    /**
     * The earliest moment [segment] may stop for a new alarm due at [dueAt]:
     * at once in a gap, after the current voice play, or once the tone has
     * sounded [MIN_TONE_MS].
     */
    fun cutAt(segment: Segment, dueAt: Long): Long {
        val sound = segment.sounds.firstOrNull { dueAt >= it.from && dueAt < it.to } ?: return dueAt
        return when (sound) {
            is Sound.Voice -> sound.to
            is Sound.Tone -> minOf(maxOf(dueAt, sound.from + MIN_TONE_MS), sound.to)
        }
    }

    /**
     * Whether [incoming], now due, interrupts [current]. A new alarm
     * interrupts any batch of repeats, and a new alarm scheduled earlier than
     * itself; an older new alarm (delivered late) waits its turn.
     */
    fun interrupts(current: Segment, currentScheduledAt: Long, incoming: Alarm): Boolean =
        incoming.isFresh && (!current.fresh || incoming.scheduledAt > currentScheduledAt)

    data class Credit(
        /** Every alarm, with the rings this segment counted added. */
        val alarms: List<Alarm>,
        /** Alarms whose last ring just counted: now missed. */
        val missed: List<String>,
    )

    /**
     * The rings [segment] counted, if it stopped at [endedAt]. A new alarm's
     * ring always counts (the cutting rules guarantee it sounded). In a batch
     * a voice note counts once played in full, a tone once it sounded
     * [MIN_TONE_MS]; anything else stays due.
     */
    fun credit(alarms: List<Alarm>, segment: Segment, endedAt: Long): Credit {
        val startedAt = mutableMapOf<String, Long>()
        if (segment.fresh) {
            segment.itemIds.forEach { startedAt[it] = segment.startsAt }
        } else {
            for (sound in segment.sounds) {
                when (sound) {
                    is Sound.Voice ->
                        if (sound.to <= endedAt && sound.itemId !in startedAt) {
                            startedAt[sound.itemId] = sound.from
                        }
                    is Sound.Tone ->
                        if (minOf(endedAt, sound.to) - sound.from >= MIN_TONE_MS) {
                            sound.itemIds.forEach { startedAt.putIfAbsent(it, sound.from) }
                        }
                }
            }
        }
        val missed = mutableListOf<String>()
        val updated = alarms.map { alarm ->
            val at = startedAt[alarm.itemId] ?: return@map alarm
            alarm.copy(ringsDone = alarm.ringsDone + 1, lastRingAt = at).also {
                if (it.isOver) missed += it.itemId
            }
        }
        return Credit(updated, missed)
    }

    /**
     * Volume Down silenced [segment] (2026-10-05): EVERY alarm in it counts
     * this ring, however briefly it sounded — it was heard and silenced, so
     * it must not come straight back. Its next ring is due as usual (10 min
     * after this one started). Nothing is answered.
     */
    fun creditSilenced(alarms: List<Alarm>, segment: Segment): Credit {
        val missed = mutableListOf<String>()
        val updated = alarms.map { alarm ->
            if (alarm.itemId !in segment.itemIds) return@map alarm
            alarm.copy(ringsDone = alarm.ringsDone + 1, lastRingAt = segment.startsAt).also {
                if (it.isOver) missed += it.itemId
            }
        }
        return Credit(updated, missed)
    }

    /** When something next comes due after [now], or null when nothing will. */
    fun nextWakeAt(alarms: List<Alarm>, now: Long): Long? =
        alarms.filter { !it.isOver && it.dueAt > now }.minOfOrNull { it.dueAt }

    /**
     * When each alarm next rings if nothing new is planned, after [current]
     * (the segment ringing now) plays out: what "Rings again at …" says. An
     * alarm in [current] gets its ring AFTER this one.
     */
    fun forecast(alarms: List<Alarm>, now: Long, current: Segment? = null): Map<String, Long> {
        var live = alarms.filter { !it.isOver }
        var t = now
        if (current != null) {
            live = credit(live, current, current.endsAt).alarms.filter { !it.isOver }
            t = maxOf(now, current.endsAt)
        }
        val next = mutableMapOf<String, Long>()
        repeat(FORECAST_STEPS) {
            if (live.all { it.itemId in next }) return next
            val segment = nextSegment(live, t)
            if (segment == null) {
                t = nextWakeAt(live, t) ?: return next
                return@repeat
            }
            for (sound in segment.sounds) {
                val ids = when (sound) {
                    is Sound.Voice -> listOf(sound.itemId)
                    is Sound.Tone -> sound.itemIds
                }
                ids.forEach { next.putIfAbsent(it, sound.from) }
            }
            live = credit(live, segment, segment.endsAt).alarms.filter { !it.isOver }
            t = segment.endsAt
        }
        return next
    }

    private const val FORECAST_STEPS = 2_000
}
