package com.timeapp.time_app.reminders

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The killed-app "new alarm" push, armed natively (2026-10-05). */
class AlarmPushPolicyTest {
    private val now = java.time.Instant.parse("2026-09-21T14:00:00Z").toEpochMilli()
    private val sha = "a".repeat(64)

    private fun data(vararg extra: Pair<String, String>) = mapOf(
        "command" to "scheduleReminder",
        "itemId" to "item-1",
        "targetUid" to "uid-1",
        "fireAtUtc" to "2026-09-21T14:13:20.000Z",
        "title" to "Test Planner sent you a voice alarm",
    ) + extra

    @Test
    fun `the push becomes an alarm, with its voice note and length`() {
        val push = AlarmPushPolicy.parse(
            data("voiceSha256" to sha, "voiceSizeBytes" to "9000", "voiceDurationMs" to "21000"),
            now,
        )!!
        assertEquals("item-1", push.itemId)
        assertEquals(java.time.Instant.parse("2026-09-21T14:13:20.000Z").toEpochMilli(), push.fireAtEpoch)
        assertEquals(sha, push.voiceSha256)
        assertEquals(9_000L, push.voiceSizeBytes)
        assertEquals(21_000L, push.voiceDurationMs)
    }

    @Test
    fun `anything else, a past time or a broken note is not armed as a voice alarm`() {
        assertNull(AlarmPushPolicy.parse(data("command" to "fetchVoiceNote"), now))
        assertNull(AlarmPushPolicy.parse(data("fireAtUtc" to "2020-01-01T00:00:00Z"), now))
        assertNull(AlarmPushPolicy.parse(data("fireAtUtc" to "soon"), now))
        assertNull(AlarmPushPolicy.parse(data("itemId" to ""), now))
        assertNull(AlarmPushPolicy.parse(data("voiceSha256" to "nope", "voiceSizeBytes" to "9000"), now)!!.voiceSha256)
        assertNull(AlarmPushPolicy.parse(data("voiceSha256" to sha), now)!!.voiceSha256)
    }

    @Test
    fun `the id matches Dart's reminderNotificationId (values seen on the Redmi)`() {
        assertEquals(1_678_518_572, AlarmPushPolicy.notificationId("a"))
        assertEquals(839_930_163, AlarmPushPolicy.notificationId("oT6sC6SgurNvV9SAtG9y"))
        assertEquals(1_953_106_375, AlarmPushPolicy.notificationId("8nhU3D6fxFCMCNlIjagf"))
        assertEquals(524_292_095, AlarmPushPolicy.notificationId("Vzmcg2uEnX8vQuJxCAW6"))
    }
}
