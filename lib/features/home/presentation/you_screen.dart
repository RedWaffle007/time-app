import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/nav_tile.dart';
import '../../../core/widgets/tab_body_inset.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../social/application/social_providers.dart';
import '../../social/presentation/user_profile_screen.dart';
import '../../voice_notes/application/voice_note_providers.dart';

/// **The You pillar = your own profile** (Batch H1, DECISIONS.md "You = your
/// profile; Settings holds the rest").
///
/// It renders [ProfileBody], the same layout anyone visiting you sees, so you
/// always know what your profile looks like to others. The body swaps the
/// relationship slot for **Edit profile**; the app bar carries a **Settings**
/// gear for everything that is not your public identity. Friends and Voice
/// notes stay one tap away under the header.
class YouScreen extends ConsumerWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUidProvider);
    final profile = ref.watch(profileProvider).value;
    final pendingRequests = ref.watch(incomingRequestCountProvider);
    // Keep the Voice notes list loaded while You is on screen, so opening it
    // shows the notes at once instead of a spinner that swaps to the list
    // mid-transition (the lag reported 2026-09-27). Listened, not watched:
    // a new note never rebuilds this screen.
    ref.listen(voiceLibraryProvider, (_, _) {});
    final username = profile?.username;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          username != null ? '@$username' : (profile?.name ?? 'You'),
        ),
        actions: [
          IconButton(
            key: const ValueKey('open-settings'),
            tooltip: 'Settings',
            icon: const Icon(AppIcons.settings),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: TabBodyInset(
        child: uid == null
            ? const SizedBox.shrink()
            : ProfileBody(
                uid: uid,
                selfLinks: [
                  NavTile(
                    icon: AppIcons.friends,
                    label: 'Friends',
                    badgeCount: pendingRequests,
                    onTap: () => context.push(Routes.friends),
                  ),
                  NavTile(
                    icon: AppIcons.voiceLibrary,
                    label: 'Voice notes',
                    onTap: () => context.push(Routes.voiceNotes),
                  ),
                ],
              ),
      ),
    );
  }
}
