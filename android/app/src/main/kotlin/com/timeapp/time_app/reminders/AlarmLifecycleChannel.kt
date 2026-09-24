package com.timeapp.time_app.reminders

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Flutter bridge for durable timeout and hardware-silence observations. */
class AlarmLifecycleChannel(private val appContext: Context) {
    companion object {
        const val CHANNEL = "time_app/alarm_lifecycle"
        @Volatile private var methodChannel: MethodChannel? = null

        fun notifyChanged() {
            methodChannel?.invokeMethod("changed", null)
        }
    }

    fun register(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                val key = call.argument<String>("key").orEmpty()
                when (call.method) {
                    "read" -> result.success(
                        AlarmLifecycleStore.load(appContext).map { toMap(it) },
                    )
                    "markOutcomeRecorded" -> {
                        AlarmLifecycleStore.update(appContext, key) {
                            it.copy(outcomeRecorded = true)
                        }
                        result.success(null)
                    }
                    "markNotificationDelivered" -> {
                        AlarmLifecycleStore.update(appContext, key) {
                            it.copy(notificationDelivered = true)
                        }
                        result.success(null)
                    }
                    "markReviewed" -> {
                        AlarmLifecycleStore.update(appContext, key) {
                            it.copy(reviewed = true)
                        }
                        result.success(null)
                    }
                    "markReviewChoice" -> {
                        val choice = call.argument<String>("choice").orEmpty()
                        require(choice == "done" || choice == "skipped")
                        AlarmLifecycleStore.update(appContext, key) {
                            it.copy(reviewed = true, reviewChoice = choice)
                        }
                        result.success(null)
                    }
                    "markReviewNotificationDelivered" -> {
                        AlarmLifecycleStore.update(appContext, key) {
                            it.copy(reviewNotificationDelivered = true)
                        }
                        result.success(null)
                    }
                    "remove" -> {
                        AlarmLifecycleStore.remove(appContext, key)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("alarm_lifecycle", t.javaClass.simpleName, null)
            }
        }
    }

    private fun toMap(event: AlarmLifecycleStore.Event): Map<String, Any> {
        val reviewChoice = event.reviewChoice
        return mapOf(
            "key" to event.key,
            "itemId" to event.itemId,
            "occurredAtEpoch" to event.occurredAtEpoch,
            "kind" to event.kind,
            "outcomeRecorded" to event.outcomeRecorded,
            "notificationDelivered" to event.notificationDelivered,
            "reviewed" to event.reviewed,
            "reviewNotificationDelivered" to event.reviewNotificationDelivered,
        ) + if (reviewChoice == null) emptyMap() else mapOf(
            "reviewChoice" to reviewChoice,
        )
    }
}
