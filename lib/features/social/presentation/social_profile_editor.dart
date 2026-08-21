import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../application/social_providers.dart';
import '../data/avatar_uploader.dart';
import '../data/username_repository.dart';
import '../data/worker_avatar_uploader.dart';
import '../domain/avatar.dart';
import '../domain/username.dart';
import 'avatar_image.dart';

/// The social half of the profile form: picture, username, bio, privacy.
///
/// Embedded by `ProfileEditScreen` beneath the identity form (name, timezone,
/// quiet hours) rather than replacing it. The two halves are edited and saved
/// separately on purpose — folding them together would mean every privacy
/// change also rewrote the user's timezone, and a concurrent edit on another
/// device would silently lose one of them.
///
/// **Three different save behaviours, and each is deliberate:**
///
///   * **Picture — instant.** It is an upload with its own progress; there is
///     nothing to draft.
///   * **Privacy — instant.** This is the one that matters. It is a safety
///     control, and a user who flips it to Private and walks away must *be*
///     private. A switch sitting inside a draft that needs a Save is a switch
///     people believe is on when it is not — the same failure `AppLockTile`
///     documents on the screen directly above this one.
///   * **Username and bio — explicit Save.** Both are text being composed, and
///     saving mid-keystroke would claim a half-typed handle. The username claim
///     can also *fail* (someone else got there first), which needs a button to
///     hang the error on.
class SocialProfileEditor extends ConsumerStatefulWidget {
  const SocialProfileEditor({super.key});

  @override
  ConsumerState<SocialProfileEditor> createState() =>
      _SocialProfileEditorState();
}

class _SocialProfileEditorState extends ConsumerState<SocialProfileEditor> {
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();

  bool _initialised = false;
  bool _savingText = false;
  bool _uploading = false;
  String? _textError;
  String? _savedUsername;
  String _savedBio = '';

  /// Bio length cap, mirrored in `firestore.rules`.
  ///
  /// 300 characters is a paragraph — enough to say who you are, short enough
  /// that a profile header stays a header. The rule enforces it; this makes the
  /// counter honest and stops a Save that would be denied.
  static const _maxBioLength = 300;

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  String? get _usernameError {
    final raw = _usernameController.text.trim();
    if (raw.isEmpty) return null; // Optional — see UserProfile.isComplete.
    final problem = validateUsername(canonicalUsername(raw));
    return problem == UsernameProblem.none
        ? null
        : describeUsernameProblem(problem);
  }

  bool get _textDirty =>
      canonicalUsername(_usernameController.text) != (_savedUsername ?? '') ||
      _bioController.text.trim() != _savedBio.trim();

  bool get _canSaveText =>
      _textDirty &&
      !_savingText &&
      _usernameError == null &&
      _bioController.text.length <= _maxBioLength;

  Future<void> _saveText(UserProfile profile) async {
    setState(() {
      _savingText = true;
      _textError = null;
    });
    try {
      final wanted = canonicalUsername(_usernameController.text);

      // Claim the handle FIRST. It is the write that can be refused, and doing
      // it before the bio means a rejected claim leaves nothing half-saved —
      // the alternative order writes the bio, fails on the handle, and leaves
      // the user unsure which of the two took effect.
      if (wanted.isNotEmpty && wanted != (_savedUsername ?? '')) {
        await ref.read(usernameRepositoryProvider).claim(
              uid: profile.uid,
              rawHandle: wanted,
              previousHandle: _savedUsername,
            );
      }

      await ref.read(profileRepositoryProvider).updateSocialProfile(
            uid: profile.uid,
            isPublic: profile.isPublic,
            bio: _bioController.text,
          );

      if (!mounted) return;
      setState(() {
        _savedUsername = wanted.isEmpty ? _savedUsername : wanted;
        _savedBio = _bioController.text.trim();
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Profile saved')));
    } on UsernameUnavailable catch (e) {
      if (mounted) setState(() => _textError = e.message);
    } catch (e) {
      if (mounted) setState(() => _textError = 'Could not save. $e');
    } finally {
      if (mounted) setState(() => _savingText = false);
    }
  }

  Future<void> _setPrivacy(UserProfile profile, bool isPublic) async {
    try {
      await ref.read(profileRepositoryProvider).updateSocialProfile(
            uid: profile.uid,
            isPublic: isPublic,
            // The SAVED bio, not the field's current text: flipping a privacy
            // switch must not silently commit a half-typed bio the user has
            // not pressed Save on.
            bio: _savedBio,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Could not change privacy. $e')),
          );
      }
    }
  }

  Future<void> _pickAndUpload(UserProfile profile) async {
    // `imageQuality` and `maxWidth`/`maxHeight` are deliberately NOT passed.
    // Both make image_picker re-encode, which on an animated GIF or WebP
    // produces a single-frame still — silently discarding the animation this
    // feature exists to support.
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (mounted) _toast('Could not open the picker. $e');
      return;
    }
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final mime = _mimeFor(picked);

      // Pre-flight before the upload, so an oversized file fails in a moment
      // rather than after a minute. The Worker repeats every check — see
      // WorkerAvatarUploader.
      final rejection = checkAvatarUpload(mime: mime, bytes: bytes.length);
      if (rejection != AvatarRejection.none) {
        if (mounted) _toast(describeAvatarRejection(rejection, mime));
        return;
      }

      final avatar = await ref.read(avatarUploaderProvider).upload(
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
    } on AvatarUploadFailure catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('Upload failed. $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _removePicture(UserProfile profile) async {
    final key = profile.avatar?.storageKey;
    // The profile field is cleared FIRST. The object deletion is best-effort
    // (see AvatarUploader.remove): the user asked for the picture to be gone
    // from their profile, and a bucket that would not delete must not stop
    // that happening.
    await ref.read(profileRepositoryProvider).clearAvatar(profile.uid);
    if (key != null && key.isNotEmpty) {
      await ref.read(avatarUploaderProvider).remove(storageKey: key);
    }
  }

  /// The MIME type, from the picked file's extension.
  ///
  /// `XFile.mimeType` is null on Android for gallery picks often enough that
  /// trusting it would reject valid files, so the extension is the fallback.
  /// Either way the Worker sniffs the actual bytes — a client-declared MIME is
  /// a hint, never a fact.
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

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) return const SizedBox.shrink();

