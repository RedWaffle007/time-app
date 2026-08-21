/// **Profile picture limits and metadata.**
///
/// The caps live in `domain/` because, exactly like [validateUsername], they are
/// asserted in three places that must agree: the picker (refuse before
/// uploading), the Worker (refuse authoritatively — the only one that counts),
/// and `firestore.rules` (refuse a metadata document claiming a size the
/// storage never accepted).
///
/// **Animated formats get a larger cap than static ones**, which is a real
/// decision rather than an oversight. A 200×200 still that needs more than 2 MB
/// is a badly exported file; an animated WebP or GIF of the same dimensions
/// legitimately needs several times that because it carries frames. One shared
/// cap would either ban animation in practice or wave through enormous stills.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

/// The formats accepted for a profile picture.
///
/// Animated GIF and animated WebP are both here because they were asked for and
/// because Flutter's `Image` decodes and plays both natively — no package, no
/// transcoding, no frame extraction. The bytes are stored and served untouched,
/// which is also why no image transformation is applied anywhere: resizing an
/// animated file server-side is the fastest way to accidentally flatten it to
/// one frame.
const Map<String, String> kAvatarMimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

/// MIME types that may carry animation, and therefore get [kAvatarMaxBytesAnimated].
///
/// `image/webp` is here even though most WebP files are still. Nothing can tell
/// the two apart without decoding the container, and doing that on the client
/// would be a check the Worker still could not trust — so the format is judged,
/// not the file. The cost is that a static WebP may be up to 5 MB; the
/// alternative is rejecting animated WebP outright.
const Set<String> kAnimatedCapableMimes = {'image/gif', 'image/webp'};

/// Cap for a still image. 2 MB.
const int kAvatarMaxBytesStatic = 2 * 1024 * 1024;

/// Cap for a format that may be animated. 5 MB.
const int kAvatarMaxBytesAnimated = 5 * 1024 * 1024;

/// The cap that applies to [mime]. Unknown types get the stricter one — an
/// unrecognised format should never buy a larger allowance.
int avatarMaxBytesFor(String mime) => kAnimatedCapableMimes.contains(mime)
    ? kAvatarMaxBytesAnimated
    : kAvatarMaxBytesStatic;

/// Whether [mime] is an accepted avatar format at all.
bool isAllowedAvatarMime(String mime) =>
    kAvatarMimeByExtension.values.contains(mime);

/// Why an upload was refused before it started, or [none].
enum AvatarRejection { none, unsupportedFormat, tooLarge, empty }

/// Client-side pre-flight. Advisory: the Worker repeats every one of these
/// checks against the bytes it actually receives, because a client check is a
/// courtesy and a server check is a control.
AvatarRejection checkAvatarUpload({required String mime, required int bytes}) {
  if (bytes <= 0) return AvatarRejection.empty;
  if (!isAllowedAvatarMime(mime)) return AvatarRejection.unsupportedFormat;
  if (bytes > avatarMaxBytesFor(mime)) return AvatarRejection.tooLarge;
  return AvatarRejection.none;
}

/// The moderation state of an uploaded picture.
///
/// **Nothing automated reviews these today, and the enum does not pretend
/// otherwise.** It exists so that (a) a human can act on a report by writing
/// one field, and (b) the read path already branches on it — so adding a
/// classifier later changes who writes the field, not who reads it.
///
/// The default is [approved], not [pending], and that is a considered choice
/// for this app's shape: there is no moderation queue and no moderator, so
/// defaulting to `pending` would leave every picture in the app permanently
/// unshown. Pictures are visible to friends and — for public profiles — to
/// signed-in users, which is a small blast radius, and [flagged] plus a report
/// gives a real path to take one down.
enum AvatarModeration {
  /// Visible. The default on upload.
  approved,

  /// Reported by a user, awaiting review. Still visible — a report is an
  /// accusation, not a finding, and hiding on accusation alone is a griefing
  /// tool.
  flagged,

  /// Withheld pending review. Renders as the fallback initial.
  pending,

  /// Reviewed and refused. Renders as the fallback initial, permanently.
  rejected,
}

/// A stored profile picture and everything known about it.
class ProfileAvatar {
  const ProfileAvatar({
    required this.url,
    required this.storageKey,
    required this.mime,
    required this.sizeBytes,
    this.moderation = AvatarModeration.approved,
    this.updatedAt,
  });

  /// Public URL the image loads from.
  final String url;

  /// The object's key in the bucket. Kept so a replacement can delete the file
  /// it supersedes — without it, every re-upload would leak the previous
  /// object and the free tier would fill with orphans.
  final String storageKey;

  final String mime;
  final int sizeBytes;
  final AvatarModeration moderation;
  final DateTime? updatedAt;

  /// Whether this picture should actually be drawn.
  bool get isDisplayable =>
      url.isNotEmpty &&
      (moderation == AvatarModeration.approved ||
          moderation == AvatarModeration.flagged);

  bool get isAnimatedCapable => kAnimatedCapableMimes.contains(mime);

  static ProfileAvatar? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final url = (m['url'] ?? '') as String;
    if (url.isEmpty) return null;
    return ProfileAvatar(
      url: url,
      storageKey: (m['storageKey'] ?? '') as String,
      mime: (m['mime'] ?? '') as String,
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      moderation: AvatarModeration.values.firstWhere(
        (s) => s.name == m['moderation'],
        // An unreadable moderation state must fail CLOSED — withhold the
        // image. The opposite default would make a corrupt field a way to
        // display a rejected picture.
        orElse: () => AvatarModeration.pending,
      ),
      updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'url': url,
        'storageKey': storageKey,
        'mime': mime,
        'sizeBytes': sizeBytes,
        'moderation': moderation.name,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}
