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
import '../../scheduling/application/planning_target_picker.dart';
import '../../scheduling/presentation/group_plan_sheet.dart';
import '../../social/application/social_providers.dart';
import '../application/group_providers.dart';
import '../domain/group_join_request.dart';
import '../domain/membership.dart';
import '../domain/planner_grant.dart';
import 'group_avatar_editor.dart';

/// Shows a group's invite code and members, lets the signed-in user grant other
/// members permission to plan for them (consent-first), and lets them end a
/// relationship: give up a grant they hold, eject a member (owner only), or
/// leave the group.
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myUid = ref.watch(currentUidProvider);
    final membersAsync = ref.watch(membersProvider(groupId));
    final grantsAsync = ref.watch(grantsProvider(groupId));
    final friendsAsync = ref.watch(myFriendshipsProvider);
    final effectiveTargets =
        ref.watch(effectivePlanningTargetsProvider).value ??
        const <PlannerGrant>[];
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
          final grants = grantsAsync.value ?? const <PlannerGrant>[];
          final friendUids = <String>{
            for (final friendship in friendsAsync.value ?? const [])
              friendship.otherUid(myUid ?? ''),
          };
          bool grantsToMe(String plannerUid) => grants.any(
            (g) =>
                g.plannerUid == plannerUid && g.targetUid == myUid && g.granted,
          );
          // The other direction: a grant *I* hold over them. Separate question,
          // separate answer — consent here is directed, never mutual.
          bool iPlanFor(String targetUid) => effectiveTargets.any(
            (g) =>
                g.plannerUid == myUid && g.targetUid == targetUid && g.granted,
          );

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
                    subtitle: const Text(
                      'Every current member must approve before they join',
                    ),
                    trailing: const Icon(AppIcons.openRow),
                    onTap: friendsAsync.hasValue
                        ? () => _inviteFriend(
                            context,
                            ref,
                            group.memberUids,
                            joinRequests,
                            myUid,
                          )
                        : null,
                  ),
                ),
              if (joinRequests.isNotEmpty) ...[
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
              // Group planning: one item for everyone the caller may plan for.
              // Shown only when there is at least one OTHER member who granted
              // permission — planning for only yourself is just self-planning.
              if (group != null && myUid != null)
                Builder(
                  builder: (context) {
                    final candidates = <GroupPlanCandidate>[
                      (uid: myUid, isSelf: true),
                      for (final m in members)
                        if (m.uid != myUid && iPlanFor(m.uid))
                          (uid: m.uid, isSelf: false),
                    ];
                    final others = candidates.where((c) => !c.isSelf).length;
                    if (others == 0) return const SizedBox.shrink();
                    return Card(
                      child: ListTile(
                        leading: const Icon(AppIcons.navPlan),
                        title: const Text('Plan for the group'),
                        subtitle: Text(
                          'One item for $others '
                          '${others == 1 ? 'member' : 'members'} you can plan '
                          'for, plus you',
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
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.sm,
                ),
                child: Text(
                  'For non-friend members, turn on "can plan for me" here. '
                  'Friend permissions are managed permanently on profiles.',
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
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
                  // The switch's label. It moved off the trailing row to make
                  // width for the overflow menu — three controls on one line is
                  // a mis-tap waiting to happen, and one of them is destructive.
                  subtitle: m.uid == myUid
                      ? null
                      : Text(
                          friendUids.contains(m.uid)
                              ? 'Planning permission is managed on their profile'
                              : 'can plan for me',
                        ),
                  trailing: m.uid == myUid || myUid == null
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (groupPlanningPermissionApplies(
                              m.uid,
                              friendUids: friendUids,
                            ))
                              Switch(
                                value: grantsToMe(m.uid),
                                onChanged: (v) => ref
                                    .read(groupRepositoryProvider)
                                    .setPlannerGrant(
                                      groupId: groupId,
                                      plannerUid: m.uid,
                                      targetUid: myUid,
                                      granted: v,
                                    ),
                              ),
                            _memberMenu(
                              context,
                              ref,
                              member: m,
                              myUid: myUid,
                              iAmOwner: iAmOwner,
                              iPlanForThem:
                                  groupPlanningPermissionApplies(
                                    m.uid,
                                    friendUids: friendUids,
                                  ) &&
                                  iPlanFor(m.uid),
                            ),
                          ],
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
    final alreadyApproved = myUid != null && request.hasApproved(myUid);
    final required = request.approvalsRequired == 0
        ? 'Waiting for the first decision'
        : '${request.approvalsReceived}/${request.approvalsRequired} approved';
    return ListTile(
      leading: const Icon(AppIcons.joinGroup),
      title: Text(request.candidateName),
      subtitle: Text(required),
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
                if (!alreadyApproved)
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
            'One rejection ends this join request, even if every other '
            'member approved it. This cannot be undone.',
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
                : admitted
                ? '${request.candidateName} joined the group.'
                : 'Your approval was recorded.',
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
          );
      if (admitted) _tellAdmitted(ref, myUid, selected.uid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            admitted
                ? '${selected.name} joined the group.'
                : '${selected.name} will join after every current member '
                      'approves.',
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

  /// Per-member secondary actions. Both are relationship-ending, so both live
  /// behind the overflow (UI-RULES.md §6.6) rather than inline in a scrolling
  /// list. Renders nothing at all when neither applies — an empty menu is a
  /// control that lies about having options.
  Widget _memberMenu(
    BuildContext context,
    WidgetRef ref, {
    required Membership member,
    required String myUid,
    required bool iAmOwner,
    required bool iPlanForThem,
  }) {
    final items = <PopupMenuEntry<void>>[
      if (iPlanForThem)
        PopupMenuItem<void>(
          onTap: () => _stopPlanning(context, ref, myUid, member),
          child: const _MenuRow(
            icon: AppIcons.stopPlanning,
            label: 'Stop planning for them',
          ),
        ),
      if (iAmOwner)
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

  /// Give up the grant I hold over [member] — I stop being their planner.
  ///
  /// Not destructive to *them*: it removes a power I hold, and they can hand it
  /// back with their own switch. Confirmed anyway because it silently drops
  /// them out of my schedule builder, which is otherwise hard to explain.
  Future<void> _stopPlanning(
    BuildContext context,
    WidgetRef ref,
    String myUid,
    Membership member,
  ) async {
    final confirmed = await _confirm(
      context,
      title: 'Stop planning for ${member.name}?',
      body:
          "They'll disappear from your schedule builder. Their existing "
          'items are untouched, and they can switch the permission back on '
          'for you at any time.',
      action: 'Stop planning',
    );
    if (confirmed != true || !context.mounted) return;
    await _guard(context, ref, () async {
      await ref
          .read(groupRepositoryProvider)
          .revokeMyPlannerGrant(
            groupId: groupId,
            plannerUid: myUid,
            targetUid: member.uid,
          );
    }, success: 'You no longer plan for ${member.name}.');
  }

  /// Owner ejects a member.
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
          "They'll lose access to this group and any permission between you "
          'is revoked. Schedule items already created stay where they are. '
          'They can rejoin only with the invite code.',
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
          'Any permission between you and its members is revoked. Schedule '
          'items already created stay where they are. You can rejoin only '
          'with the invite code.',
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

  /// One destructive-confirmation shape for all three actions — red on the
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
        text: 'Join my group "$groupName" on Checkmate with code: $code',
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
        Text(label),
      ],
    );
  }
}
