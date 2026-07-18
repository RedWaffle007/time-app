import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../auth/application/auth_providers.dart';
import '../application/group_providers.dart';
import '../domain/planner_grant.dart';

/// Shows a group's invite code and members, and lets the signed-in user grant
/// other members permission to plan for them (consent-first).
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myUid = ref.watch(authStateProvider).value?.uid;
    final membersAsync = ref.watch(membersProvider(groupId));
    final grantsAsync = ref.watch(grantsProvider(groupId));
    final group = ref
        .watch(myGroupsProvider)
        .value
        ?.where((g) => g.id == groupId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(group?.name ?? 'Group')),
      body: membersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (members) {
          final grants = grantsAsync.value ?? const <PlannerGrant>[];
          bool grantsToMe(String plannerUid) => grants.any((g) =>
              g.plannerUid == plannerUid &&
              g.targetUid == myUid &&
              g.granted);

          return ListView(
            children: [
              // Invite code with one-tap copy + share.
              Card(
                margin: const EdgeInsets.all(16),
                child: ListTile(
                  leading: const Icon(Icons.key),
                  title: const Text('Invite code'),
                  subtitle: Text(
                    group?.joinCode ?? '—',
                    style: const TextStyle(
                        fontSize: 22, letterSpacing: 3, fontWeight: FontWeight.bold),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Copy code',
                        icon: const Icon(Icons.copy),
                        onPressed: group == null
                            ? null
                            : () => _copyCode(context, group.joinCode),
                      ),
                      IconButton(
                        tooltip: 'Share invite',
                        icon: const Icon(Icons.share),
                        onPressed: group == null
                            ? null
                            : () => _shareCode(group.joinCode, group.name),
                      ),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Members', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Turn on "can plan for me" to let a member build your schedule. '
                  'Only you can grant this.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              for (final m in members)
                ListTile(
                  leading: CircleAvatar(child: Text(_initial(m.name))),
                  title: Text(m.uid == myUid ? '${m.name} (you)' : m.name),
                  trailing: m.uid == myUid
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('can plan for me'),
                            Switch(
                              value: grantsToMe(m.uid),
                              onChanged: myUid == null
                                  ? null
                                  : (v) => ref
                                      .read(groupRepositoryProvider)
                                      .setPlannerGrant(
                                        groupId: groupId,
                                        plannerUid: m.uid,
                                        targetUid: myUid,
                                        granted: v,
                                      ),
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

  String _initial(String name) =>
      name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  Future<void> _copyCode(BuildContext context, String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "$code"')),
    );
  }

  Future<void> _shareCode(String code, String groupName) async {
    await SharePlus.instance.share(
      ShareParams(
        text: 'Join my group "$groupName" on time-app with code: $code',
      ),
    );
  }
}
