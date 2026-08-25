import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Reads this device's manufacturer, kept behind an interface so the OEM branch
/// selection can be tested with a fake string instead of real hardware.
abstract interface class OemInfo {
  /// The raw `Build.MANUFACTURER`, or an empty string off Android or on any
  /// failure — [oemProfileFor] maps empty to the graceful skip-the-step default.
  Future<String> manufacturer();
}

/// The real implementation, over `device_info_plus`. Adds no permission and no
/// native code of its own — it only reads build fields the OS already exposes.
class DeviceInfoOemInfo implements OemInfo {
  const DeviceInfoOemInfo();

  @override
  Future<String> manufacturer() async {
    // Off Android there is no autostart/Doze story to brand, so short-circuit
    // rather than pay for a plugin call that would answer nothing useful.
    if (!Platform.isAndroid) return '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.manufacturer;
    } catch (_) {
      // A failed read must degrade to "unknown OEM" (skip the autostart step),
      // never crash onboarding.
      return '';
    }
  }
}
