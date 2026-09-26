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

    fun notificationIds(): Set<Int> = notifications.keys.toSet()

    fun clear() {
        notifications.clear()
        uiItems.clear()
    }
}

/** Constants whose values are part of the alarm's user-visible contract. */
internal object AlarmSoundPolicy {
    const val MAX_RING_DURATION_MS = 60_000L

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

    const val MISSED_TITLE = "Missed alarm"

    fun missedText(headline: String?): String =
        headline?.trim()?.takeIf { it.isNotEmpty() }
            ?.let { "You didn't respond: $it" }
            ?: "You didn't respond to a planned task."
}
