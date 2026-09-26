import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format/device_clock_localizations.dart';

/// The phone's REAL 12/24-hour clock setting (item F1, 2026-09-26), read from
/// Android's `DateFormat.is24HourFormat`. Flutter alone only knows "forced
/// 24-hour"; a 12-hour phone in a 24-hour-default language looked 24-hour.
class DeviceClock {
  const DeviceClock();

  static const _channel = MethodChannel('time_app/clock');

  /// Null when unknown (no native side): callers keep Flutter's own value.
  Future<bool?> is24Hour() async {
    try {
      return await _channel.invokeMethod<bool>('is24Hour');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('DeviceClock: $e');
      return null;
    }
  }
}

/// Read in main() before runApp (the first frame must already be right).
final deviceClockInitialProvider = Provider<bool?>((ref) => null);

final deviceClockProvider = Provider<DeviceClock>((ref) => const DeviceClock());

/// The live setting; refreshed on resume (it can change in Settings).
final deviceUses24HourProvider =
    NotifierProvider<DeviceUses24HourController, bool?>(
      DeviceUses24HourController.new,
    );

class DeviceUses24HourController extends Notifier<bool?> {
  @override
  bool? build() => ref.watch(deviceClockInitialProvider);

  Future<void> refresh() async {
    final value = await ref.read(deviceClockProvider).is24Hour();
    if (value != null && value != state) state = value;
  }
}

/// Applies the phone's clock to everything below: the format helper (via
/// MediaQuery) and the Material time picker (via localizations). With an
/// unknown setting it changes nothing.
class DeviceClockScope extends StatelessWidget {
  const DeviceClockScope({
    super.key,
    required this.use24Hour,
    required this.child,
  });

  final bool? use24Hour;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final use24 = use24Hour;
    if (use24 == null) return child;
    final base = MaterialLocalizations.of(context);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24),
      child: Localizations.override(
        context: context,
        delegates: [_DeviceClockDelegate(base, use24)],
        child: child,
      ),
    );
  }
}

class _DeviceClockDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _DeviceClockDelegate(this.base, this.use24);

  final MaterialLocalizations base;
  final bool use24;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture(
    DeviceClockMaterialLocalizations(base, use24Hour: use24),
  );

  @override
  bool shouldReload(_DeviceClockDelegate old) =>
      old.use24 != use24 || old.base != base;
}
