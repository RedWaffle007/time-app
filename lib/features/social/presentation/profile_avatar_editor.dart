import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../application/social_providers.dart';
import '../data/avatar_uploader.dart';
import '../data/worker_avatar_uploader.dart';
import '../domain/avatar.dart';
import 'avatar_image.dart';

/// The profile-picture control — display plus pick / crop / upload / remove.
///
/// Extracted from `SocialProfileEditor` so the Edit Profile screen can float it
/// at the TOP as the page's visual anchor, above the identity fields, while the
/// social editor keeps username / bio / privacy. It owns ALL the avatar logic,
/// so there is one place that uploads a picture, not two.
///
/// **The avatar is uploaded IMMEDIATELY** — it is not gated by either Save on
/// the screen. That is why it can live apart from the social editor's Save
/// without changing anything: picking a photo stores it and writes the profile
/// then and there.
///
/// The static-vs-animated split is the rule recorded in DECISIONS.md
/// (2026-08-23): JPEG/PNG go through the crop+zoom UI, which downscales and
/// compresses; GIF/WebP are never re-encoded (it would flatten the animation)
/// and are size-capped instead.
class ProfileAvatarEditor extends ConsumerStatefulWidget {
  const ProfileAvatarEditor({super.key});

  @override
  ConsumerState<ProfileAvatarEditor> createState() =>
      _ProfileAvatarEditorState();
}

class _ProfileAvatarEditorState extends ConsumerState<ProfileAvatarEditor> {
  bool _uploading = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) return const SizedBox.shrink();

    final muted = context.colors.onSurfaceVariant;
    final animatedNote = profile.avatar?.isAnimatedCapable ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: Sizes.avatarEditable,
          height: Sizes.avatarEditable,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AvatarImage(profile: profile, size: Sizes.avatarEditable),
              if (_uploading) const CircularProgressIndicator(),
            ],
          ),
        ),
        const SizedBox(height: Space.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              onPressed: _uploading ? null : () => _pickAndUpload(profile),
              icon: const Icon(AppIcons.editPhoto),
              label: Text(profile.hasStoredAvatar ? 'Change' : 'Add photo'),
            ),
            if (profile.hasStoredAvatar) ...[
              const SizedBox(width: Space.sm),
              TextButton.icon(
                onPressed: _uploading ? null : () => _removePicture(profile),
                icon: const Icon(AppIcons.removePhoto),
                label: const Text('Remove'),
              ),
            ],
          ],
        ),
        const SizedBox(height: Space.xs),
        Text(
          animatedNote
              ? 'Animated pictures play on your profile.'
              : 'JPEG, PNG, GIF or WebP. GIFs and WebP can be animated.',
          textAlign: TextAlign.center,
          style: context.text.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }

  Future<void> _pickAndUpload(UserProfile profile) async {
    // Pick WITHOUT re-encoding at pick time — `imageQuality`/`maxWidth` would
    // flatten an animated GIF or WebP. Any resizing happens AFTER, and only for
    // static images (see below).
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (mounted) _toast('Could not open the picker. $e');
      return;
    }
    if (picked == null) return;

    // The static-vs-animated split (DECISIONS.md 2026-08-23). GIF/WebP MUST NOT
    // be re-encoded — cropping or compressing them loses the animation — so they
    // take the direct path and a size cap. JPEG/PNG go through the crop+zoom UI,
    // which downscales and compresses, and is what lets a large camera photo in.
    final Uint8List bytes;
    final String mime;
    if (kAnimatedCapableMimes.contains(_mimeFor(picked))) {
      mime = _mimeFor(picked);
      bytes = await picked.readAsBytes();
    } else {
      final cropped = await _cropStatic(picked);
      if (cropped == null) return; // the user backed out of the cropper
      // The crop re-encodes to JPEG, so that is the true type regardless of what
      // was picked — declare it honestly (the Worker sniffs bytes anyway).
      mime = 'image/jpeg';
      bytes = cropped;
    }

    setState(() => _uploading = true);
    try {
      // Pre-flight before the upload, so an oversized file fails in a moment
      // rather than after a minute. Static images are already compressed by the
      // cropper, so in practice this only ever catches an over-cap ANIMATED file.
      // The Worker repeats every check — see WorkerAvatarUploader.
      final rejection = checkAvatarUpload(mime: mime, bytes: bytes.length);
      if (rejection != AvatarRejection.none) {
        if (mounted) _toast(describeAvatarRejection(rejection, mime));
        return;
      }

      final avatar = await ref
          .read(avatarUploaderProvider)
          .upload(
            bytes: bytes,
            mime: mime,
            previousKey: profile.avatar?.storageKey,
          );

      // Written only AFTER the bytes are stored and a URL exists. The reverse
      // order puts a URL on the profile that 404s for everyone who loads it
      // before the upload lands.
      await ref
          .read(profileRepositoryProvider)
          .setAvatar(uid: profile.uid, avatar: avatar);
      // The stream normally receives Firestore's local write immediately. An
      // explicit refresh also covers a listener that was briefly disconnected
      // while the upload finished, so the editor and every shared avatar surface
      // resolve the newly stored metadata rather than retaining the picker-time
      // snapshot.
      ref.invalidate(profileProvider);
    } on AvatarUploadFailure catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('Upload failed. $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Crop (square, with zoom), downscale and compress a STATIC image. Returns
  /// null if the user cancelled. Only ever called for JPEG/PNG — never for an
  /// animated format, which this would flatten to a single frame.
  Future<Uint8List?> _cropStatic(XFile picked) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      // A square output matches the rounded-square avatar, and the 1024 cap plus
      // JPEG q85 is what brings a multi-megabyte camera photo under the 2MB cap.
      maxWidth: 1024,
      maxHeight: 1024,
      compressQuality: 85,
      compressFormat: ImageCompressFormat.jpg,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(toolbarTitle: 'Crop photo', lockAspectRatio: true),
        IOSUiSettings(title: 'Crop photo', aspectRatioLockEnabled: true),
      ],
    );
    if (cropped == null) return null;
    return cropped.readAsBytes();
  }

  Future<void> _removePicture(UserProfile profile) async {
    final key = profile.avatar?.storageKey;
    // The profile field is cleared FIRST. The object deletion is best-effort
    // (see AvatarUploader.remove): the user asked for the picture to be gone
    // from their profile, and a bucket that would not delete must not stop that
    // happening.
    await ref.read(profileRepositoryProvider).clearAvatar(profile.uid);
    ref.invalidate(profileProvider);
    if (key != null && key.isNotEmpty) {
      await ref.read(avatarUploaderProvider).remove(storageKey: key);
    }
  }

  /// The MIME type, from the picked file's extension.
  ///
  /// `XFile.mimeType` is null on Android for gallery picks often enough that
  /// trusting it would reject valid files, so the extension is the fallback.
  /// Either way the Worker sniffs the actual bytes — a client-declared MIME is a
  /// hint, never a fact.
  String _mimeFor(XFile file) {
    final declared = file.mimeType;
    if (declared != null && isAllowedAvatarMime(declared)) return declared;
    final name = file.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    final ext = dot == -1 ? '' : name.substring(dot + 1);
    return kAvatarMimeByExtension[ext] ?? '';
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
