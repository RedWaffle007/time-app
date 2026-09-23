import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/domain/planner_grant.dart';
import '../../social/application/social_providers.dart';

/// Who a voice-driven plan is for. Mirrors the schedule builder's own three
/// selection fields so it can be handed straight into it.
class PlanTargetSelection {
  const PlanTargetSelection({
    required this.uid,
    required this.isSelf,
    this.groupId,
  });

  final String uid;
  final bool isSelf;

  /// The group the grant came from; null when planning for self.
  final String? groupId;
}

/// The person-picker shown BEFORE the voice prompt in the Plan flow (S6): pick
/// who this is for, then speak the alarm details. "Myself" is always offered;
/// then anyone who has granted planning permission. Returns null if dismissed.
///
/// This is the same choice the schedule builder makes on its first screen — the
/// voice flow just makes it first so the spoken details land against a known
/// target.
Future<PlanTargetSelection?> showPlanTargetPicker(
  BuildContext context,
  WidgetRef ref,
) {
  return showModalBottomSheet<PlanTargetSelection>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _PlanTargetPicker(),
  );
}

class _PlanTargetPicker extends ConsumerWidget {
  const _PlanTargetPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authRepositoryProvider).currentUser;
    final grants = ref.watch(effectivePlanningTargetsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.sm,
          Space.lg,
          Space.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              child: Text('Plan for', style: context.text.titleLarge),
            ),
            const SizedBox(height: Space.sm),
            if (me != null) _selfTile(context, ref, me.uid),
            ...grants.when(
              data: (list) => [
                for (final g in list) _targetTile(context, ref, g),
              ],
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(Space.lg),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (_, _) => const [
                Padding(
                  padding: EdgeInsets.all(Space.lg),
                  child: Text('Could not load the people you can plan for.'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _selfTile(BuildContext context, WidgetRef ref, String uid) {
    final profile = ref.watch(profileByUidProvider(uid)).value;
    return ListTile(
      leading: const Icon(AppIcons.person),
      title: Text(profile == null ? 'Myself' : '${profile.name} (myself)'),
      subtitle: profile == null ? null : Text(profile.homeTimezone),
      onTap: () =>
          Navigator.pop(context, PlanTargetSelection(uid: uid, isSelf: true)),
    );
  }

  Widget _targetTile(BuildContext context, WidgetRef ref, PlannerGrant grant) {
    final profile = ref.watch(profileByUidProvider(grant.targetUid)).value;
    return ListTile(
      leading: const Icon(AppIcons.person),
      title: Text(profile?.name ?? grant.targetUid),
      subtitle: profile == null ? null : Text(profile.homeTimezone),
      onTap: () => Navigator.pop(
        context,
        PlanTargetSelection(
          uid: grant.targetUid,
          isSelf: false,
          groupId: grant.groupId,
        ),
      ),
    );
  }
}
