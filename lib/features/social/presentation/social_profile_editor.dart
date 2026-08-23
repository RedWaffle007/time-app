import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../application/social_providers.dart';
import '../data/username_repository.dart';
import '../domain/username.dart';

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
        // The profile PICTURE is not here — it is `ProfileAvatarEditor`, floated
        // at the top of the Edit Profile screen as the page anchor. This editor
        // owns username, bio and the privacy toggle only.
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
