import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/application/auth_providers.dart';
import '../application/group_providers.dart';

/// Lists the user's groups; lets them create a new one or join by code.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        actions: [
          IconButton(
            tooltip: 'Join by code',
            icon: const Icon(Icons.login),
            onPressed: () => _showJoinDialog(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (groups) {
          if (groups.isEmpty) {
            return const Center(
              child: Text('No groups yet.\nCreate one or join by code.',
                  textAlign: TextAlign.center),
            );
          }
          return ListView(
            children: [
              for (final g in groups)
                ListTile(
                  leading: const Icon(Icons.group),
                  title: Text(g.name),
                  subtitle: Text('Code: ${g.joinCode} · ${g.memberUids.length} member(s)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/groups/${g.id}'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
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

  Future<void> _showJoinDialog(BuildContext context, WidgetRef ref) async {
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
}
