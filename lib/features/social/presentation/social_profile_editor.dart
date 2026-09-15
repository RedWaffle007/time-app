import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';

/// The public/private toggle for the profile.
///
/// It is the ONE control on the Edit Profile screen's "Public profile" section
/// that is not part of the single Save draft, and that is deliberate: privacy is
/// a safety switch, and a user who flips it to Private and walks away must *be*
/// private. A switch sitting inside a draft that needs a Save is a switch people
/// believe is on when it is not — the same failure `AppLockTile` documents. So
/// it commits the instant it is flipped.
///
/// Username and bio (which used to live here, each with their own Save) now sit
/// in [ProfileEditScreen]'s single draft. The picture is `ProfileAvatarEditor`,
/// floated at the top of the screen as the page anchor.
class SocialProfileEditor extends ConsumerStatefulWidget {
  const SocialProfileEditor({super.key});

  @override
  ConsumerState<SocialProfileEditor> createState() =>
      _SocialProfileEditorState();
}

class _SocialProfileEditorState extends ConsumerState<SocialProfileEditor> {
  Future<void> _setPrivacy(UserProfile profile, bool isPublic) async {
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateSocialProfile(
            uid: profile.uid,
            isPublic: isPublic,
            // The COMMITTED bio, not any half-typed draft: flipping privacy must
            // not silently commit a bio the user has not pressed Save on.
            bio: profile.bio,
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

    final muted = context.colors.onSurfaceVariant;
    return SwitchListTile(
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
      onChanged: (value) => _setPrivacy(profile, value),
    );
  }
}
