import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/user_profile.dart';
import '../../notifications/application/friend_notifier.dart';
import '../application/social_providers.dart';
import '../data/planning_permission_repository.dart';
import '../domain/planning_request.dart';
import '../domain/profile_visibility.dart';
import 'avatar_image.dart';
import 'stats_section.dart';

/// One person's profile: who they are, where the viewer stands with them, and
/// — if privacy allows — their stats.
///
/// **Every control on this screen is decided by `profileVisibilityProvider`**,
/// which resolves five live facts into one value. No widget here re-derives
/// "are we friends?" from a request row or a block document; doing that in two
/// places is how two screens end up disagreeing about the same relationship.
///
/// **A blocked profile — in either direction — renders as unavailable and
/// nothing else.** Not "you blocked this person" on one side and something
/// different on the other: telling someone they have been blocked hands them
/// the one fact a block exists to withhold. `ProfileRelation` keeps the
/// distinction internally so the viewer's own controls can differ, and this
/// screen is where that distinction stops.
class UserProfileScreen extends ConsumerWidget {
  const UserProfileScreen({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(profileVisibilityProvider(uid));
    final profile = ref.watch(profileByUidProvider(uid));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          if (visibility.value case final v?)
            if (!v.isSelf && !v.isUnreachable)
              _ProfileOverflowMenu(uid: uid, visibility: v),
        ],
      ),
      body: AsyncView<UserProfile?>(
        value: profile,
        onRetry: () => ref.invalidate(profileByUidProvider(uid)),
        isEmpty: (p) => p == null,
        emptyIcon: AppIcons.profileUnavailable,
        emptyMessage: 'This profile is not available.',
        builder: (context, data) {
          final v = visibility.value;
          // Still resolving the relationship. Deliberately NOT rendered as a
          // partial profile: the header is harmless but the stats section
          // below it is not, and a permissive default for one frame is a leak.
          if (v == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (v.isUnreachable) return const _Unavailable();

          return ListView(
            padding: Space.screenList,
            children: [
              _Header(profile: data!, visibility: v),
              const SizedBox(height: Space.lg),
              _RelationshipActions(uid: uid, visibility: v),
              if (v.relation == ProfileRelation.friend)
                _PlanningPermissionSection(uid: uid, name: data.name),
              StatsSection(uid: uid),
            ],
          );
        },
      ),
    );
  }
}

/// What a blocked profile looks like, from BOTH sides.
///
/// The copy is deliberately about the profile, not about the block: "not
/// available" is true whether the viewer blocked them, they blocked the viewer,
/// or the account is gone. See [AppIcons.profileUnavailable].
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.profileUnavailable,
              size: Sizes.emptyStateIcon,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(height: Space.md),
            Text(
              'This profile is not available.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.profile, required this.visibility});

  final UserProfile profile;
  final ProfileVisibility visibility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.colors.onSurfaceVariant;
    // Only ever non-null for the viewer's own profile — a visitor's device
    // cannot enumerate someone else's friendships. See friendCountForProvider.
    final friendCount = ref.watch(friendCountForProvider(profile.uid));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarImage(profile: profile, size: Sizes.avatarHeader),
            const SizedBox(width: Space.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.name, style: context.text.titleLarge),
                  if (profile.handle case final handle?) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      handle,
                      style: context.text.bodyMedium?.copyWith(color: muted),
                    ),
                  ],
                  if (friendCount != null) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      friendCount == 1 ? '1 friend' : '$friendCount friends',
                      style: context.text.labelSmall?.copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (profile.bio?.trim().isNotEmpty ?? false) ...[
          const SizedBox(height: Space.lg),
          Text(profile.bio!.trim(), style: context.text.bodyMedium),
        ],
      ],
    );
  }
}

/// The one primary action, chosen by relationship.
///
/// Exactly one button, never a row of them. "Add friend" and "Accept" and
/// "Requested" are the same slot in three states, and rendering them as
/// alternatives would ask the user to work out which applies.
class _RelationshipActions extends ConsumerStatefulWidget {
  const _RelationshipActions({required this.uid, required this.visibility});

  final String uid;
  final ProfileVisibility visibility;

  @override
  ConsumerState<_RelationshipActions> createState() =>
      _RelationshipActionsState();
}

