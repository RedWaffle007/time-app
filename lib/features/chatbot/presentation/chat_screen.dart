import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/warning_panel.dart';
import '../../../routing/app_router.dart';
import '../application/chatbot_providers.dart';
import '../data/chatbot_service.dart';
import '../domain/chat_message.dart';

/// The language-practice chat.
///
/// **Deliberately apart from the delegation app.** It shares the theme, the
/// icon vocabulary and the router and nothing else: no group, no schedule item,
/// no approval, no Firestore document and no push. It is reached from the account
/// menu (and, in debug builds, the dev menu) — from nowhere in the core loop.
///
/// It is **pushed**, never a tab, which is what keeps the session boundary below
/// honest: a tab in the shell's indexed stack would stay mounted forever, and
/// this State with it (DECISIONS.md, 2026-08-18).
///
/// The transcript lives in this widget's State, not in a provider. That is the
/// feature, not a shortcut: a practice session is one sitting, so leaving the
/// screen ends it — the same boundary the `session_id` draws for the service.
/// A provider-held transcript would quietly resurrect yesterday's conversation
/// under a session id the backend had already forgotten.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messages = <ChatMessage>[];
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  /// One continuous conversation, generated per screen session and never
  /// persisted. Time plus randomness, so two devices practising at once cannot
  /// collide on the service.
  late final String _sessionId =
      'app-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  /// True while a turn is in flight. Blocks a second send, because two
  /// overlapping turns would land in the transcript in whatever order the
  /// network decided.
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Run one turn.
  ///
  /// [isNewTurn] is false when retrying a failed turn: the user's message is
  /// already in the transcript, and adding it again would show them saying the
  /// same thing twice.
  Future<void> _send(String text, {bool isNewTurn = true}) async {
    final message = text.trim();
    if (message.isEmpty || _sending) return;

    setState(() {
      if (isNewTurn) _messages.add(UserMessage(message));
      _sending = true;
    });
    _input.clear();

    try {
      final reply = await ref
          .read(chatbotServiceProvider)
          .send(sessionId: _sessionId, message: message);
      if (!mounted) return;
      setState(() => _messages.add(BotMessage(reply)));
    } on ChatbotFailure catch (failure) {
      if (!mounted) return;
      // The seam promises this is the only thing that can be thrown, and that
      // its message is already written for a person. Rendering it verbatim is
      // what makes an unreachable laptop read as "wake the laptop" instead of
      // as a crash.
      setState(() => _messages
          .add(FailureMessage(text: failure.message, retryOf: message)));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        // Keep the keyboard where it was, so a reply doesn't cost a tap.
        _inputFocus.requestFocus();
      }
    }
  }

  void _retry(FailureMessage failure) {
    setState(() => _messages.remove(failure));
    _send(failure.retryOf, isNewTurn: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Language practice'),
        actions: [
          // One item, because there is one thing to say about a chat that runs
          // on this phone: where its model is.
          //
          // "Service address" was removed when the engine moved on-device. It
          // edits an address that nothing reads any more, so leaving it here
          // would invite someone to fix a connection problem they do not have.
          // The screen still exists, reachable from the dev menu, because it
          // becomes meaningful again the moment `chatbotServiceProvider` is
          // pointed back at HTTP for a comparison (DECISIONS.md, 2026-08-19).
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(AppIcons.overflow),
            onSelected: (route) => context.push(route),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: Routes.chatbotModel,
                child: ListTile(
                  leading: Icon(AppIcons.offlineModel),
                  title: Text('Offline model'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && !_sending
                ? const _EmptyTranscript()
                : _Transcript(
                    messages: _messages,
                    sending: _sending,
                    onRetry: _retry,
                  ),
          ),
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// The message list, newest at the bottom.
///
/// `reverse: true` over a reversed index rather than a ScrollController: the
/// list then pins itself to the newest message as it grows and when the
/// keyboard opens, with no scroll animation to schedule after each setState.
class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.messages,
    required this.sending,
    required this.onRetry,
  });

  final List<ChatMessage> messages;
  final bool sending;
  final void Function(FailureMessage failure) onRetry;

  @override
  Widget build(BuildContext context) {
    // The in-flight indicator occupies the newest slot while a turn is running.
    final pending = sending ? 1 : 0;

    return ListView.builder(
      reverse: true,
      padding: Space.screenList,
      itemCount: messages.length + pending,
      itemBuilder: (context, index) {
        if (index < pending) return const _Thinking();
        final message = messages[messages.length - 1 - (index - pending)];
        return switch (message) {
          UserMessage(:final text) => _Bubble(
              fromUser: true,
              child: Text(text, style: context.text.bodyLarge),
            ),
          BotMessage(:final reply) => _Bubble(
              fromUser: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // German leads: it is the thing being practised.
                  Text(reply.german, style: context.text.bodyLarge),
                  if (reply.english.isNotEmpty) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      reply.english,
                      style: context.text.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                  // A miss is marked, never hidden and never dramatised — line
                  // work and muted text, so it reads as a note about this reply
                  // rather than as something gone wrong (§2.7).
                  if (!reply.matched) ...[
                    const SizedBox(height: Space.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          AppIcons.noMatch,
                          size: Sizes.badgeIcon,
                          color: context.colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: Space.xs),
                        Expanded(
                          child: Text(
                            'No close match — try saying it another way.',
                            style: context.text.labelSmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          // Not a bubble: a failed turn is not something the bot said.
          FailureMessage failure => Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WarningPanel(failure.text),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => onRetry(failure),
                      icon: const Icon(AppIcons.retry, size: Sizes.inlineIcon),
                      label: const Text('Try again'),
                    ),
                  ),
                ],
              ),
            ),
        };
      },
    );
  }
}

