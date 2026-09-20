package com.timeapp.time_app.reminders

import android.content.Context
import androidx.annotation.Keep
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Dart bridge for the native audio alarm, kept separate from notification UI. */
@Keep
class AlarmDeliveryChannel(private val appContext: Context) {
    companion object {
        const val CHANNEL = "time_app/alarm_delivery"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> {
                    val id = call.argument<Int>("id")
                    val itemId = call.argument<String>("itemId") ?: ""
                    val fireAt = call.argument<Long>("fireAtMillis")
                    val exact = call.argument<Boolean>("exact") ?: true
                    if (id == null || fireAt == null || itemId.isEmpty()) {
                        result.success("bad_args")
                    } else {
                        result.success(
                            AlarmDeliveryScheduler.arm(
                                appContext,
                                id,
                                itemId,
                                fireAt,
                                exact,
                            ),
                        )
                    }
                }
                "cancel" -> {
                    call.argument<Int>("id")?.let {
                        AlarmDeliveryScheduler.cancel(appContext, it)
                    }
                    result.success(null)
                }
                "cancelAll" -> {
                    AlarmDeliveryScheduler.cancelAll(appContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
