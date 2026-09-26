import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/invite_link.dart';

/// An invite link that arrived but cannot be acted on yet — the person must
/// first get past sign-in, profile setup and permissions. The router stores
/// it; `PendingInviteListener` (inside HomeShell, reached only past every
/// gate) consumes it exactly once.
class PendingInviteNotifier extends Notifier<InviteLink?> {
  @override
  InviteLink? build() => null;

  void set(InviteLink invite) => state = invite;

  /// Returns the pending invite and clears it, so it is handled once.
  InviteLink? take() {
    final invite = state;
    state = null;
    return invite;
  }
}

final pendingInviteProvider =
    NotifierProvider<PendingInviteNotifier, InviteLink?>(
      PendingInviteNotifier.new,
    );
