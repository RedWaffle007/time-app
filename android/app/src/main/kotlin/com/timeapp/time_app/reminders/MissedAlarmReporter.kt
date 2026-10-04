package com.timeapp.time_app.reminders

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Tells the planner AT ONCE that an alarm rang out unanswered (2026-09-27).
 *
 * The last ring's stop (25 minutes in, 2026-10-04) runs here in native code, usually with the app's
 * Dart side not running. Before this, the "unavailable" fact and its "Uh-Oh!"
 * push waited for the app to be opened (often when the person answered
 * Done/Skip). Now the stop itself POSTs `{event: alarmTimeout}` to the push
 * Worker with the signed-in user's ID token; the Worker records
 * `alarm.unavailableAt` and pushes the planner.
 *
 * Best-effort by design: no network, no signed-in user, or a killed process
 * simply leaves the old path in charge — the lifecycle row recorded beside
 * this call is still reported by the app on its next run, and the Worker's
 * dedup makes the second report a no-op.
 */
object MissedAlarmReporter {
    private const val TAG = "MissedAlarmReporter"

    /** Must equal `kNotifyEndpoint` in lib/core/config/notify_config.dart. */
    const val NOTIFY_ENDPOINT = "https://time-app-notify.timeapp.workers.dev"

    /** Same name as `ALARM_TIMEOUT_EVENT` in worker/src/alarm-timeout.js. */
    const val EVENT = "alarmTimeout"

    private const val TOKEN_TIMEOUT_S = 10L
    private const val HTTP_TIMEOUT_MS = 10_000
    private const val ATTEMPTS = 3
    private const val WAKE_LOCK_MS = 45_000L

    /** The request body. Pure, so it is unit-tested. */
    fun requestBody(targetUid: String, itemId: String, atEpochMs: Long): String =
        JSONObject()
            .put("event", EVENT)
            .put("targetUid", targetUid)
            .put("itemId", itemId)
            .put("at", atEpochMs)
            .toString()

    /** Worth retrying: no answer, or the server/transport failed. A 4xx is final. */
    fun shouldRetry(status: Int?): Boolean = status == null || status >= 500

    fun report(context: Context, itemIds: List<String>, atEpochMs: Long) {
        if (itemIds.isEmpty()) return
        val app = context.applicationContext
        // The service stops right after this; keep the CPU up for the call.
        val wakeLock = (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "time_app:missed_report")
            .apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_MS)
            }
        Thread {
            try {
                val user = FirebaseAuth.getInstance().currentUser
                if (user == null) {
                    Log.i(TAG, "no signed-in user; the app reports on next run")
                    return@Thread
                }
                val token = Tasks.await(user.getIdToken(false), TOKEN_TIMEOUT_S, TimeUnit.SECONDS)
                    .token ?: return@Thread
                itemIds.forEach { itemId ->
                    send(token, requestBody(user.uid, itemId, atEpochMs), itemId)
                }
            } catch (e: Exception) {
                Log.w(TAG, "report failed; the app reports on next run", e)
            } finally {
                if (wakeLock.isHeld) wakeLock.release()
            }
        }.start()
    }

    private fun send(token: String, body: String, itemId: String) {
        for (attempt in 1..ATTEMPTS) {
            var status: Int? = null
            try {
                val conn = (URL("$NOTIFY_ENDPOINT/").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = HTTP_TIMEOUT_MS
                    readTimeout = HTTP_TIMEOUT_MS
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Authorization", "Bearer $token")
                }
                conn.outputStream.use { it.write(body.toByteArray()) }
                status = conn.responseCode
                conn.disconnect()
                Log.i(TAG, "reported $itemId: HTTP $status")
            } catch (e: Exception) {
                Log.w(TAG, "attempt $attempt for $itemId failed: ${e.javaClass.simpleName}")
            }
            if (!shouldRetry(status)) return
            if (attempt < ATTEMPTS) Thread.sleep(2_000L * attempt)
        }
    }
}
