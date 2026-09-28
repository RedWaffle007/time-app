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
