import 'package:cloud_firestore/cloud_firestore.dart';

import '../../social/domain/avatar.dart';

/// A user's profile, stored at `users/{uid}` in Firestore.
///
/// Beyond name/avatar/home-timezone, the profile carries the user's optional
/// **quiet hours** — a window (set by the user themselves) during which a
/// planner is warned before scheduling. See [quietHoursStartMinutes].
///
/// **The social fields ([username], [bio], [isPublic], [avatar]) live on this
/// document rather than a separate one**, because everything here is already
/// readable by any signed-in user who knows the uid (`allow get: if signedIn()`
/// — the planner needs the target's name and home timezone, and vice versa).
/// Adding public-by-nature fields to a public-by-design document costs nothing
/// and saves a second read on every profile view.
///
/// **What must NEVER be added here is anything the privacy toggle governs.**
/// [isPublic] cannot protect a field on this document, because the document's
/// own read rule does not consult it. Statistics therefore live at
/// `users/{uid}/profileStats/summary`, which has its own gated rule. Putting a
/// number here "just for convenience" would silently publish it to every signed-
/// in user and make the privacy switch a decoration.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.homeTimezone,
    this.avatarUrl,
    this.quietHoursStartMinutes,
    this.quietHoursEndMinutes,
    this.username,
    this.bio,
    this.isPublic = false,
    this.avatar,
  });

  final String uid;

  /// The display name, exactly as typed. **This is the display name** — there
  /// is deliberately no separate `displayName` field. `name` is already
  /// required, already server-enforced, and already rendered on every roster,
  /// card and notification; a second name field would mean two sources of truth
  /// for one fact and a migration to decide which existing rows meant which.
  final String name;

  /// IANA timezone name, e.g. "Asia/Karachi". Required — the app's premise
  /// depends on knowing the target's local time.
  final String homeTimezone;

  /// The Google account photo, captured at first sign-in.
  ///
  /// Superseded by [avatar] when the user uploads one. Kept as the fallback
  /// rather than migrated: it costs one nullable string, it is the only picture
  /// most users will ever have, and dropping it would blank every existing
  /// profile the moment this shipped. [displayAvatarUrl] resolves the two.
  final String? avatarUrl;

  /// Quiet-hours window as minutes-since-local-midnight (0–1439), in the user's
  /// own [homeTimezone]. Both null → no window set. The window may wrap past
  /// midnight (start > end), e.g. 22:00→07:00. Warning-only for now:
  /// enforcement (actually blocking an alarm) arrives with the alarm layer.
  final int? quietHoursStartMinutes;
  final int? quietHoursEndMinutes;

  /// The unique handle, in canonical (lowercase) form. Null until claimed.
  ///
  /// A **mirror** of the authoritative reservation at `usernames/{handle}`.
  /// This copy exists so rendering a profile needs one read instead of a
  /// reverse lookup; the reservation is what actually guarantees uniqueness.
  /// The two are written in one transaction — see [UsernameRepository.claim].
  final String? username;

  /// Free text the user writes about themselves. Length-capped in the rules.
  final String? bio;

  /// The privacy toggle. **Private by default** — `false` is the value an
  /// existing profile with no such field decodes to, so shipping this feature
  /// does not silently make anyone's numbers public.
  ///
  /// Governs the *stats* subcollection only. Name, avatar and timezone remain
  /// readable by uid regardless, because the delegation loop needs them.
  final bool isPublic;

  /// An uploaded profile picture, if there is one. Takes precedence over
  /// [avatarUrl].
  final ProfileAvatar? avatar;

  bool get hasQuietHours =>
      quietHoursStartMinutes != null && quietHoursEndMinutes != null;

  /// A profile is only usable once it has a name, a home timezone AND a
  /// username.
  ///
  /// The username requirement was added 2026-08-24 (DECISIONS.md "Mandatory
  /// username at onboarding"): an account with no handle cannot be found by
  /// search, so it can send requests but never be added back — a dead end. This
  /// deliberately routes EXISTING handle-less accounts through
  /// `CompleteProfileScreen` once, to set a handle, which is the intended
  /// "no account without a handle" behaviour rather than a regression.
  bool get isComplete =>
      name.trim().isNotEmpty &&
      homeTimezone.trim().isNotEmpty &&
      (username?.trim().isNotEmpty ?? false);

  /// The picture to draw, or null for the initial-letter fallback.
  ///
  /// Uploaded picture first, but only when it is [ProfileAvatar.isDisplayable]
  /// — a withheld or rejected upload falls back to the Google photo rather than
  /// to a blank, which keeps a moderation action from looking like a bug.
  String? get displayAvatarUrl {
    final uploaded = avatar;
    if (uploaded != null && uploaded.isDisplayable) return uploaded.url;
    final google = avatarUrl;
    return (google != null && google.isNotEmpty) ? google : null;
  }

  /// Whether an uploaded avatar map with an image URL is actually stored.
  ///
  /// This intentionally differs from [displayAvatarUrl]: a withheld or
  /// rejected upload is not displayable, but it is still the owner's stored
  /// picture and therefore may be removed. Keeping this fact named prevents
  /// controls from using a nullable map as a proxy for a visible image.
  bool get hasStoredAvatar => avatar != null && avatar!.url.isNotEmpty;

  /// The handle rendered for display, with its `@`. Falls back to nothing.
  String? get handle => username == null ? null : '@$username';

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return UserProfile(
      uid: doc.id,
      name: (data['name'] ?? '') as String,
      homeTimezone: (data['homeTimezone'] ?? '') as String,
      avatarUrl: data['avatarUrl'] as String?,
      quietHoursStartMinutes: (data['quietHoursStartMinutes'] as num?)?.toInt(),
      quietHoursEndMinutes: (data['quietHoursEndMinutes'] as num?)?.toInt(),
      username: data['username'] as String?,
      bio: data['bio'] as String?,
      isPublic: (data['isPublic'] ?? false) as bool,
      avatar: ProfileAvatar.fromMap(data['avatar'] as Map<String, dynamic>?),
    );
  }
}
