import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';

/// R6 (2026-10-02): the target's optional note to the planner.
///
/// "Send note" sits BESIDE the answer buttons (Skip / Done, Already heard /
/// Play) and on the ringing voice alarm as "Dismiss & reply". Tapping an
/// answer directly means no note; there is never an extra prompt. One note
/// per plan, never edited, sent as its own push to the planner.

/// The prompt line: "Optional: send a note to {planner} about this alarm."
String sendNotePrompt(ScheduleItem item, {String? plannerName}) {
  final name = plannerName?.trim();
  final who = name == null || name.isEmpty ? 'your planner' : name;
  final what = item.isVoiceAlarm ? 'voice note' : 'alarm';
  return 'Optional: send a note to $who about this $what.';
}

/// Opens the note pop-up. Resolves true once the note is saved (the push to
/// the planner follows in the background), false when cancelled.
Future<bool> showSendNoteDialog(
  BuildContext context,
  WidgetRef ref,
  ScheduleItem item,
) async {
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => _SendNoteDialog(item: item),
  );
  return sent ?? false;
}

class _SendNoteDialog extends ConsumerStatefulWidget {
  const _SendNoteDialog({required this.item});

  final ScheduleItem item;

  @override
  ConsumerState<_SendNoteDialog> createState() => _SendNoteDialogState();
}

class _SendNoteDialogState extends ConsumerState<_SendNoteDialog> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final item = widget.item;
    try {
      await ref
          .read(scheduleRepositoryProvider)
          .sendReply(item.targetUid, item.id, text);
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = "Couldn't send. Check your connection and try again.";
        });
      }
      return;
    }
    // The note is saved; the planner's push must never hold the screen.
    unawaited(
      ref
          .read(notificationEventNotifierProvider)
          .notify(
            event: NotifyEvent.replied,
            targetUid: item.targetUid,
            itemId: item.id,
          ),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final plannerName = ref
        .watch(profileByUidProvider(widget.item.createdByUid))
        .value
        ?.name;
    final canSend = _text.text.trim().isNotEmpty && !_sending;
    return AlertDialog(
      scrollable: true,
      title: const Text('Send note'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            sendNotePrompt(widget.item, plannerName: plannerName),
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const ValueKey('send-note-text'),
            controller: _text,
            autofocus: true,
            enabled: !_sending,
            maxLength: ScheduleReply.maxLength,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Your note'),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              _error!,
              key: const ValueKey('send-note-error'),
              style: context.text.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('send-note-send'),
          onPressed: canSend ? _send : null,
          child: Text(_sending ? 'Sending…' : 'Send'),
        ),
      ],
    );
  }
}

/// "Send note", beside the answer buttons. Text only, like Skip and Done.
class SendNoteButton extends ConsumerWidget {
  const SendNoteButton({
    super.key,
    required this.item,
    this.enabled = true,
    this.onSent,
  });

  final ScheduleItem item;
  final bool enabled;

  /// After a note is saved (a snapshot holder, like the missed popup, hides
  /// the button itself; a live card just rebuilds from the stream).
  final VoidCallback? onSent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      key: ValueKey('send-note-${item.id}'),
      onPressed: enabled
          ? () async {
              if (await showSendNoteDialog(context, ref, item)) onSent?.call();
            }
          : null,
      child: const Text('Send note'),
    );
  }
}

/// "Note" on a History card (both people), only when a note was sent: opens
/// it. The target reads "Your note"; the planner "Note from {name}".
class ReplyNoteButton extends ConsumerWidget {
  const ReplyNoteButton({
    super.key,
    required this.item,
    required this.iAmTarget,
  });

  final ScheduleItem item;
  final bool iAmTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reply = item.reply;
    if (reply == null) return const SizedBox.shrink();
    return TextButton(
      key: ValueKey('reply-note-${item.id}'),
      onPressed: () {
        final name = iAmTarget
            ? null
            : ref.read(profileByUidProvider(item.targetUid)).value?.name;
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            scrollable: true,
            title: Text(
              iAmTarget ? 'Your note' : 'Note from ${name ?? 'them'}',
            ),
            content: Text(
              reply.text,
              key: const ValueKey('reply-note-text'),
              style: context.text.bodyLarge,
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
      child: const Text('Note'),
    );
  }
}
