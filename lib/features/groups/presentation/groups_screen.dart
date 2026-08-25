import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/async_view.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../home/presentation/account_button.dart';
import '../application/group_providers.dart';
import '../domain/group.dart';

/// Lists the user's groups; lets them create a new one or join by code.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key, this.embedded = false});

  /// When true, this screen is a sub-tab inside the Plan shell (slice S4): the
  /// shell owns the app bar (with the Join / New-group / account actions) and
  /// there is no FAB (the single-FAB rule is reserved for the S5 voice FAB), so
  /// both are suppressed. Default false = the standalone old-bar screen, byte
  /// for byte as before.
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
                const AccountButton(),
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
      body: AsyncView<List<Group>>(
        value: groupsAsync,
        onRetry: () => ref.invalidate(myGroupsProvider),
        isEmpty: (groups) => groups.isEmpty,
        emptyMessage: 'No groups yet.\nCreate one or join by code.',
        builder: (context, groups) => ListView(
          children: [
            for (final g in groups)
              ListTile(
                leading: const Icon(AppIcons.group),
                title: Text(g.name),
                subtitle: Text('Code: ${g.joinCode} · ${g.memberUids.length} member(s)'),
                trailing: const Icon(AppIcons.openRow),
                // In the Plan shell the group-detail push must stay in the Plan
                // stack (`/plan/groups/:id`); in the old bar it stays in the
                // Groups branch (`/groups/:id`). Back returns to the right place
                // either way.
                onTap: () => context.push(
                  embedded ? '${Routes.plan}/groups/${g.id}' : '/groups/${g.id}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The "New group" dialog. Top-level so the Plan shell's app-bar `＋` action
/// (slice S4) can invoke exactly the same flow the standalone screen's FAB does.
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
    await ref.read(groupRepositoryProvider).createGroup(
          name: name,
          ownerUid: user.uid,
          ownerName: profile?.name ?? user.displayName ?? 'Me',
        );
  }

/// The "Join by code" dialog. Top-level for the same reason
/// [showGroupCreateDialog] is — the Plan shell's app-bar Join action reuses it.
Future<void> showGroupJoinDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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

    final group = await ref.read(groupRepositoryProvider).joinByCode(
          code: code,
          uid: user.uid,
          name: profile?.name ?? user.displayName ?? 'Me',
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(group == null ? 'No group with that code.' : 'Joined ${group.name}!'),
      ),
    );
}
