import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_tokens.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/voice_note_cache.dart';
import '../application/voice_note_providers.dart';
import '../data/voice_note_client.dart';
import '../data/voice_player.dart';
import 'voice_note_recorder.dart' show formatVoiceLength;

/// "Play voice note" on a plan waiting for approval (item 32b): the target
/// hears exactly what their alarm will play before consenting to it.
class VoiceNotePlayButton extends ConsumerStatefulWidget {
  const VoiceNotePlayButton({super.key, required this.item});

  final ScheduleItem item;

  @override
  ConsumerState<VoiceNotePlayButton> createState() =>
      _VoiceNotePlayButtonState();
}

class _VoiceNotePlayButtonState extends ConsumerState<VoiceNotePlayButton> {
  // Read in initState, never lazily: dispose must not touch `ref`.
  late final VoicePlayer _player;
  StreamSubscription<void>? _completion;
  bool _loading = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player = ref.read(voicePlayerProvider);
    _completion = _player.completed.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _completion?.cancel();
    if (_playing) unawaited(_player.stop());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final path = await ref.read(voiceNoteCacheProvider).ensure(widget.item);
      await _player.play(path);
      if (mounted) setState(() => _playing = true);
    } on VoiceNoteFailure catch (e) {
      _say(e.message);
    } on Object {
      _say(voiceNoteErrorMessage(null));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final length = formatVoiceLength(
      Duration(milliseconds: widget.item.voiceNote?.durationMs ?? 0),
    );
    return OutlinedButton.icon(
      key: const ValueKey('play-voice-note'),
      onPressed: _loading ? null : _toggle,
      icon: _loading
          ? const SizedBox(
              height: Sizes.buttonSpinner,
              width: Sizes.buttonSpinner,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(_playing ? AppIcons.voiceNoteStopPlaying : AppIcons.voiceNote),
      label: Text(_playing ? 'Stop voice note' : 'Play voice note · $length'),
    );
  }
}
