package com.timeapp.alarm_delivery_bridge;

import android.content.Context;
import android.util.Log;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;

/** Registers the app alarm channel in both visible and headless Flutter engines. */
public final class AlarmDeliveryBridgePlugin implements FlutterPlugin {
  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    try {
      // Scheduling and playback deliberately remain in the app's reminder
      // feature. This package only makes Flutter's generated registrant attach
      // that same channel to Firebase Messaging's background engine.
      Class<?> channelClass =
          Class.forName("com.timeapp.time_app.reminders.AlarmDeliveryChannel");
      Object channel =
          channelClass
              .getDeclaredConstructor(Context.class)
              .newInstance(binding.getApplicationContext());
      channelClass
          .getMethod("register", BinaryMessenger.class)
          .invoke(channel, binding.getBinaryMessenger());
    } catch (Throwable error) {
      Log.e("AlarmDeliveryBridge", "Unable to register alarm delivery", error);
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}
}
