import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../application/social_providers.dart';
import '../domain/user_block.dart';
import 'user_row.dart';

/// Everyone the signed-in user has blocked, with a way to lift each one.
///
/// The rows deliberately do NOT open the blocked person's profile — that
/// profile renders as unavailable, so tapping through would be a dead end.
/// Unblocking is the only action, and it is the trailing control.
class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(myBlocksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Blocked')),
      body: AsyncView<List<UserBlock>>(
        value: blocks,
        onRetry: () => ref.invalidate(myBlocksProvider),
        isEmpty: (list) => list.isEmpty,
        emptyIcon: AppIcons.block,
        emptyMessage: "You haven't blocked anyone.",
        builder: (context, list) => ListView(
          padding: Space.screenListSafe(context),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: Text(
                'Unblocking does not restore a friendship or any permission to '
                'plan on your schedule. You would both start over.',
                style: context.text.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
            for (final block in list)
              UserRow(
                uid: block.blockedUid,
                subtitle: 'Blocked',
                // A blocked profile is unavailable, so a drill-in would go
                // nowhere. Tapping the row does nothing; the control is the
                // explicit button.
                onTap: () {},
                trailing: TextButton.icon(
                  icon: const Icon(AppIcons.unblock),
                  label: const Text('Unblock'),
                  onPressed: () async {
                    final me = ref.read(currentUidProvider);
                    if (me == null) return;
                    await ref.read(blockRepositoryProvider).unblock(
                          blockerUid: me,
                          blockedUid: block.blockedUid,
                        );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
