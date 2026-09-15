import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/notify_config.dart';
import '../domain/avatar.dart';
import 'avatar_uploader.dart';

/// Uploads through the **existing Cloudflare Worker**, which stores the object
/// in Supabase Storage and returns its public URL.
///
/// ### Why this shape, and not a direct upload from the phone
///
/// Supabase's storage authorisation is its own JWT; it has never heard of a
/// Firebase uid. Reconciling them from the client would mean shipping either a
/// Supabase key inside the APK — extractable in minutes, and it would be a
/// write key — or a second sign-in the user has to complete. Neither is
/// acceptable for a profile picture.
///
/// The Worker already solves precisely this problem for push: it verifies a
/// Firebase ID token and holds privileged credentials that never leave
/// Cloudflare. Reusing it means the phone proves who it is with the token it
/// already has, and the storage key stays a Worker secret.
///
/// It also puts the size and format caps somewhere they cannot be bypassed.
/// [checkAvatarUpload] runs on this side too, but only so the user hears "that
/// file is too large" before waiting through an upload — the Worker repeats
/// every check against the bytes it actually receives, and that copy is the one
/// that counts.
///
/// ### Why Supabase
///
/// It was picked against three constraints: free without a payment card
/// (Cloudflare R2 fails this), genuinely open source and self-hostable
/// (Cloudinary and ImgBB fail this), and able to serve animated GIF and WebP
/// untouched. Supabase Storage is Apache-2.0, has a 1 GB no-card free tier, and
/// is plain object storage — so an animated file is served back byte-for-byte.
///
/// **No image transformation is requested, ever.** Supabase's transform API is
/// a paid feature, and resizing an animated image server-side is the standard
/// way to silently flatten it to a single frame. Originals only; the UI scales
/// them for display.
class WorkerAvatarUploader implements AvatarUploader {
  const WorkerAvatarUploader();

  /// Where the Worker's avatar routes live. Derived from the notify endpoint
  /// rather than configured separately — it is the same Worker, and two
  /// constants that must agree is one constant too many.
  static Uri? _endpoint(String path) {
    if (kNotifyEndpoint.isEmpty) return null;
    final base = Uri.parse(kNotifyEndpoint);
    return base.replace(path: path);
  }

  static const _timeout = Duration(seconds: 60);

  @override
  Future<ProfileAvatar> upload({
    required Uint8List bytes,
    required String mime,
    String? previousKey,
  }) async {
    // Pre-flight, so an oversized file fails instantly instead of after a
    // 5 MB upload. Not the authoritative check — see the class doc.
    final rejection = checkAvatarUpload(mime: mime, bytes: bytes.length);
    if (rejection != AvatarRejection.none) {
      throw AvatarUploadFailure(describeAvatarRejection(rejection, mime));
    }

    final uri = _endpoint('/avatar');
    if (uri == null) {
      throw const AvatarUploadFailure(
        'Picture uploads are not set up yet on this build.',
      );
    }

    final idToken = await _idToken();

    final http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': mime,
              // The Worker deletes this object after the new one is stored.
              // A header rather than a body field because the body IS the
              // image — there is nowhere else to put it.
              if (previousKey != null && previousKey.isNotEmpty)
                'X-Previous-Key': previousKey,
            },
            body: bytes,
          )
          .timeout(_timeout);
    } catch (e) {
      throw AvatarUploadFailure('Could not reach the server. $e');
    }

    if (response.statusCode != 200) {
      throw AvatarUploadFailure(
        describeAvatarUploadFailure(response.statusCode, response.body),
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AvatarUploadFailure(
        'The server sent back something unreadable.',
      );
    }

    final url = body['url'] as String?;
    final key = body['key'] as String?;
    if (url == null || url.isEmpty || key == null || key.isEmpty) {
      throw const AvatarUploadFailure(
        'The upload finished but returned no picture.',
      );
    }

    return ProfileAvatar(
      url: url,
      storageKey: key,
      mime: (body['mime'] as String?) ?? mime,
      sizeBytes: (body['sizeBytes'] as num?)?.toInt() ?? bytes.length,
      // Approved on arrival. See [AvatarModeration] for why the default is not
      // `pending`: there is no moderation queue, so pending would mean nobody's
      // picture is ever shown.
      moderation: AvatarModeration.approved,
    );
  }

  @override
  Future<void> remove({required String storageKey}) async {
    final uri = _endpoint('/avatar');
    if (uri == null || storageKey.isEmpty) return;

    final idToken = await _idToken();
    try {
      await http
          .delete(
            uri,
            headers: {
              'Authorization': 'Bearer $idToken',
              'X-Storage-Key': storageKey,
            },
          )
          .timeout(_timeout);
    } catch (_) {
      // Best-effort, and it must be. The profile field is cleared either way,
      // so the user's picture is gone from every view; what a failure here
      // leaves behind is an orphaned object in a bucket, which is a cleanup
      // problem and not the user's. Throwing would refuse to remove a picture
      // because the file could not be deleted — the wrong way round.
    }
  }

  Future<String> _idToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const AvatarUploadFailure('You are signed out.');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw const AvatarUploadFailure(
        'Could not confirm who you are. Try again.',
      );
    }
    return token;
  }
}

