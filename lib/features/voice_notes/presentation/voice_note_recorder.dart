import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/voice_note_providers.dart';
import '../data/voice_player.dart';
import '../data/voice_recorder.dart';

/// A recorded, not-yet-sent voice note.
class RecordedVoiceNote {
  const RecordedVoiceNote(this.path, this.length);
  final String path;
  final Duration length;
}

/// Where drafts are written. A provider so tests can point it at a temp dir.
final voiceDraftPathProvider = Provider<Future<String> Function()>((ref) {
  return () async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/voice-draft-${DateTime.now().microsecondsSinceEpoch}.m4a';
  };
});

/// "m:ss" for a duration — digits only, no words, so it reads in any locale.
String formatVoiceLength(Duration d) {
  final seconds = d.inSeconds.clamp(0, 5999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _Phase { idle, recording, recorded }

/// The schedule builder's voice-note section (item 32b): record up to 20 s
/// (auto-stops), then preview, discard or re-record. Reports the current
/// draft through [onChanged] (null = no voice note). Nothing is uploaded
/// here — the builder uploads on save.
class VoiceNoteRecorder extends ConsumerStatefulWidget {
  const VoiceNoteRecorder({
    super.key,
    required this.recipientName,
    required this.onChanged,
    this.enabled = true,
  });

  final String recipientName;
  final ValueChanged<RecordedVoiceNote?> onChanged;
  final bool enabled;

  @override
  ConsumerState<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

class _VoiceNoteRecorderState extends ConsumerState<VoiceNoteRecorder> {
  // Created in initState, never lazily: dispose must not touch `ref`.
  late final VoiceRecorder _recorder;
  late final VoicePlayer _player;
  StreamSubscription<void>? _completion;

  _Phase _phase = _Phase.idle;
  bool _playing = false;
  RecordedVoiceNote? _draft;
  final _clock = Stopwatch();
  Timer? _ticker;
  Timer? _hardStop;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _recorder = ref.read(voiceRecorderFactoryProvider)();
    _player = ref.read(voicePlayerProvider);
    _completion = _player.completed.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _hardStop?.cancel();
    _completion?.cancel();
    if (_playing) unawaited(_player.stop());
    if (_phase == _Phase.recording) unawaited(_recorder.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<bool> _ensurePermission() async {
    if (await _recorder.hasPermission()) return true;
    if (!mounted) return false;
    // The doctrine: explain on screen BEFORE the one-shot OS prompt.
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your microphone?'),
        content: Text(
          'Checkmate records a short voice note that plays when '
          "${widget.recipientName}'s alarm rings. The microphone is only on "
          'while you record.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go != true) return false;
    final granted = await _recorder.hasPermission(request: true);
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone is off for Checkmate. Turn it on in Settings to '
            'record a voice note.',
          ),
        ),
      );
    }
    return granted;
  }

  Future<void> _start() async {
    if (!await _ensurePermission() || !mounted) return;
    await _discardFile();
    final path = await ref.read(voiceDraftPathProvider)();
    try {
      await _recorder.start(path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't start recording. Try again.")),
        );
      }
      return;
    }
    _clock
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _elapsed = _clock.elapsed);
    });
    _hardStop = Timer(kMaxVoiceNote, _stop);
    setState(() {
      _phase = _Phase.recording;
      _elapsed = Duration.zero;
    });
  }

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    _ticker?.cancel();
    _hardStop?.cancel();
    _clock.stop();
    final length = _clock.elapsed > kMaxVoiceNote
        ? kMaxVoiceNote
        : _clock.elapsed;
    final path = await _recorder.stop();
    if (!mounted) return;
    if (path == null) {
      setState(() => _phase = _Phase.idle);
      widget.onChanged(null);
      return;
    }
    final draft = RecordedVoiceNote(path, length);
    setState(() {
      _phase = _Phase.recorded;
      _draft = draft;
      _elapsed = length;
    });
    widget.onChanged(draft);
  }

  Future<void> _togglePlay() async {
    final draft = _draft;
    if (draft == null) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    try {
      await _player.play(draft.path);
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _discardFile() async {
    final draft = _draft;
    _draft = null;
    if (_playing) {
      await _player.stop();
      _playing = false;
    }
    if (draft != null) {
      try {
        await File(draft.path).delete();
      } catch (_) {}
    }
  }

  Future<void> _discard() async {
    await _discardFile();
    if (!mounted) return;
    setState(() => _phase = _Phase.idle);
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Card(
      key: const ValueKey('voice-note-recorder'),
      child: Padding(
        padding: Space.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.voiceNote),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    'Voice note (optional)',
                    style: context.text.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              switch (_phase) {
                _Phase.idle =>
                  "Plays 3 times instead of the ringtone when ${widget.recipientName}'s "
                      'alarm rings. Up to 20 seconds.',
                _Phase.recording =>
                  'Recording… ${formatVoiceLength(_elapsed)} / '
                      '${formatVoiceLength(kMaxVoiceNote)}',
                _Phase.recorded =>
                  'Voice note ready · ${formatVoiceLength(_elapsed)}',
              },
              key: const ValueKey('voice-note-status'),
              style: muted,
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: switch (_phase) {
                _Phase.idle => [
                  OutlinedButton.icon(
                    onPressed: widget.enabled ? _start : null,
                    icon: const Icon(AppIcons.voiceNoteRecord),
                    label: const Text('Record'),
                  ),
                ],
                _Phase.recording => [
                  FilledButton.icon(
                    onPressed: _stop,
                    icon: const Icon(AppIcons.voiceNoteStopRecording),
                    label: const Text('Stop'),
                  ),
                ],
                _Phase.recorded => [
                  OutlinedButton.icon(
                    onPressed: widget.enabled ? _togglePlay : null,
                    icon: Icon(
                      _playing
                          ? AppIcons.voiceNoteStopPlaying
                          : AppIcons.voiceNotePlay,
                    ),
                    label: Text(_playing ? 'Stop' : 'Play'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.enabled ? _start : null,
                    icon: const Icon(AppIcons.voiceNoteRecord),
                    label: const Text('Re-record'),
                  ),
                  TextButton.icon(
                    onPressed: widget.enabled ? _discard : null,
                    icon: const Icon(AppIcons.voiceNoteDiscard),
                    label: const Text('Discard'),
                  ),
                ],
              },
            ),
          ],
        ),
      ),
    );
  }
}
