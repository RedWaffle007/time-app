package com.timeapp.time_app.reminders

/** Constants whose values are part of the alarm's user-visible contract. */
internal object AlarmSoundPolicy {
    /** The longest a new alarm rings (the ring queue, 2026-10-05). */
    const val MAX_RING_DURATION_MS = RingQueuePolicy.FRESH_MAX_MS

    // MediaPlayer implements this by finishing the entire source before seeking
    // back to its start. Never replace it with a timer that calls start/reseek.
    const val LOOP_WHOLE_TONE = true

    fun shouldStartPlayer(playerAlreadyExists: Boolean): Boolean =
        !playerAlreadyExists

    /** "{planner} planned {task} for you" — the heads-up must say who and what. */
    fun ringingTitle(headline: String?): String =
        headline?.trim()?.takeIf { it.isNotEmpty() } ?: "Alarm"

    /**
     * A repeat says so (2026-10-05): "Reminder 2 of 3 · {planner} planned
     * {task} for you". Ring 1 is the plain sentence.
     */
    fun ringingTitle(headline: String?, ring: Int): String =
        if (ring <= 1) ringingTitle(headline)
        else "Reminder $ring of ${RingQueuePolicy.RINGS} · ${ringingTitle(headline)}"

    const val RINGING_TEXT = "Tap to open · Dismiss to stop"

    /**
     * The heads-up's second line (2026-10-05): when it was planned for, how
     * many others ring with it, then what to do. "Planned for 5:08 PM ·
     * +2 more · Tap to open · Dismiss to stop".
     */
    fun ringingText(plannedTime: String?, others: Int): String =
        listOfNotNull(
            plannedTime?.takeIf { it.isNotBlank() }?.let { "Planned for $it" },
            if (others > 0) "+$others more" else null,
            RINGING_TEXT,
        ).joinToString(" · ")

    /**
     * When the ringing service re-removes a late-arriving scheduled duplicate.
     * Both fire at the same instant from separate OS alarms; these cover the
     * observed spread without leaving a duplicate up for long.
     */
    val DUPLICATE_RECHECK_MS = listOf(500L, 2_000L, 5_000L)

    /** Waiting for its next ring: when it comes back, in the phone's format. */
    fun quietText(time: String): String = "Rings again at $time · Dismiss to stop"

    const val MISSED_TITLE = "Missed alarm"

    private const val VOICE_SUFFIX = " sent you a voice alarm"
    private const val PLANNED_INFIX = " planned "
    private const val PLANNED_SUFFIX = " for you"
    private const val UNKNOWN_PLANNER = "Someone"

    /**
     * "Missed alarm from {planner}" / "Missed voice note from {planner}" (R3,
     * 2026-10-02), read back from the one alarm sentence the alarm was armed
     * with (Dart `alarmHeadline()`, Worker `alarmHeadline()`), so no second
     * field rides the arming path. A self-plan, an unknown name ("Someone")
     * or an unrecognised sentence keeps the plain title. Known limit: a
     * planner whose own name contains " planned " is cut at that word.
     */
    fun missedTitle(headline: String?): String {
        val sentence = headline?.trim().orEmpty()
        if (sentence.endsWith(VOICE_SUFFIX)) {
            val who = sentence.removeSuffix(VOICE_SUFFIX).trim()
            return if (who.isEmpty() || who == UNKNOWN_PLANNER) {
                "Missed voice note"
            } else {
                "Missed voice note from $who"
            }
        }
        if (sentence.endsWith(PLANNED_SUFFIX)) {
            val cut = sentence.indexOf(PLANNED_INFIX)
            if (cut > 0) {
                val who = sentence.substring(0, cut).trim()
                if (who.isNotEmpty() && who != UNKNOWN_PLANNER && who != "You") {
                    return "$MISSED_TITLE from $who"
                }
            }
        }
        return MISSED_TITLE
    }

    fun missedText(headline: String?): String =
        headline?.trim()?.takeIf { it.isNotEmpty() }
            ?.let { "You didn't respond: $it" }
            ?: "You didn't respond to a planned task."
}
