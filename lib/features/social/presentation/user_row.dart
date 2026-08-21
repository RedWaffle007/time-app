import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import 'avatar_image.dart';

/// **One person, in a list.** Friends, search results, requests and blocked
/// users all draw this, so a person looks the same everywhere in the app.
///
/// It resolves the profile itself from a uid rather than taking one, because
/// every caller has a uid and none of them has a profile: a friendship stores
/// two uids, a request stores two uids, a block stores two uids. Making each
/// screen fetch profiles first would put the same `profileByUidProvider` watch
/// in four places.
///
/// **A profile that has not loaded renders as a row, not as nothing.** The
/// avatar falls back to its neutral placeholder and the name to a muted
/// "Loading…", so a list does not pop into existence one row at a time.
class UserRow extends ConsumerWidget {
  const UserRow({
    super.key,
    required this.uid,
    this.trailing,
    this.subtitle,
    this.onTap,
  });

  final String uid;

  /// Overrides the default chevron — used by rows whose action is a button
  /// (Accept / Decline) rather than a drill-in.
  final Widget? trailing;

  /// Overrides the handle line.
  final String? subtitle;

  /// Defaults to opening this person's profile.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByUidProvider(uid)).value;
    final muted = context.colors.onSurfaceVariant;

    final secondary = subtitle ?? profile?.handle;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: Space.xs),
      leading: AvatarImage(profile: profile, size: Sizes.avatarRow),
      title: Text(
        profile?.name ?? 'Loading…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: profile == null
            ? context.text.bodyLarge?.copyWith(color: muted)
            : null,
      ),
      subtitle: secondary == null
          ? null
          : Text(
              secondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: muted),
            ),
      trailing: trailing ?? const Icon(AppIcons.openRow),
      // Pushed, not `go`: a profile is a detail screen over whatever list
      // opened it, and Back must return to that list.
      onTap: onTap ?? () => context.push(Routes.userProfileFor(uid)),
    );
  }
}
