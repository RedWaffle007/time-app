// Named public collaborators keep call sites legible; private initializing
// formals would expose unusable `_sound:`-style parameter names.
// ignore_for_file: prefer_initializing_formals

import '../../../routing/app_router.dart';
import '../data/alarm_sound.dart';

/// Shows the alarm screen for a plan that is RINGING while the app is open
/// (R5, 2026-10-02).
///
/// The ringing service names who and what only through its notification, and
/// Android turns that into a heads-up while the phone is in use, which HyperOS
/// hides by default ("Floating notifications" off). The result was a tone with
/// nothing on screen. So the app opens the alarm itself: when a ring starts
/// while it is alive, and when it is opened or resumed mid-ring. Never twice
/// for the alarm already on screen.
class AlarmRingingPresenter {
  AlarmRingingPresenter({
    required AlarmSound sound,
    required void Function(String itemId) open,
    required Uri? Function() currentLocation,
  }) : _sound = sound,
       _open = open,
       _currentLocation = currentLocation;

  final AlarmSound _sound;
  final void Function(String itemId) _open;
  final Uri? Function() _currentLocation;

  void start() => _sound.onRinging(show);

  void dispose() => _sound.onRinging(null);

  /// App start or resume: is something ringing that is not on screen?
  Future<void> checkNow() async {
    final itemId = await _sound.ringingItem();
    if (itemId != null) show(itemId);
  }

  void show(String itemId) {
    if (itemId.isEmpty) return;
    final here = _currentLocation();
    if (here != null &&
        here.path == Routes.alarm &&
        here.queryParameters[Routes.alarmItemParam] == itemId) {
      return;
    }
    _open(itemId);
  }
}