class _RelationshipActionsState extends ConsumerState<_RelationshipActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('That did not work. $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUidProvider);
    if (me == null || widget.visibility.isSelf) return const SizedBox.shrink();
    final repo = ref.read(friendRepositoryProvider);
    // Captured while alive, then used across awaits — see the note in
    // friend_requests_screen.dart. Here the widget usually survives the action,
    // but capturing keeps every friend-notify site on the same safe pattern.
    final notifier = ref.read(friendEventNotifierProvider);

    switch (widget.visibility.relation) {
      case ProfileRelation.none:
        return _Action(
          icon: AppIcons.addFriend,
          label: 'Add friend',
          busy: _busy,
          onPressed: () => _run(() async {
            await repo.sendRequest(fromUid: me, toUid: widget.uid);
            // Best-effort push to the recipient — never blocks the state change.
            await notifier.notify(
              event: FriendNotifyEvent.friendRequest,
              fromUid: me,
              toUid: widget.uid,
            );
          }),
        );

      case ProfileRelation.requestSent:
        final request = ref.watch(outgoingRequestToProvider(widget.uid)).value;
        // Outlined, not filled: the action available here is *withdrawing*,
        // which is secondary. A filled button would invite a tap that undoes
        // what the user just did.
        return _Action(
          icon: AppIcons.declineFriend,
          label: 'Requested — tap to withdraw',
          filled: false,
          busy: _busy,
          onPressed: request == null
              ? null
              : () => _run(() => repo.cancelRequest(request)),
        );

      case ProfileRelation.requestReceived:
        final request = ref.watch(incomingRequestFromProvider(widget.uid)).value;
        return Row(
          children: [
            Expanded(
              child: _Action(
                icon: AppIcons.acceptFriend,
                label: 'Accept',
                busy: _busy,
                onPressed: request == null
                    ? null
                    : () => _run(() async {
                          await repo.acceptRequest(request);
                          // Notify the original sender they were accepted.
                          await notifier.notify(
                            event: FriendNotifyEvent.friendAccept,
                            fromUid: request.fromUid,
                            toUid: me,
                          );
                        }),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: _Action(
                icon: AppIcons.declineFriend,
                label: 'Decline',
                filled: false,
                busy: _busy,
                onPressed: request == null
                    ? null
                    : () => _run(() => repo.rejectRequest(request)),
              ),
            ),
          ],
        );

      case ProfileRelation.friend:
        // No primary action. Being friends is a resting state, not something
        // to do — and "Remove friend" belongs in the overflow with the other
        // severances, not under the user's thumb on the main surface.
        return const SizedBox.shrink();

      case ProfileRelation.self:
      case ProfileRelation.blocking:
      case ProfileRelation.blockedBy:
        return const SizedBox.shrink();
    }
  }
}

/// Friendship-scoped planning permission, shown only between friends (#4).
///
/// Two independent, per-direction controls — consent always originates from the
/// person being planned for:
///   * a TARGET-controlled switch: "Let [name] plan for me" (default off);
///   * a way to ASK the friend for permission to plan for THEM, when they have
///     not already granted it.
///
/// Neither grants anything the other way: friendship still carries no planning
/// power on its own (DECISIONS.md "Friendship-scoped planning grants").
class _PlanningPermissionSection extends ConsumerStatefulWidget {
  const _PlanningPermissionSection({required this.uid, required this.name});

  final String uid;
  final String name;

  @override
  ConsumerState<_PlanningPermissionSection> createState() =>
      _PlanningPermissionSectionState();
}

