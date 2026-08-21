import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/reminder.dart';

/// **The durable local mirror: what this app believes the OS is holding.**
///
/// It exists because *Android cannot be asked*. There is no reliable "list my
/// scheduled alarms" — `pendingNotificationRequests()` reports
/// flutter_local_notifications' own bookkeeping, which is a different thing
/// from an AlarmManager registration and stays confidently wrong after a
/// reboot, an app update, or a revoked exact-alarm permission. Reconciling
/// against it would produce an app that is certain everything is scheduled and
/// notifies nobody.
///
/// So we keep our own record, and treat it as a BELIEF rather than as truth.
/// Reconciliation compares belief against desire and issues the difference; the
/// OS is told, never asked. Both directions of error are survivable and
/// deliberately asymmetric:
///
///   * mirror says scheduled, OS has nothing → that reminder is lost until the
///     next re-schedule. This is the failure worth engineering against, and it
///     is why the fingerprint includes everything, and why the boot receivers
///     exist.
///   * mirror says nothing, OS has it → we schedule again under the same
///     deterministic id, which REPLACES rather than duplicates. Harmless.
///
/// Local, not Firestore, for the same reason `app_lock_store.dart` is: this is a
/// fact about *this phone*. The same account on a second device has its own OS
/// alarms, and syncing one device's belief to another would be actively wrong.
abstract interface class ReminderMirrorStore {
  Future<List<ScheduledReminder>> load();
  Future<void> save(List<ScheduledReminder> reminders);
  Future<void> clear();
}

class SharedPrefsReminderMirrorStore implements ReminderMirrorStore {
  const SharedPrefsReminderMirrorStore();

  static const _key = 'reminder_mirror_v1';

  @override
  Future<List<ScheduledReminder>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ScheduledReminder.decode(prefs.getString(_key));
    } catch (e) {
      // Read as empty. The consequence is that everything gets re-scheduled,
      // which is the recoverable direction (see the class doc).
      debugPrint('ReminderMirrorStore: load failed: $e');
      return const [];
    }
  }

  @override
  Future<void> save(List<ScheduledReminder> reminders) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, ScheduledReminder.encode(reminders));
    } catch (e) {
      debugPrint('ReminderMirrorStore: save failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      debugPrint('ReminderMirrorStore: clear failed: $e');
    }
  }
}

/// In-memory mirror, for tests and for any platform with no reminder support.
class InMemoryReminderMirrorStore implements ReminderMirrorStore {
  List<ScheduledReminder> _reminders = const [];

  @override
  Future<List<ScheduledReminder>> load() async => _reminders;

  @override
  Future<void> save(List<ScheduledReminder> reminders) async {
    _reminders = List.unmodifiable(reminders);
  }

  @override
  Future<void> clear() async => _reminders = const [];
}
