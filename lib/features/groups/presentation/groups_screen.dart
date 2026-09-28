import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/tab_action_row.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/friend_notifier.dart';
import '../application/group_providers.dart';
import '../domain/group.dart';
import 'group_avatar_image.dart';

/// Lists the user's groups; lets them create a new one or join by code.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key, this.embedded = false});

  /// When true, this screen is a sub-tab inside the Plan shell: the shell owns
  /// the app bar (with Join / New-group actions) and the persistent `PLAN`
  /// button, so both are suppressed here. Default false retains this screen's
  /// standalone presentation.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);

    return Scaffold(
      appBar: embedded
          ? null
          : AppBar(
              title: const Text('Groups'),
              actions: [
                IconButton(
                  tooltip: 'Join by code',
                  icon: const Icon(AppIcons.joinGroup),
                  onPressed: () => showGroupJoinDialog(context, ref),
                ),
              ],
            ),
      floatingActionButton: embedded
          ? null
          : FloatingActionButton.extended(
              // Unique tag: HomeShell's IndexedStack keeps this tab AND the
              // Activity tab (which also has a FAB) mounted at once, so the
              // default shared FAB hero tag collides. See heroTag on
              // PlannerActivityScreen's FAB too.
              heroTag: 'groupsFab',
              onPressed: () => showGroupCreateDialog(context, ref),
              icon: const Icon(AppIcons.add),
              label: const Text('New group'),
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The same top button row as every Plan sub-tab (2026-09-28):
          // create and join are named buttons, Archive beside them.
          TabActionRow(
            home: TabAction(
              key: const ValueKey('groups-create'),
              label: 'CREATE GROUP',
              onPressed: () => showGroupCreateDialog(context, ref),
            ),
            activity: TabAction(
              key: const ValueKey('groups-join'),
              label: 'JOIN GROUP',
              onPressed: () => showGroupJoinDialog(context, ref),
            ),
            groups: TabAction(
              key: const ValueKey('groups-archive'),
              label: 'ARCHIVE',
              onPressed: () => context.push(Routes.archived),
            ),
          ),
          Expanded(child: _groupList(context, ref, groupsAsync)),
        ],
      ),
    );
  }

  Widget _groupList(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Group>> groupsAsync,
  ) {
    return AsyncView<List<Group>>(
      value: groupsAsync,
      onRetry: () => ref.invalidate(myGroupsProvider),
      isEmpty: (groups) => groups.isEmpty,
      emptyMessage: 'No groups yet.\nCreate one or join by code.',
      builder: (context, groups) => ListView(
        children: [
          for (final g in groups)
            ListTile(
              leading: GroupAvatarImage(group: g),
              title: Text(g.name),
              subtitle: Text(
                'Code: ${g.joinCode} · ${g.memberUids.length} member(s)',
              ),
              trailing: const Icon(AppIcons.openRow),
              // Group detail is a Plan sub-route, so it stacks over the Plan
              // shell and Back returns here. (Post-S5 this screen only ever
              // renders embedded inside Plan; the old `/groups/:id` branch is
              // gone.)
              onTap: () => context.push('${Routes.plan}/groups/${g.id}'),
            ),
        ],
      ),
    );
  }
}

/// The "New group" dialog. Top-level so the Plan shell's app-bar action can
/// invoke exactly the same flow the standalone screen's FAB does.
Future<void> showGroupCreateDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New group'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Group name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;

  final user = ref.read(authRepositoryProvider).currentUser;
  final profile = ref.read(profileProvider).value;
  if (user == null) return;
  await ref
      .read(groupRepositoryProvider)
      .createGroup(
        name: name,
        ownerUid: user.uid,
        ownerName: profile?.name ?? user.displayName ?? 'Me',
      );
}

/// The "Join by code" dialog. Top-level for the same reason
/// [showGroupCreateDialog] is — the Plan shell's app-bar Join action reuses it.
Future<void> showGroupJoinDialog(
  BuildContext context,
  WidgetRef ref, {
  // Prefilled from a group invite link (item 17); the person still confirms.
  String? initialCode,
}) async {
  final controller = TextEditingController(text: initialCode ?? '');
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Join a group'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Invite code'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Join'),
        ),
      ],
    ),
  );
  if (code == null || code.isEmpty) return;

  final user = ref.read(authRepositoryProvider).currentUser;
  final profile = ref.read(profileProvider).value;
  if (user == null) return;

  final notifier = ref.read(friendEventNotifierProvider);
  final groupId = await ref
      .read(groupRepositoryProvider)
      .requestJoinByCode(
        code: code,
        uid: user.uid,
        name: profile?.name ?? user.displayName ?? 'Me',
      );
  if (groupId != null) {
    // Tell the group's admins (item 3). Best-effort and not awaited: the
    // request is already saved, and they also see it in the group.
    unawaited(
      notifier.notify(
        event: FriendNotifyEvent.groupJoinRequested,
        fromUid: user.uid,
        toUid: user.uid,
        groupId: groupId,
      ),
    );
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        groupId != null
            ? 'Request sent. A group admin will approve it.'
            : 'No group with that code.',
      ),
    ),
  );
}
