import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../routing/app_router.dart';
import '../application/model_setup_controller.dart';
import '../domain/model_setup_state.dart';
import 'chat_screen.dart';
import 'model_setup_screen.dart';

/// What `/chatbot` actually builds: the chat, or the reason it cannot open yet.
///
/// **The chat has no fallback any more.** Replies come from the model files on
/// this phone, so without them there is nothing to talk to — no laptop to reach,
/// no address to fix. Rendering a chat that could only ever answer with an error
/// would be a worse lie than a screen that says what is missing and offers the
/// one action that fixes it.
///
/// Three journeys through here, and only the first costs anything:
///
///  - **First time.** The check finds nothing and stops at [ModelNeeded] — a
///    download prompt with the size on it. Nothing is fetched until the button
///    is tapped.
///  - **Mid-download.** Progress, resumable, and it survives leaving the screen.
///  - **Every time after.** The check passes in a few hundred milliseconds and
///    the chat appears; the gate is invisible.
///
/// It sits **outside** [ChatScreen] deliberately, handing over to it whole
/// rather than wrapping it. `ChatScreen`'s State holds the transcript and mints
/// the `session_id`, so building it only once the model is ready means a session
/// begins when practice begins — not when someone glanced at a download prompt
/// (DECISIONS.md, 2026-08-18).
class ChatGate extends ConsumerWidget {
  const ChatGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(modelSetupControllerProvider);

    // Handed over entirely: ChatScreen brings its own Scaffold, AppBar and
    // overflow menu, and the gate leaves no wrapper behind to fight with them.
    if (state is ModelReady) return const ChatScreen();

    return Scaffold(
      // The pre-model states need a back arrow of their own, and a deliberately
      // plainer bar than the chat's — there is no transcript to act on yet.
      appBar: AppBar(
        title: const Text('Language practice'),
        actions: [
          IconButton(
            tooltip: 'Offline model',
            icon: const Icon(AppIcons.offlineModel),
            onPressed: () => context.push(Routes.chatbotModel),
          ),
        ],
      ),
      body: const SafeArea(child: ModelSetupBody()),
    );
  }
}
