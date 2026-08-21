package com.timeapp.time_app.reminders

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart half of the audit lives in `reminder_audit_log.dart`; this is the
 * Android end of the same channel.
 *
 * Dart only ever ARMS, CANCELS and READS. It never writes a FIRED row — that
 * one is written by [ReminderAuditReceiver] in a process where Dart does not
 * exist, which is the entire reason the instrument is native.
 *
 * Every method answers `success`, including the failure paths: this is
 * diagnostics, and diagnostics that can break the feature they diagnose are
 * worse than no diagnostics. `arm` returns its outcome string rather than
 * raising, so Dart can log a denied exact-alarm permission without a scheduling
 * call ever throwing because of it.
 */
class ReminderAuditChannel(private val appContext: Context) {

    companion object {
        const val CHANNEL = "time_app/reminder_audit"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "arm" -> {
                        val id = call.argument<Int>("id")
                        val itemId = call.argument<String>("itemId") ?: ""
                        // Milliseconds since epoch arrive as a Long from Dart's
                        // int, which is 64-bit — reading it as Int truncates
                        // every timestamp into the 1970s.
                        val fireAt = call.argument<Long>("fireAtMillis")
                        if (id == null || fireAt == null) {
                            result.success("bad_args")
                        } else {
                            result.success(
                                ReminderAuditScheduler.arm(appContext, id, itemId, fireAt),
                            )
                        }
                    }

                    "cancel" -> {
                        call.argument<Int>("id")?.let {
                            ReminderAuditScheduler.cancel(appContext, it)
                        }
                        result.success(null)
                    }

                    "cancelAll" -> {
                        ReminderAuditScheduler.cancelAll(appContext)
                        result.success(null)
                    }

                    "note" -> {
                        ReminderAuditLog.write(
                            appContext,
                            event = call.argument<String>("event") ?: "NOTE",
                            itemId = call.argument<String>("itemId") ?: "",
                            notificationId = call.argument<Int>("id"),
                            scheduledEpoch = call.argument<Long>("fireAtMillis"),
                            note = call.argument<String>("note") ?: "",
                        )
                        result.success(null)
                    }

                    "read" -> result.success(ReminderAuditLog.read(appContext))
                    "clear" -> {
                        ReminderAuditLog.clear(appContext)
                        result.success(null)
                    }
                    "path" -> result.success(ReminderAuditLog.path(appContext))

                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.success("error: ${t.javaClass.simpleName}")
            }
        }
    }
}
