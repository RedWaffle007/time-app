import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../auth/application/auth_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/archive_providers.dart';

/// The card overflow menu carrying Archive, in both My Schedule and Activity.
/// One widget rather than two copies, so the guard, the wording and the undo
/// affordance cannot drift apart between the two screens.
///
/// **Overflow, not an inline button.** Settled cards sit in scrollable lists,
/// and an always-visible Archive control there invites a mis-tap mid-scroll —
/// on an action whose whole job is to make a row disappear. Archive is a
/// secondary action on the card; it belongs behind the ⋮.
///
/// **Never the word "delete", and never a bin glyph.** The document is
/// untouched, the other party still sees it and was not told — copy that
/// implied otherwise would be the exact dishonesty "delete for me" was rejected
/// for (DECISIONS.md "Group D").
///
/// This is the **manual** route only — done / skipped. Rejected and withdrawn
/// items are auto-hidden by a view rule the moment their status is set and never
/// reach a card, so they never need (or get) this menu. Callers must gate on
/// [ScheduleItem.isManuallyArchivable]; the assert catches it if one forgets.
class ArchiveMenuButton extends ConsumerWidget {
  const ArchiveMenuButton({super.key, required this.item});

  final ScheduleItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    assert(item.isManuallyArchivable,
        'manual archive is for items with a recorded outcome only');

    return PopupMenuButton<String>(
      icon: const Icon(AppIcons.overflow),
      tooltip: 'More',
      onSelected: (value) {
        if (value == 'archive') _archive(context, ref);
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'archive', child: Text('Archive')),
      ],
    );
  }

  /// No confirmation dialog. A dialog would frame this as consequential, and it
  /// is not: the row moves to the Archived screen and comes straight back. The
  /// undo action carries the reversibility instead — and says the quiet part
  /// ("hidden from your views") where the user is looking.
  ///
  /// The Undo belongs to this route alone. Auto-archive writes nothing, so it
  /// has nothing to undo and deliberately shows no snackbar at all.
  ///
  /// **`persist: false` is load-bearing, not a tidy-up.** A [SnackBar] carrying
  /// a [SnackBarAction] defaults to `persist: true` (`snack_bar.dart:303`), and
  /// the dismiss timer then fires into a no-op (`scaffold.dart:619-626`) — so
  /// this snackbar never timed out, and setting a `duration` would not have
  /// helped. It outlived sign-out and even a sign-in as a different account,
  /// because `MaterialApp` builds the `ScaffoldMessenger` ABOVE the Router
  /// (`material/app.dart:1047`) where no route or auth change can reach it.
  ///
  /// The `uid` re-check inside `Undo` closes the other half of that, and does it
  /// independently of the auth-change teardown in `app.dart`. `uid` is captured
  /// when the snackbar is shown; if the account changed before the tap, this
  /// write would land in the PREVIOUS account's archive document — a real
  /// cross-account write, not a cosmetic leak. Ownership is therefore re-checked
  /// at TAP time, not trusted from capture time.
  ///
  /// `auth` is captured here rather than `ref.read` inside the closure on
  /// purpose: archiving removes this card from the list, so the widget (and its
  /// `WidgetRef`) may already be disposed by the time Undo is tapped. Holding
  /// the repository object is the same pattern the `repository` capture uses.
  Future<void> _archive(BuildContext context, WidgetRef ref) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(archiveRepositoryProvider);
    final auth = ref.read(authRepositoryProvider);

    await repository.archive(uid, item.id);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        persist: false,
        content: const Text('Archived — hidden from your views only.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (auth.currentUser?.uid != uid) return;
            repository.unarchive(uid, item.id);
          },
        ),
      ),
    );
  }
}
