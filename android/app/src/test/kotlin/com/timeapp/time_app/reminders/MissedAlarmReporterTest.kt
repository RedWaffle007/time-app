package com.timeapp.time_app.reminders

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MissedAlarmReporterTest {
    @Test
    fun bodyCarriesTheWorkerEventTargetItemAndTime() {
        val body = JSONObject(MissedAlarmReporter.requestBody("uid-1", "item-1", 1_893_488_460_000L))
        assertEquals("alarmTimeout", body.getString("event"))
        assertEquals("uid-1", body.getString("targetUid"))
        assertEquals("item-1", body.getString("itemId"))
        assertEquals(1_893_488_460_000L, body.getLong("at"))
    }

    @Test
    fun onlyTransportAndServerFailuresAreRetried() {
        assertTrue(MissedAlarmReporter.shouldRetry(null))
        assertTrue(MissedAlarmReporter.shouldRetry(500))
        assertFalse(MissedAlarmReporter.shouldRetry(200))
        assertFalse(MissedAlarmReporter.shouldRetry(403))
        assertFalse(MissedAlarmReporter.shouldRetry(400))
    }
}

class RingRecordReporterTest {
    @Test
    fun `one commit updates only the ring fields, deleting a cleared forecast`() {
        val body = org.json.JSONObject(
            RingRecordReporter.commitBody(
                "proj",
                "uid1",
                listOf(
                    RingRecordReporter.Record(
                        "item1",
                        ring = 2,
                        times = linkedMapOf("ringAt" to 0L, "nextRingAt" to null),
                    ),
                ),
            ),
        )
        val write = body.getJSONArray("writes").getJSONObject(0)
        assertEquals(
            "projects/proj/databases/(default)/documents/scheduleItems/uid1/items/item1",
            write.getJSONObject("update").getString("name"),
        )
        val fields = write.getJSONObject("update").getJSONObject("fields")
            .getJSONObject("alarm").getJSONObject("mapValue").getJSONObject("fields")
        assertEquals("2", fields.getJSONObject("ring").getString("integerValue"))
        assertEquals("1970-01-01T00:00:00Z", fields.getJSONObject("ringAt").getString("timestampValue"))
        // In the mask but not in the fields: Firestore deletes it.
        assertEquals(false, fields.has("nextRingAt"))
        assertEquals(
            listOf("alarm.ring", "alarm.ringAt", "alarm.nextRingAt"),
            write.getJSONObject("updateMask").getJSONArray("fieldPaths").let { a ->
                (0 until a.length()).map { a.getString(it) }
            },
        )
        // Never creates a plan that is gone.
        assertEquals(true, write.getJSONObject("currentDocument").getBoolean("exists"))
    }

    @Test
    fun `only server failures are retried`() {
        assertEquals(true, RingRecordReporter.shouldRetry(null))
        assertEquals(true, RingRecordReporter.shouldRetry(503))
        assertEquals(false, RingRecordReporter.shouldRetry(403))
        assertEquals(false, RingRecordReporter.shouldRetry(200))
    }
}
