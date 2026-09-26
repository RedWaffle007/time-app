import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../application/social_providers.dart';
import '../../plan_requests/application/plan_request_providers.dart';
import '../domain/friendship.dart';
import 'user_row.dart';
import '../../invites/domain/invite_link.dart';

/// The friends list, and the door to everything else social.
///
/// The requests inbox is a row at the top rather than a second tab, for the
/// same reason the pending-approvals queue is a shortcut on My Schedule and not
/// its own destination: it is usually empty, and a permanently-visible empty
/// tab teaches people to ignore the place their attention is meant to go. When
/// there is something waiting, the row carries the same orange count badge the
/// nav bar uses — the one attention signal in the app that a user learns to
/// trust (UI-RULES.md §2.7).
class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUidProvider);
    final friendships = ref.watch(myFriendshipsProvider);
    final pending = ref.watch(incomingRequestCountProvider);
    final planRequests = ref.watch(incomingPlanRequestCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          // Tap-to-open invite link for WhatsApp etc. (item 17).
          Builder(
            builder: (context) {
              final username = ref.watch(profileProvider).value?.username;
              return IconButton(
                tooltip: 'Invite a friend',
                icon: const Icon(AppIcons.share),
                onPressed: username == null || username.isEmpty
                    ? null
                    : () => SharePlus.instance.share(
                        ShareParams(text: friendInviteShareText(username)),
                      ),
              );
            },
          ),
          IconButton(
            tooltip: 'Blocked users',
            icon: const Icon(AppIcons.block),
            onPressed: () => context.push(Routes.blockedUsers),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'friendsFab',
        onPressed: () => context.push(Routes.userSearch),
        icon: const Icon(AppIcons.addFriend),
        label: const Text('Find people'),
      ),
      body: AsyncView<List<Friendship>>(
        value: friendships,
        onRetry: () => ref.invalidate(myFriendshipsProvider),
        // Never "empty": the requests row belongs on screen even with no
        // friends, and AsyncView's empty state would replace the whole body
        // with a message and hide it.
        builder: (context, friends) => ListView(
          padding: Space.screenListSafe(context),
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: Space.xs),
              leading: PendingCountBadge(
                count: pending,
                child: const Icon(AppIcons.approvals),
              ),
              title: const Text('Friend requests'),
              subtitle: Text(
                pending == 0
                    ? 'Nothing waiting'
                    : pending == 1
                    ? '1 person is waiting on you'
                    : '$pending people are waiting on you',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(AppIcons.openRow),
              onTap: () => context.push(Routes.friendRequests),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: Space.xs),
              leading: PendingCountBadge(
                count: planRequests,
                child: const Icon(AppIcons.navSchedule),
              ),
              title: const Text('Plan requests'),
              subtitle: Text(
                planRequests == 0
                    ? 'Ask friends to help plan your time'
                    : planRequests == 1
                    ? '1 request is waiting on you'
                    : '$planRequests requests are waiting on you',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(AppIcons.openRow),
              onTap: () => context.push(Routes.planRequests),
            ),
            const Divider(),
            if (friends.isEmpty)
              _EmptyFriends()
            else
              for (final friendship in friends)
                UserRow(uid: friendship.otherUid(me ?? '')),
          ],
        ),
      ),
    );
  }
}

/// UI-RULES.md §6.5. Inline rather than through AsyncView, because this list
/// keeps its requests row above the message.
class _EmptyFriends extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Column(
        children: [
          Icon(AppIcons.emptyFriends, size: Sizes.emptyStateIcon, color: muted),
          const SizedBox(height: Space.md),
          Text(
            'No friends yet.\nFind someone by their username.',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