/// Converts the Worker's deliberately small public error vocabulary into
/// actionable copy without trusting or displaying a provider response body.
String describeAvatarUploadFailure(int statusCode, String responseBody) {
  String? error;
  String? reason;
  try {
    final body = jsonDecode(responseBody);
    if (body is Map<String, dynamic>) {
      error = body['error'] as String?;
      reason = body['reason'] as String?;
    }
  } catch (_) {
    // A gateway may replace the Worker JSON with HTML. Its body is never shown.
  }

  switch (statusCode) {
    case 401:
      return 'Your session expired. Sign in again and retry.';
    case 413:
      return 'That picture is too large.';
    case 415:
      return 'That file type is not supported. Use JPEG, PNG, GIF or WebP.';
    case 429:
      return 'Too many uploads just now. Try again in a minute.';
    case 500:
      if (error == 'storage-not-configured') {
        return 'Avatar storage is not configured on the server yet.';
      }
      return 'The avatar backend failed. Your picture was not changed.';
    case 502:
      if (error == 'store-failed') {
        return switch (reason) {
          'storage-authorization-failed' =>
            'Avatar storage rejected the upload. Your picture was not changed.',
          'storage-bucket-not-found' =>
            'Avatar storage is unavailable. Your picture was not changed.',
          _ => 'Avatar storage is temporarily unavailable. Try again.',
        };
      }
      return 'The avatar storage service is unavailable. Try again.';
    default:
      return 'The upload failed ($statusCode). Try again.';
  }
}

/// User-facing copy for a pre-flight rejection. Interpolates the caps from
/// `avatar.dart` so the message cannot disagree with the rule.
String describeAvatarRejection(AvatarRejection rejection, String mime) {
  switch (rejection) {
    case AvatarRejection.none:
      return '';
    case AvatarRejection.empty:
      return 'That file is empty.';
    case AvatarRejection.unsupportedFormat:
      return 'Use a JPEG, PNG, GIF or WebP image.';
    case AvatarRejection.tooLarge:
      final mb = avatarMaxBytesFor(mime) ~/ (1024 * 1024);
      // Static photos are cropped and compressed before this check, so a
      // too-large file here is almost always an ANIMATED one — say why it can't
      // just be shrunk.
      if (kAnimatedCapableMimes.contains(mime)) {
        return 'That animated image is over ${mb}MB. It can\'t be compressed '
            'without losing the animation — try a shorter or smaller one.';
      }
      return 'That picture is over ${mb}MB. Pick a smaller one.';
  }
}
