package com.timeapp.time_app.reminders

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Writes the ring queue's live record onto each plan (2026-10-05), so the
 * planner's card can say "Ringing · reminder 2 of 3" or "rings again about
 * 5:23" — timing the planner's phone can no longer work out, because repeats
 * move as new plans arrive.
 *
 * Runs from native code, usually with the app's Dart side dead, so it goes
 * through Firestore's REST API with the signed-in user's ID token: the same
 * security rules as any app write (the target, an approved plan, only these
 * `alarm.*` fields), without starting a second Firestore SDK instance beside
 * the Flutter plugin's. One commit per segment event, best-effort: no network
 * or no user just leaves the card a step behind.
 */
object RingRecordReporter {
    private const val TAG = "RingRecordReporter"
    private const val TOKEN_TIMEOUT_S = 10L
    private const val HTTP_TIMEOUT_MS = 10_000
    private const val ATTEMPTS = 3
    private const val WAKE_LOCK_MS = 45_000L

    /**
     * One plan's update. [ring] is written when set; each [times] entry is
     * written as a timestamp, or DELETED when its value is null.
     */
    data class Record(
        val itemId: String,
        val ring: Int? = null,
        val times: Map<String, Long?> = emptyMap(),
    )

    /** The `documents:commit` body. Pure, so it is unit-tested. */
    fun commitBody(projectId: String, uid: String, records: List<Record>): String {
        val writes = JSONArray()
        records.forEach { record ->
            val fields = JSONObject()
            val mask = JSONArray()
            record.ring?.let {
                fields.put("ring", JSONObject().put("integerValue", it.toString()))
                mask.put("alarm.ring")
            }
            record.times.forEach { (name, epoch) ->
                if (epoch != null) {
                    fields.put(name, JSONObject().put("timestampValue", timestamp(epoch)))
                }
                // In the mask without a value: Firestore deletes the field.
                mask.put("alarm.$name")
            }
            writes.put(
                JSONObject()
                    .put(
                        "update",
                        JSONObject()
                            .put(
                                "name",
                                "projects/$projectId/databases/(default)/documents/" +
                                    "scheduleItems/$uid/items/${record.itemId}",
                            )
                            .put(
                                "fields",
                                JSONObject().put(
                                    "alarm",
                                    JSONObject().put("mapValue", JSONObject().put("fields", fields)),
                                ),
                            ),
                    )
                    .put("updateMask", JSONObject().put("fieldPaths", mask))
                    .put("currentDocument", JSONObject().put("exists", true)),
            )
        }
        return JSONObject().put("writes", writes).toString()
    }

    /** RFC 3339 in UTC, as Firestore's REST API wants. */
    fun timestamp(epochMs: Long): String = java.time.Instant.ofEpochMilli(epochMs).toString()

    /** Worth retrying: no answer, or the server/transport failed. A 4xx is final. */
    fun shouldRetry(status: Int?): Boolean = status == null || status >= 500

    fun report(context: Context, records: List<Record>) {
        if (records.isEmpty()) return
        val app = context.applicationContext
        val wakeLock = (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "time_app:ring_record")
            .apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_MS)
            }
        Thread {
            try {
                val user = FirebaseAuth.getInstance().currentUser ?: return@Thread
                val projectId = FirebaseApp.getInstance().options.projectId ?: return@Thread
                val token = Tasks.await(user.getIdToken(false), TOKEN_TIMEOUT_S, TimeUnit.SECONDS)
                    .token ?: return@Thread
                send(projectId, token, commitBody(projectId, user.uid, records))
            } catch (e: Exception) {
                Log.w(TAG, "ring record not written: ${e.javaClass.simpleName}")
            } finally {
                if (wakeLock.isHeld) wakeLock.release()
            }
        }.start()
    }

    private fun send(projectId: String, token: String, body: String) {
        val url = "https://firestore.googleapis.com/v1/projects/$projectId/" +
            "databases/(default)/documents:commit"
        for (attempt in 1..ATTEMPTS) {
            var status: Int? = null
            try {
                val conn = (URL(url).openConnection() as HttpURLConnection).apply {
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
                Log.i(TAG, "ring record: HTTP $status")
            } catch (e: Exception) {
                Log.w(TAG, "attempt $attempt failed: ${e.javaClass.simpleName}")
            }
            if (!shouldRetry(status)) return
            if (attempt < ATTEMPTS) Thread.sleep(2_000L * attempt)
        }
    }
}