class _PlanningPermissionSectionState
    extends ConsumerState<_PlanningPermissionSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('That did not work. $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUidProvider);
    if (me == null) return const SizedBox.shrink();
    final repo = ref.read(planningPermissionRepositoryProvider);
    final canPlanForMe =
        ref.watch(canFriendPlanForMeProvider(widget.uid)).value ?? false;
    final canEmergencyForMe =
        ref.watch(canFriendEmergencyPlanForMeProvider(widget.uid)).value ??
            false;

    return Padding(
      padding: const EdgeInsets.only(top: Space.md, bottom: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            child: Text('Planning', style: context.text.titleSmall),
          ),
          // Target-controlled: I decide whether this friend may plan for me.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Let ${widget.name} plan for me'),
            subtitle: const Text(
                'They can propose items — you still approve each one.'),
            value: canPlanForMe,
            onChanged: _busy
                ? null
                : (v) => _run(() => repo.setGrant(
                      plannerUid: widget.uid,
                      targetUid: me,
                      granted: v,
                    )),
          ),
          const SizedBox(height: Space.sm),
          _askControl(context, me, repo, PlanningKind.normal),
          const SizedBox(height: Space.md),
          // A SEPARATE, higher-stakes grant: emergency items fire WITHOUT your
          // per-item approval. Independent of the normal toggle — granting it
          // never implies normal permission and vice versa.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Let ${widget.name} set emergency alarms for me'),
            subtitle: const Text(
                'Emergency items fire immediately, without your approval.'),
            value: canEmergencyForMe,
            onChanged: _busy
                ? null
                : (v) => _run(() => repo.setGrant(
                      plannerUid: widget.uid,
                      targetUid: me,
                      granted: v,
                      kind: PlanningKind.emergency,
                    )),
          ),
          const SizedBox(height: Space.sm),
          _askControl(context, me, repo, PlanningKind.emergency),
        ],
      ),
    );
  }

  /// The reverse direction for a [kind]: do I have permission to plan for them,
  /// and if not, the ask. Three resolved states — already allowed, request
  /// pending, or ask.
  Widget _askControl(BuildContext context, String me,
      PlanningPermissionRepository repo, PlanningKind kind) {
    final emergency = kind == PlanningKind.emergency;
    final iCan = (emergency
            ? ref.watch(iCanEmergencyPlanForProvider(widget.uid))
            : ref.watch(iCanPlanForProvider(widget.uid)))
        .value ??
        false;
    if (iCan) {
      return Row(
        children: [
          Icon(AppIcons.approved,
              size: Sizes.inlineIcon, color: context.colors.primary),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
                emergency
                    ? 'You can set emergency alarms for ${widget.name}.'
                    : 'You can plan for ${widget.name}.',
                style: context.text.bodyMedium),
          ),
        ],
      );
    }

    final pending = (emergency
            ? ref.watch(outgoingEmergencyRequestProvider(widget.uid))
            : ref.watch(outgoingPlanningRequestProvider(widget.uid)))
        .value;
    // `busy: false`, deliberately: the live stream flips this control to its new
    // state (Ask → Requested) on its own, so the stream is the feedback. Swapping
    // to a spinner on the section-wide `_busy` made BOTH asks blank out whenever
    // ANY of the four controls was tapped — the reported flicker. `_run` still
    // guards against a double-tap.
    if (pending != null) {
      return _Action(
        icon: AppIcons.declineFriend,
        label: 'Requested — tap to withdraw',
        filled: false,
        busy: false,
        onPressed: () => _run(() => repo.deleteRequest(pending)),
      );
    }

    return _Action(
      icon: emergency ? AppIcons.emergency : AppIcons.navPlan,
      label: emergency
          ? 'Ask to set emergency alarms for ${widget.name}'
          : 'Ask to plan for ${widget.name}',
      filled: false,
      busy: false,
      onPressed: () => _run(() =>
          repo.sendRequest(fromUid: me, toUid: widget.uid, kind: kind)),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.filled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(
            height: Sizes.buttonSpinner,
            width: Sizes.buttonSpinner,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final handler = busy ? null : onPressed;

    return filled
        ? FilledButton.icon(
            onPressed: handler, icon: Icon(icon), label: child)
        : OutlinedButton.icon(
            onPressed: handler, icon: Icon(icon), label: child);
  }
}

/// Severances and reporting, folded into a menu.
///
/// Everything here changes a relationship or accuses someone, so none of it
/// belongs on the main surface where a mis-tap reaches it — the same reasoning
/// as [AppIcons.overflow] on a card.
class _ProfileOverflowMenu extends ConsumerWidget {
  const _ProfileOverflowMenu({required this.uid, required this.visibility});

  final String uid;
  final ProfileVisibility visibility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(AppIcons.overflow),
      tooltip: 'More',
      onSelected: (value) async {
        final me = ref.read(currentUidProvider);
        if (me == null) return;
        final messenger = ScaffoldMessenger.of(context);

        switch (value) {
          case 'unfriend':
            final confirmed = await _confirm(
              context,
              title: 'Remove friend?',
              body: "You'll both stop seeing each other's stats. Either of "
                  'you can send a new request later.',
              action: 'Remove',
            );
            if (confirmed) {
              await ref
                  .read(friendRepositoryProvider)
                  .removeFriend(uid: me, otherUid: uid);
            }

          case 'block':
            // The copy states every consequence, including the one people do
            // not expect — that a live planner grant is revoked, i.e. this
            // person can no longer put anything on your schedule. Softening a
            // destructive act is the same dishonesty as harshening a
            // reversible one (UI-RULES.md, and AppIcons.removeMember).
            final confirmed = await _confirm(
              context,
              title: 'Block this person?',
              body: "You won't see each other's profiles, and any friendship, "
                  'pending request and permission to plan on your schedule is '
                  'removed. Existing plans stay — you can withdraw or reject '
                  'them yourself.',
              action: 'Block',
            );
            if (confirmed) {
              await ref
                  .read(blockRepositoryProvider)
                  .block(blockerUid: me, blockedUid: uid);
            }

          case 'report':
            // No moderation queue exists yet, and the UI does not pretend one
            // does. Flagging writes the state the read path already honours;
            // what it cannot promise is a review, so the confirmation does not
            // claim one. See AvatarModeration.
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'Reported. Blocking is the fastest way to stop seeing '
                    'someone.',
                  ),
                ),
              );
        }
      },
      itemBuilder: (context) => [
        if (visibility.relation == ProfileRelation.friend)
          const PopupMenuItem(
            value: 'unfriend',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(AppIcons.removeFriend),
              title: Text('Remove friend'),
            ),
          ),
        const PopupMenuItem(
          value: 'report',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.report),
            title: Text('Report'),
          ),
        ),
        if (visibility.canBlock)
          const PopupMenuItem(
            value: 'block',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(AppIcons.block),
              title: Text('Block'),
            ),
          ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final result = await showDialog<bool>(
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
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}
