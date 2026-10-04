package com.timeapp.time_app.reminders

/**
 * The ownership rule for the one native alarm tone.
 *
 * A due notification claims the sound before Flutter exists. When AlarmScreen
 * mounts it adds a UI claim, then cancellation releases the notification claim.
 * The tone must survive that handoff and stop only when no notification or UI
 * still owns it. Keeping this Android-free makes the rule executable in a plain
 * JVM test; [AlarmSoundService] remains the sole owner of MediaPlayer/wake-lock
 * side effects.
 */
internal class AlarmPlaybackOwnership {
    private val notifications = linkedMapOf<Int, String>()
    private val uiItems = linkedSetOf<String>()

    val hasOwners: Boolean
        get() = notifications.isNotEmpty() || uiItems.isNotEmpty()

    fun claimNotification(notificationId: Int, itemId: String) {
        if (notificationId >= 0 && itemId.isNotEmpty()) {
            // Same id replaces its own stale value; it never creates a second
            // owner and therefore cannot cause a second playback start.
            notifications[notificationId] = itemId
        }
    }

    fun claimUi(itemId: String) {
        if (itemId.isNotEmpty()) uiItems.add(itemId)
    }

    fun releaseNotification(notificationId: Int) {
        notifications.remove(notificationId)
    }

    fun releaseItem(itemId: String) {
        notifications.entries.removeAll { it.value == itemId }
        uiItems.remove(itemId)
    }

    fun latestNotification(): Pair<Int, String>? =
        notifications.entries.lastOrNull()?.let { it.key to it.value }

    fun latestUiItem(): String? = uiItems.lastOrNull()

    fun itemIds(): Set<String> = notifications.values.toSet() + uiItems

    fun itemForNotification(notificationId: Int): String? = notifications[notificationId]

    fun notificationIdsOf(itemId: String): Set<Int> =
        notifications.filterValues { it == itemId }.keys.toSet()

    fun notificationIds(): Set<Int> = notifications.keys.toSet()

    fun clear() {
        notifications.clear()
        uiItems.clear()
    }
}

/**
 * The alarms in a ring right now (2026-10-04), in the order they started, each
 * with its own end time. The newest one has the speaker; the rest keep their
 * own clocks and take it back, newest first, as later ones end. Android-free,
 * for a plain JVM test.
 */
internal class AlarmRingSet {
    private val ends = linkedMapOf<String, Long>()

    val isEmpty: Boolean get() = ends.isEmpty()

    fun contains(itemId: String): Boolean = itemId in ends

    /** Adds [itemId] as the newest; an alarm already here is unchanged. */
    fun add(itemId: String, endsAt: Long) {
        if (itemId !in ends) ends[itemId] = endsAt
    }

    /** True when [itemId] was ringing. */
    fun remove(itemId: String): Boolean = ends.remove(itemId) != null

    /** The one with the speaker: the newest still ringing. */
    fun sounding(): String? = ends.keys.lastOrNull()

    fun endsAt(itemId: String): Long? = ends[itemId]

    fun ids(): List<String> = ends.keys.toList()

    fun clear() = ends.clear()
}

/** Constants whose values are part of the alarm's user-visible contract. */
internal object AlarmSoundPolicy {
    /** One ring of the cycle (2026-10-04): 5 minutes, then quiet or missed. */
    const val MAX_RING_DURATION_MS = RingCyclePolicy.RING_MS

    // MediaPlayer implements this by finishing the entire source before seeking
    // back to its start. Never replace it with a timer that calls start/reseek.
    const val LOOP_WHOLE_TONE = true

    fun shouldStartPlayer(playerAlreadyExists: Boolean): Boolean =
        !playerAlreadyExists

    /** "{planner} planned {task} for you" — the heads-up must say who and what. */
    fun ringingTitle(headline: String?): String =
        headline?.trim()?.takeIf { it.isNotEmpty() } ?: "Alarm"

    const val RINGING_TEXT = "Tap to open · Dismiss to stop"

    /**
     * When the ringing service re-removes a late-arriving scheduled duplicate.
     * Both fire at the same instant from separate OS alarms; these cover the
     * observed spread without leaving a duplicate up for long.
     */
    val DUPLICATE_RECHECK_MS = listOf(500L, 2_000L, 5_000L)

    /** Between rings (2026-10-04): when it comes back, in the phone's format. */
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
