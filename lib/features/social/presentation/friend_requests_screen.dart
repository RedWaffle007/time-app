import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../notifications/application/friend_notifier.dart';
import '../application/social_providers.dart';
import '../domain/friend_request.dart';
import '../domain/planning_request.dart';
import 'user_row.dart';

/// Incoming requests to decide, and outgoing ones to withdraw.
///
/// Both on one screen, with incoming first and marked as the attention section.
/// They are two halves of one question — "what friend requests are in flight?"
/// — and splitting them across tabs would hide the half that is usually empty
/// behind a tap.
class FriendRequestsScreen extends ConsumerWidget {
  const FriendRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(incomingRequestsProvider);
    final outgoing = ref.watch(outgoingRequestsProvider);
    final planning = ref.watch(incomingPlanningRequestsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Requests')),
      body: AsyncView<List<FriendRequest>>(
        value: incoming,
        onRetry: () => ref.invalidate(incomingRequestsProvider),
        builder: (context, incomingRequests) {
          final outgoingRequests = outgoing.value ?? const <FriendRequest>[];
          final planningRequests =
              planning.value ?? const <PlanningRequest>[];

          if (incomingRequests.isEmpty &&
              outgoingRequests.isEmpty &&
              planningRequests.isEmpty) {
            return const _NoRequests();
          }

          return ListView(
            padding: Space.screenList,
            children: [
              if (incomingRequests.isNotEmpty) ...[
                // `attention: true` is a CLAIM that this section holds
                // something waiting on the user — which is exactly what an
                // undecided request is. Not a styling choice (SectionHeader).
                const SectionHeader('Waiting on you', attention: true),
                for (final request in incomingRequests)
                  _IncomingRow(request: request),
              ],
              if (planningRequests.isNotEmpty) ...[
                // Distinct from a friend request: this asks for permission to
                // PLAN for you, not to be friends (you already are).
                const SectionHeader('Permission to plan', attention: true),
                for (final request in planningRequests)
                  _PlanningRow(request: request),
              ],
              if (outgoingRequests.isNotEmpty) ...[
                const SectionHeader('Sent'),
                for (final request in outgoingRequests)
                  _OutgoingRow(request: request),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _IncomingRow extends ConsumerStatefulWidget {
  const _IncomingRow({required this.request});
  final FriendRequest request;

  @override
  ConsumerState<_IncomingRow> createState() => _IncomingRowState();
}

class _IncomingRowState extends ConsumerState<_IncomingRow> {
  bool _busy = false;

  Future<void> _decide(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      // No success message. The row disappears from the list the moment the
      // write lands — the list IS the feedback, and a snackbar on top of it
      // would be telling the user something they can already see.
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
    final repo = ref.read(friendRepositoryProvider);
    // Captured HERE, while the row is alive. Accepting removes this request from
    // the pending list, which disposes the row — so reading the notifier AFTER
    // `acceptRequest`'s await would run `ref.read` on a dead widget and throw
    // before the push fires (silently, since `mounted` is then false). Holding
    // the notifier object across the await avoids that. See DECISIONS.md
    // "Friend-request push".
    final notifier = ref.read(friendEventNotifierProvider);
    return UserRow(
      uid: widget.request.fromUid,
      subtitle: 'Wants to be friends',
      trailing: _busy
          ? const SizedBox(
              height: Sizes.buttonSpinner,
              width: Sizes.buttonSpinner,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Decline',
                  icon: const Icon(AppIcons.declineFriend),
                  onPressed: () =>
                      _decide(() => repo.rejectRequest(widget.request)),
                ),
                IconButton.filled(
                  tooltip: 'Accept',
                  icon: const Icon(AppIcons.acceptFriend),
                  onPressed: () => _decide(() async {
                    await repo.acceptRequest(widget.request);
                    // Notify the original sender they were accepted. `notifier`
                    // is captured in build(), NOT read here — this row is
                    // disposed the instant the accept lands.
                    await notifier.notify(
                      event: FriendNotifyEvent.friendAccept,
                      fromUid: widget.request.fromUid,
                      toUid: widget.request.toUid,
                    );
                  }),
                ),
              ],
            ),
    );
  }
}

/// An incoming request for permission to PLAN for the signed-in user (#4).
/// Approving writes the friendship grant (the target authors it) and clears the
/// ask; declining just removes it. Kept distinct from a friend request and from
/// approving a single plan.
class _PlanningRow extends ConsumerStatefulWidget {
  const _PlanningRow({required this.request});
  final PlanningRequest request;

  @override
  ConsumerState<_PlanningRow> createState() => _PlanningRowState();
}

class _PlanningRowState extends ConsumerState<_PlanningRow> {
  bool _busy = false;

  Future<void> _decide(Future<void> Function() action) async {
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
    final repo = ref.read(planningPermissionRepositoryProvider);
    // Captured while the row is alive — approving deletes the request, which
    // disposes this row, so reading the notifier after the await would run on a
    // dead widget. Same pattern as the friend-accept row above.
    final notifier = ref.read(friendEventNotifierProvider);
    final emergency = widget.request.kind == PlanningKind.emergency;
    return UserRow(
      uid: widget.request.fromUid,
      subtitle: emergency
          ? 'Wants to set emergency alarms for you'
          : 'Wants to plan for you',
      trailing: _busy
          ? const SizedBox(
              height: Sizes.buttonSpinner,
              width: Sizes.buttonSpinner,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Decline',
                  icon: const Icon(AppIcons.declineFriend),
                  onPressed: () =>
                      _decide(() => repo.deleteRequest(widget.request)),
                ),
                IconButton.filled(
                  tooltip: 'Allow',
                  icon: const Icon(AppIcons.acceptFriend),
                  onPressed: () => _decide(() async {
                    await repo.approve(widget.request);
                    // Tell the requester it was granted. Best-effort, NOT
                    // awaited; `notifier` was captured in build().
                    unawaited(notifier.notify(
                      event: FriendNotifyEvent.planningApprove,
                      fromUid: widget.request.fromUid,
                      toUid: widget.request.toUid,
                      kind: widget.request.kind.name,
                    ));
                  }),
                ),
              ],
            ),
    );
  }
}

class _OutgoingRow extends ConsumerWidget {
  const _OutgoingRow({required this.request});
  final FriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return UserRow(
      uid: request.toUid,
      subtitle: 'Request sent',
      trailing: IconButton(
        tooltip: 'Withdraw request',
        icon: const Icon(AppIcons.declineFriend),
        onPressed: () =>
            ref.read(friendRepositoryProvider).cancelRequest(request),
      ),
    );
  }
}

class _NoRequests extends StatelessWidget {
  const _NoRequests();

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.emptyRequests,
                size: Sizes.emptyStateIcon, color: muted),
            const SizedBox(height: Space.md),
            Text(
              'No friend requests right now.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
