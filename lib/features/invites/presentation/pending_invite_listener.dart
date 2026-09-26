import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/presentation/groups_screen.dart';
import '../../social/application/social_providers.dart';
import '../application/pending_invite.dart';
import '../domain/invite_link.dart';

/// Acts on an invite link once the person is fully inside the app (it sits
/// in HomeShell, past sign-in, profile setup and permissions). A friend
/// invite opens that person's profile, where Add friend lives; a group invite
/// opens the join dialog with the code filled in. Nothing is sent without the
/// person tapping — a link never acts on its own.
class PendingInviteListener extends ConsumerStatefulWidget {
  const PendingInviteListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PendingInviteListener> createState() =>
      _PendingInviteListenerState();
}

class _PendingInviteListenerState extends ConsumerState<PendingInviteListener> {
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    // An invite that arrived during sign-in / setup, before this existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
  }

  Future<void> _consume() async {
    if (!mounted || _handling) return;
    final invite = ref.read(pendingInviteProvider.notifier).take();
    if (invite == null) return;
    _handling = true;
    try {
      await handleInvite(context, ref, invite);
    } finally {
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<InviteLink?>(pendingInviteProvider, (_, next) {
      if (next != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _consume());
      }
    });
    return widget.child;
  }
}

/// What an invite does. Exposed for tests.
Future<void> handleInvite(
  BuildContext context,
  WidgetRef ref,
  InviteLink invite,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  switch (invite.kind) {
    case InviteKind.group:
      await showGroupJoinDialog(context, ref, initialCode: invite.value);
    case InviteKind.user:
      String? uid;
      try {
        uid = await ref.read(usernameRepositoryProvider).lookup(invite.value);
      } catch (_) {
        uid = null;
      }
      if (!context.mounted) return;
      if (uid == null) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text('No one is using the username ${invite.value}.'),
          ),
        );
        return;
      }
      if (uid == ref.read(currentUidProvider)) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('That is your own invite link.')),
        );
        return;
      }
      await context.push(Routes.userProfileFor(uid));
  }
}
