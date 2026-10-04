import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/voice_note_cache.dart';
import '../application/voice_note_providers.dart';
import '../data/voice_note_client.dart';
import '../domain/voice_library_note.dart';
import 'voice_library_screen.dart';
import 'voice_note_recorder.dart';

/// The library note chosen for an alarm, with a preview and the way back to
/// recording (32d; big Play/X per Batch G item 9). Shared by the Plan screen
/// and the group plan sheet (2026-09-27) so both look and behave the same.
class LibraryNoteChoice extends ConsumerStatefulWidget {
  const LibraryNoteChoice({
    super.key,
    required this.note,
    required this.enabled,
    required this.onRemove,
  });

  final VoiceLibraryNote note;
  final bool enabled;

  /// "Record instead": the caller drops the chosen note.
  final VoidCallback onRemove;

  @override
  ConsumerState<LibraryNoteChoice> createState() => _LibraryNoteChoiceState();
}

class _LibraryNoteChoiceState extends ConsumerState<LibraryNoteChoice> {
  bool _playing = false;
  StreamSubscription<void>? _done;

  @override
  void dispose() {
    _done?.cancel();
    super.dispose();
  }

  Future<void> _stop() async {
    if (!_playing) return;
    await ref.read(voicePlayerProvider).stop();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (_playing) return _stop();
    final player = ref.read(voicePlayerProvider);
    try {
      final path = await ref
          .read(voiceNoteCacheProvider)
          .ensureLibrary(widget.note);
      _done?.cancel();
      _done = player.completed.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
      await player.play(path);
      if (mounted) setState(() => _playing = true);
    } on VoiceNoteFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return Card(
      key: const ValueKey('library-choice'),
      child: ListTile(
        leading: const Icon(AppIcons.voiceLibrary),
        title: Text(
          voiceNoteLabel(context, note),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'From your library · ${formatVoiceLength(note.length)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('library-choice-play'),
              tooltip: _playing ? 'Stop' : 'Play',
              iconSize: Sizes.voiceChoiceIcon,
              constraints: const BoxConstraints.tightFor(
                width: Sizes.voiceChoiceButton,
                height: Sizes.voiceChoiceButton,
              ),
              onPressed: widget.enabled ? _toggle : null,
              icon: Icon(
                _playing
                    ? AppIcons.voiceNoteStopPlaying
                    : AppIcons.voiceNotePlay,
              ),
            ),
            IconButton(
              key: const ValueKey('library-choice-remove'),
              tooltip: 'Record instead',
              iconSize: Sizes.voiceChoiceIcon,
              constraints: const BoxConstraints.tightFor(
                width: Sizes.voiceChoiceButton,
                height: Sizes.voiceChoiceButton,
              ),
              onPressed: widget.enabled
                  ? () async {
                      await _stop();
                      widget.onRemove();
                    }
                  : null,
              icon: const Icon(AppIcons.voiceNoteDiscard),
            ),
          ],
        ),
      ),
    );
  }
}
