import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/friend_notifier.dart';
import '../../scheduling/presentation/group_plan_sheet.dart';
import '../../social/application/social_providers.dart';
import '../application/group_providers.dart';
import '../domain/group_join_request.dart';
import '../domain/membership.dart';
import '../domain/group.dart';
import 'group_avatar_editor.dart';
import '../../invites/domain/invite_link.dart';

/// A group's invite code, members and admins (WhatsApp-style, Batch G item 3):
/// admins add friends directly and decide join requests; the creator makes or
/// removes admins; admins remove members; anyone but the creator may leave; and
/// any member may plan for the whole group.
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myUid = ref.watch(currentUidProvider);
    final membersAsync = ref.watch(membersProvider(groupId));
    final friendsAsync = ref.watch(myFriendshipsProvider);
    final joinRequests =
        ref.watch(groupJoinRequestsProvider(groupId)).value ??
        const <GroupJoinRequest>[];
    final group = ref
        .watch(myGroupsProvider)
        .value
        ?.where((g) => g.id == groupId)
        .firstOrNull;

    // The owner cannot be removed and cannot leave — `isMemberRemoval()` in
    // firestore.rules refuses it, because /groups has `delete: if false` and a
    // group that lost its owner could never be cleaned up by anyone.
    final iAmOwner = myUid != null && group != null && group.ownerUid == myUid;
    final iAmAdmin = myUid != null && group != null && group.isAdmin(myUid);

    return Scaffold(
      appBar: AppBar(
        title: Text(group?.name ?? 'Group'),
        actions: [
          if (group != null && myUid != null && !iAmOwner)
            PopupMenuButton<void>(
              icon: const Icon(AppIcons.overflow),
              tooltip: 'More',
              itemBuilder: (_) => [
                PopupMenuItem<void>(
                  onTap: () => _leave(context, ref, myUid, group.name),
                  child: const _MenuRow(
                    icon: AppIcons.leaveGroup,
                    label: 'Leave group',
                  ),
                ),
              ],
            ),
        ],
      ),
      body: AsyncView<List<Membership>>(
        value: membersAsync,
        onRetry: () => ref.invalidate(membersProvider(groupId)),
        builder: (context, members) {
          return ListView(
            padding: const EdgeInsets.only(top: Space.lg),
            children: [
              if (group != null) ...[
                GroupAvatarEditor(group: group, editable: iAmOwner),
                const SizedBox(height: Space.sm),
              ],
              // Invite code with one-tap copy + share.
              Card(
                child: ListTile(
                  leading: const Icon(AppIcons.inviteCode),
                  title: const Text('Invite code'),
                  // The one place codeDisplay exists for — a named token rather
                  // than an inline exception to the no-font-sizes rule.
                  subtitle: Text(
                    group?.joinCode ?? '—',
                    style: context.codeDisplay,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Copy code',
                        icon: const Icon(AppIcons.copy),
                        onPressed: group == null
                            ? null
                            : () => _copyCode(context, group.joinCode),
                      ),
                      IconButton(
                        tooltip: 'Share invite',
                        icon: const Icon(AppIcons.share),
                        onPressed: group == null
                            ? null
                            : () => _shareCode(group.joinCode, group.name),
                      ),
                    ],
                  ),
                ),
              ),
              if (group != null && myUid != null)
                Card(
                  child: ListTile(
                    leading: const Icon(AppIcons.addFriend),
                    title: const Text('Add a friend'),
                    subtitle: Text(
                      iAmAdmin
                          ? 'They join right away'
                          : 'A group admin approves before they join',
                    ),
                    trailing: const Icon(AppIcons.openRow),
                    onTap: friendsAsync.hasValue
                        ? () => _inviteFriend(
                            context,
                            ref,
                            group.memberUids,
                            joinRequests,
                            myUid,
                            iAmAdmin,
                          )
                        : null,
                  ),
                ),
              // Only admins decide, so only admins see the queue (item 3).
              if (iAmAdmin && joinRequests.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Space.lg),
                  child: SectionHeader('Join requests'),
                ),
                for (final request in joinRequests)
                  _joinRequestTile(context, ref, request, myUid),
              ],
              // Group accountability + leaderboard — shared follow-through and a
              // ranked board, from each member's published summary.
              if (group != null)
                Card(
                  child: ListTile(
                    leading: const Icon(AppIcons.stats),
                    title: const Text('Group progress'),
                    subtitle: const Text(
                      'Shared streak, follow-through & leaderboard',
                    ),
                    trailing: const Icon(AppIcons.nextPeriod),
                    onTap: () =>
                        context.push('${Routes.plan}/groups/$groupId/progress'),
                  ),
                ),
              // Group planning (item 3): ANY member plans for the whole group —
              // every member plus themselves, no permission step. Shown once
              // there is someone else to plan for.
              if (group != null && myUid != null)
                Builder(
                  builder: (context) {
                    final candidates = <GroupPlanCandidate>[
                      (uid: myUid, isSelf: true),
                      for (final m in members)
                        if (m.uid != myUid) (uid: m.uid, isSelf: false),
                    ];
                    final others = candidates.where((c) => !c.isSelf).length;
                    if (others == 0) return const SizedBox.shrink();
                    return Card(
                      child: ListTile(
                        leading: const Icon(AppIcons.navPlan),
                        title: const Text('Plan for the group'),
                        subtitle: Text(
                          'One alarm for all $others '
                          '${others == 1 ? 'member' : 'members'}, plus you',
                        ),
                        onTap: () => showGroupPlanSheet(
                          context,
                          ref,
                          groupId: groupId,
                          groupName: group.name,
                          candidates: candidates,
                        ),
                      ),
                    );
                  },
                ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Space.lg),
                child: SectionHeader('Members'),
              ),
              for (final m in members)
                ListTile(
                  // A rounded SQUARE initial, matching `AvatarImage` — members
                  // here have no UserProfile to draw a photo from, but the shape
                  // and the container tint stay consistent with every avatar.
                  leading: Container(
                    width: Sizes.avatarRow,
                    height: Sizes.avatarRow,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.colors.primaryContainer,
                      borderRadius: Radii.md,
                    ),
                    child: Text(
                      _initial(m.name),
                      style: context.text.titleMedium?.copyWith(
                        color: context.colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                  title: Text(m.uid == myUid ? '${m.name} (you)' : m.name),
                  subtitle: group == null
                      ? null
                      : m.uid == group.ownerUid
                      ? const Text('Creator · admin')
                      : group.isAdmin(m.uid)
                      ? const Text('Admin')
                      : null,
                  trailing: m.uid == myUid || myUid == null || group == null
                      ? null
                      : _memberMenu(
                          context,
                          ref,
                          member: m,
                          group: group,
                          iAmOwner: iAmOwner,
                          iAmAdmin: iAmAdmin,
                          myUid: myUid,
                        ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _joinRequestTile(
    BuildContext context,
    WidgetRef ref,
    GroupJoinRequest request,
    String? myUid,
  ) {
    return ListTile(
      leading: const Icon(AppIcons.joinGroup),
      title: Text(request.candidateName),
      subtitle: Text(
        request.isInvitation
            ? 'Invited by a member'
            : 'Asked with the invite code',
      ),
      trailing: myUid == null
          ? null
          : Wrap(
              spacing: Space.xs,
              children: [
                IconButton(
                  tooltip: 'Reject ${request.candidateName}',
                  icon: const Icon(AppIcons.rejected),
                  onPressed: () =>
                      _decideJoinRequest(context, ref, request, myUid, false),
                ),
                IconButton(
                  tooltip: 'Approve ${request.candidateName}',
                  icon: const Icon(AppIcons.approved),
                  onPressed: () =>
                      _decideJoinRequest(context, ref, request, myUid, true),
                ),
              ],
            ),
    );
  }

  /// Push the admitted candidate. Only the approval that COMPLETED the
  /// admission calls this; the Worker re-verifies the approved request and the
  /// roster, and stamps the request so it is sent at most once. Best-effort:
  /// the membership is already saved.
  void _tellAdmitted(WidgetRef ref, String myUid, String candidateUid) {
    unawaited(
      ref
          .read(friendEventNotifierProvider)
          .notify(
            event: FriendNotifyEvent.groupJoinApproved,
            fromUid: myUid,
            toUid: candidateUid,
            groupId: groupId,
          ),
    );
  }

  Future<void> _decideJoinRequest(
    BuildContext context,
    WidgetRef ref,
    GroupJoinRequest request,
    String myUid,
    bool approve,
  ) async {
    if (!approve) {
      final confirmed = await _confirm(
        context,
        title: 'Reject ${request.candidateName}?',
        body:
            'This ends their request. Any admin can decide, and one '
            'decision is final.',
        action: 'Reject',
      );
      if (confirmed != true || !context.mounted) return;
    }
    try {
      final admitted = await ref
          .read(groupRepositoryProvider)
          .decideJoinRequest(
            groupId: groupId,
            candidateUid: request.candidateUid,
            callerUid: myUid,
            approve: approve,
          );
      if (admitted) _tellAdmitted(ref, myUid, request.candidateUid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !approve
                ? '${request.candidateName}\'s request was rejected.'
                : '${request.candidateName} joined the group.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not record that decision: $error')),
      );
    }
  }

  Future<void> _inviteFriend(
    BuildContext context,
    WidgetRef ref,
    List<String> memberUids,
    List<GroupJoinRequest> requests,
    String myUid,
    bool iAmAdmin,
  ) async {
    final friendships = ref.read(myFriendshipsProvider).value ?? const [];
    final unavailable = <String>{
      ...memberUids,
      ...requests.map((request) => request.candidateUid),
    };
    final availableUids = [
      for (final friendship in friendships)
        if (!unavailable.contains(friendship.otherUid(myUid)))
          friendship.otherUid(myUid),
    ];

    if (availableUids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No friends are available to invite to this group.'),
        ),
      );
      return;
    }

    final selected = await showDialog<({String uid, String name})>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) => AlertDialog(
          title: const Text('Add a friend'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final uid in availableUids)
                  Builder(
                    builder: (context) {
                      final profile = dialogRef
                          .watch(profileByUidProvider(uid))
                          .value;
                      return ListTile(
                        leading: const Icon(AppIcons.person),
                        title: Text(profile?.name ?? 'Loading…'),
                        enabled: profile != null,
                        onTap: profile == null
                            ? null
                            : () => Navigator.pop(dialogContext, (
                                uid: uid,
                                name: profile.name,
                              )),
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;

    try {
      final admitted = await ref
          .read(groupRepositoryProvider)
          .inviteFriend(
            groupId: groupId,
            callerUid: myUid,
            friendUid: selected.uid,
            friendName: selected.name,
            callerIsAdmin: iAmAdmin,
          );
      if (admitted) {
        _tellAdmitted(ref, myUid, selected.uid);
      } else {
        // A member's invitation waits for an admin — tell them (item 3).
        unawaited(
          ref
              .read(friendEventNotifierProvider)
              .notify(
                event: FriendNotifyEvent.groupJoinRequested,
                fromUid: myUid,
                toUid: selected.uid,
                groupId: groupId,
              ),
        );
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            admitted
                ? '${selected.name} joined the group.'
                : '${selected.name} will join once a group admin approves.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send the invitation: $error')),
      );
    }
  }

  /// Per-member actions (item 3). The creator makes or removes admins; any
  /// admin removes a member (never the creator). Renders nothing when neither
  /// applies — an empty menu is a control that lies about having options.
  Widget _memberMenu(
    BuildContext context,
    WidgetRef ref, {
    required Membership member,
    required Group group,
    required bool iAmOwner,
    required bool iAmAdmin,
    required String myUid,
  }) {
    final isCreator = member.uid == group.ownerUid;
    final theyAreAdmin = group.isAdmin(member.uid);
    final items = <PopupMenuEntry<void>>[
      if (iAmOwner && !isCreator)
        PopupMenuItem<void>(
          onTap: () => _setAdmin(context, ref, member, !theyAreAdmin),
          child: _MenuRow(
            icon: theyAreAdmin ? AppIcons.removeAdmin : AppIcons.makeAdmin,
            label: theyAreAdmin ? 'Remove as admin' : 'Make admin',
          ),
        ),
      if (iAmAdmin && !isCreator)
        PopupMenuItem<void>(
          onTap: () => _removeMember(context, ref, myUid, member),
          child: const _MenuRow(
            icon: AppIcons.removeMember,
            label: 'Remove from group',
          ),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<void>(
      icon: const Icon(AppIcons.overflow),
      tooltip: 'More',
      itemBuilder: (_) => items,
    );
  }

  /// The creator shares or takes back admin rights (item 3).
  Future<void> _setAdmin(
    BuildContext context,
    WidgetRef ref,
    Membership member,
    bool admin,
  ) async {
    await _guard(
      context,
      ref,
      () => ref
          .read(groupRepositoryProvider)
          .setAdmin(groupId: groupId, memberUid: member.uid, admin: admin),
      success: admin
          ? '${member.name} is now an admin.'
          : '${member.name} is no longer an admin.',
    );
  }

  /// An admin removes a member (item 3) — including another admin, never the
  /// creator.
  Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    String myUid,
    Membership member,
  ) async {
    final confirmed = await _confirm(
      context,
      title: 'Remove ${member.name}?',
      body:
          "They'll lose access to this group. Plans already set stay where "
          'they are. They can rejoin only with the invite code.',
      action: 'Remove',
    );
    if (confirmed != true || !context.mounted) return;
    await _guard(context, ref, () async {
      await ref
          .read(groupRepositoryProvider)
          .removeMember(
            groupId: groupId,
            memberUid: member.uid,
            callerUid: myUid,
          );
    }, success: '${member.name} removed.');
  }

  /// Leave a group I don't own. Pops back to the group list on success — the
  /// members stream starts failing the moment membership is gone, and sitting
  /// on a screen whose data the rules now deny is not a state worth rendering.
  Future<void> _leave(
    BuildContext context,
    WidgetRef ref,
    String myUid,
    String groupName,
  ) async {
    final confirmed = await _confirm(
      context,
      title: 'Leave "$groupName"?',
      body:
          "You'll lose access to this group. Plans already set stay where "
          'they are. You can rejoin only with the invite code.',
      action: 'Leave',
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await _guard(context, ref, () async {
      await ref
          .read(groupRepositoryProvider)
          .removeMember(groupId: groupId, memberUid: myUid, callerUid: myUid);
    }, success: 'You left "$groupName".');
    if (ok && context.mounted) Navigator.of(context).pop();
  }

  /// One destructive-confirmation shape for these actions — red on the
  /// confirm button only, one of the rationed uses (UI-RULES.md §2.5).
  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colors.error,
              foregroundColor: ctx.colors.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  /// Run a write and report it. These are the first writes on this screen that
  /// the rules can legitimately refuse — an owner check or a membership check
  /// can fail on a stale snapshot — and a silent no-op on a destructive action
  /// is the worst possible outcome. Returns whether it succeeded.
  Future<bool> _guard(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() write, {
    required String success,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await write();
      messenger.showSnackBar(SnackBar(content: Text(success)));
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't do that: $e")));
      return false;
    }
  }

  String _initial(String name) =>
      name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  Future<void> _copyCode(BuildContext context, String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied "$code"')));
  }

  Future<void> _shareCode(String code, String groupName) async {
    await SharePlus.instance.share(
      ShareParams(
        text: groupInviteShareText(groupName, code),
      ),
    );
  }
}

/// A popup-menu row: glyph then label, at the list-icon size. Exists so the
/// three menu entries can't drift apart, and so no call site hand-rolls
/// spacing between an icon and its text.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: Sizes.listIcon),
        const SizedBox(width: Space.md),
        // Flexible so a long label ("Remove from group") at a large text scale
        // wraps inside the popup's width cap instead of overflowing it.
        Flexible(child: Text(label)),
      ],
    );
  }
}
