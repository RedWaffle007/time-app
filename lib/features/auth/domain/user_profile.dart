import 'package:cloud_firestore/cloud_firestore.dart';

/// A user's profile, stored at `users/{uid}` in Firestore.
///
/// Beyond name/avatar/home-timezone, the profile carries the user's optional
/// **quiet hours** — a window (set by the user themselves) during which a
/// planner is warned before scheduling. See [quietHoursStartMinutes].
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.homeTimezone,
    this.avatarUrl,
    this.quietHoursStartMinutes,
    this.quietHoursEndMinutes,
  });

  final String uid;
  final String name;

  /// IANA timezone name, e.g. "Asia/Karachi". Required — the app's premise
  /// depends on knowing the target's local time.
  final String homeTimezone;

  final String? avatarUrl;

  /// Quiet-hours window as minutes-since-local-midnight (0–1439), in the user's
  /// own [homeTimezone]. Both null → no window set. The window may wrap past
  /// midnight (start > end), e.g. 22:00→07:00. Warning-only for now:
  /// enforcement (actually blocking an alarm) arrives with the alarm layer.
  final int? quietHoursStartMinutes;
  final int? quietHoursEndMinutes;

  bool get hasQuietHours =>
      quietHoursStartMinutes != null && quietHoursEndMinutes != null;

  /// A profile is only usable once it has both a name and a home timezone.
  bool get isComplete => name.trim().isNotEmpty && homeTimezone.trim().isNotEmpty;

  factory UserProfile.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const {};
    return UserProfile(
      uid: doc.id,
      name: (data['name'] ?? '') as String,
      homeTimezone: (data['homeTimezone'] ?? '') as String,
      avatarUrl: data['avatarUrl'] as String?,
      quietHoursStartMinutes: (data['quietHoursStartMinutes'] as num?)?.toInt(),
      quietHoursEndMinutes: (data['quietHoursEndMinutes'] as num?)?.toInt(),
    );
  }
}