    if (!_initialised) {
      _usernameController.text = profile.username ?? '';
      _bioController.text = profile.bio ?? '';
      _savedUsername = profile.username;
      _savedBio = profile.bio ?? '';
      _initialised = true;
    }

    final muted = context.colors.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AvatarRow(
          profile: profile,
          uploading: _uploading,
          onPick: () => _pickAndUpload(profile),
          onRemove:
              profile.avatar == null ? null : () => _removePicture(profile),
        ),
        const SizedBox(height: Space.xl),
        TextField(
          controller: _usernameController,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: kUsernameMaxLength,
          decoration: InputDecoration(
            labelText: 'Username',
            prefixIcon: const Icon(AppIcons.username),
            helperText: 'How people find you. Lowercase letters, numbers and _',
            errorText: _usernameError,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _bioController,
          maxLines: 3,
          maxLength: _maxBioLength,
          decoration: const InputDecoration(
            labelText: 'About you',
            alignLabelWithHint: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.sm),
        FilledButton(
          onPressed: _canSaveText ? () => _saveText(profile) : null,
          child: _savingText
              ? const SizedBox(
                  height: Sizes.buttonSpinner,
                  width: Sizes.buttonSpinner,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save profile'),
        ),
        if (_textError != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            _textError!,
            style:
                context.text.bodyMedium?.copyWith(color: context.colors.error),
          ),
        ],
        const SizedBox(height: Space.md),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            profile.isPublic ? AppIcons.privacyPublic : AppIcons.privacyPrivate,
          ),
          title: const Text('Public profile'),
          subtitle: Text(
            profile.isPublic
                ? 'Anyone using the app can see your stats.'
                : 'Only friends can see your stats. Your name and picture stay '
                    'visible to people you share a group with.',
            style: context.text.bodySmall?.copyWith(color: muted),
          ),
          value: profile.isPublic,
          // Applies immediately — see the class doc for why this one is not
          // part of the draft above it.
          onChanged: (value) => _setPrivacy(profile, value),
        ),
      ],
    );
  }
}

class _AvatarRow extends StatelessWidget {
  const _AvatarRow({
    required this.profile,
    required this.uploading,
    required this.onPick,
    required this.onRemove,
  });

  final UserProfile profile;
  final bool uploading;
  final VoidCallback onPick;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    final animatedNote = profile.avatar?.isAnimatedCapable ?? false;

    return Row(
      children: [
        SizedBox(
          width: Sizes.avatarEditable,
          height: Sizes.avatarEditable,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AvatarImage(profile: profile, size: Sizes.avatarEditable),
              if (uploading) const CircularProgressIndicator(),
            ],
          ),
        ),
        const SizedBox(width: Space.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: uploading ? null : onPick,
                icon: const Icon(AppIcons.editPhoto),
                label: Text(profile.avatar == null ? 'Add photo' : 'Change'),
              ),
              if (onRemove != null)
                TextButton.icon(
                  onPressed: uploading ? null : onRemove,
                  icon: const Icon(AppIcons.removePhoto),
                  label: const Text('Remove'),
                ),
              const SizedBox(height: Space.xs),
              Text(
                animatedNote
                    ? 'Animated pictures play on your profile.'
                    : 'JPEG, PNG, GIF or WebP. GIFs and WebP can be animated.',
                style: context.text.labelSmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