/// One side of the conversation.
///
/// **Neutral fills on purpose.** Side and tone carry who is speaking; green and
/// orange are not spent here. Under §2.7 a filled shape is *state*, and a chat
/// bubble is not a state — a green bubble would read as affirmation and an
/// orange one as "waiting on you", which is the one signal the app cannot
/// afford to dilute.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.fromUser, required this.child});

  final bool fromUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bubble = Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: fromUser
              ? context.colors.surfaceContainerHigh
              : context.colors.surface,
          borderRadius: Radii.md,
          border: Border.all(color: context.colors.outlineVariant),
        ),
        child: child,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        children: [
          // The gutter opposite the speaker is what keeps a long message from
          // spanning the full width and losing its side. A spacer rather than
          // an asymmetric EdgeInsets, so every value on screen is a token.
          if (fromUser) const SizedBox(width: Space.xxxl),
          Expanded(child: bubble),
          if (!fromUser) const SizedBox(width: Space.xxxl),
        ],
      ),
    );
  }
}

/// The turn in flight, in the bot's slot so the wait has a place on screen.
class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    return _Bubble(
      fromUser: false,
      child: SizedBox(
        width: Sizes.buttonSpinner,
        height: Sizes.buttonSpinner,
        child: CircularProgressIndicator(
          strokeWidth: Sizes.ruleWidth - 1,
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Nothing said yet. Follows the §6.5 empty-state recipe.
class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.emptyGeneric,
              size: Sizes.emptyStateIcon,
              color: context.colors.primary,
            ),
            const SizedBox(height: Space.md),
            Text('Practise German', style: context.text.titleMedium),
            const SizedBox(height: Space.sm),
            Text(
              'Say anything to start. Replies come back in German with an '
              'English gloss underneath.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The input row. Pinned under the transcript, above the keyboard.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final void Function(String text) onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border(
            top: BorderSide(
              color: context.colors.outlineVariant,
              width: Sizes.hairline,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: !sending,
                minLines: 1,
                // Grows with a longer sentence, then scrolls — a practice
                // message is a sentence or two, not an essay.
                maxLines: 4,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Type a message'),
                onSubmitted: onSend,
              ),
            ),
            const SizedBox(width: Space.sm),
            IconButton.filled(
              tooltip: 'Send',
              onPressed: sending ? null : () => onSend(controller.text),
              icon: sending
                  ? SizedBox(
                      width: Sizes.buttonSpinner,
                      height: Sizes.buttonSpinner,
                      child: CircularProgressIndicator(
                        strokeWidth: Sizes.ruleWidth - 1,
                        color: context.colors.onSurfaceVariant,
                      ),
                    )
                  : const Icon(AppIcons.send),
            ),
          ],
        ),
      ),
    );
  }
}
