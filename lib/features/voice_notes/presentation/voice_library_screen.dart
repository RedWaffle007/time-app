import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../auth/application/auth_providers.dart';
import '../application/voice_note_cache.dart';
import '../application/voice_note_providers.dart';
import '../data/voice_note_client.dart';
import '../domain/voice_library_note.dart';
import 'voice_note_recorder.dart';

/// What a library note is called: its own name, else when it was recorded, in
/// the phone's language and clock (32d).
String voiceNoteLabel(BuildContext context, VoiceLibraryNote note) =>
    note.name ?? formatLocalInstant(context, note.createdAt);

/// You → Voice notes (item 32d): every voice note you have sent, newest
/// first, grouped by month once there are two months. Play, rename, delete.
class VoiceLibraryScreen extends ConsumerWidget {
  const VoiceLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(voiceLibraryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Voice notes')),
      body: AsyncView<List<VoiceLibraryNote>>(
        value: library,
        onRetry: () => ref.invalidate(voiceLibraryProvider),
        builder: (context, notes) {
          if (notes.isEmpty) return const _Empty();
          final groups = groupVoiceLibrary(notes);
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              Text(
                'Every voice note you send is kept here — the newest '
                '$kVoiceLibraryLimit. Reuse one from the Plan screen.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              for (final group in groups) ...[
                if (group.monthStart != null)
                  SectionHeader(formatMonthYear(context, group.monthStart!)),
                if (group.monthStart == null) const SizedBox(height: Space.md),
                for (final note in group.notes) VoiceLibraryTile(note: note),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Mirrors the Worker's `LIBRARY_LIMIT`.
const kVoiceLibraryLimit = 20;

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.voiceLibrary,
              size: Sizes.emptyStateIcon,
              color: context.colors.primary,
            ),
            const SizedBox(height: Space.md),
            Text('No voice notes yet', style: context.text.titleMedium),
            const SizedBox(height: Space.xs),
            Text(
              'Voice notes you send with an alarm are saved here to reuse.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One saved note: its name (or date), length, and Play / Rename / Delete.
class VoiceLibraryTile extends ConsumerStatefulWidget {
  const VoiceLibraryTile({super.key, required this.note});

  final VoiceLibraryNote note;

  @override
  ConsumerState<VoiceLibraryTile> createState() => _VoiceLibraryTileState();
}

class _VoiceLibraryTileState extends ConsumerState<VoiceLibraryTile> {
  bool _playing = false;
  bool _busy = false;
  StreamSubscription<void>? _done;

  @override
  void dispose() {
    _done?.cancel();
    super.dispose();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _togglePlay() async {
    final player = ref.read(voicePlayerProvider);
    if (_playing) {
      await player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _busy = true);
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
      _say(e.message);
    } catch (_) {
      _say(voiceNoteErrorMessage(null));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: widget.note.name ?? ''),
    );
    if (name == null) return;
    try {
      await ref
          .read(voiceLibraryRepositoryProvider)
          .rename(uid, widget.note.id, name);
    } catch (_) {
      _say("Couldn't rename it. Check your connection and try again.");
    }
  }

  Future<void> _delete() async {
    final label = voiceNoteLabel(context, widget.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this voice note?'),
        content: Text(
          '"$label" leaves your library. Alarms already sent with it still '
          'play it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const ValueKey('voice-library-confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_playing) await ref.read(voicePlayerProvider).stop();
    setState(() => _busy = true);
    try {
      await ref.read(voiceNoteClientProvider).deleteLibrary(widget.note.id);
      await ref.read(voiceNoteCacheProvider).forgetLibrary(widget.note.id);
    } on VoiceNoteFailure catch (e) {
      _say(e.message);
    } catch (_) {
      _say("Couldn't delete it. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return Card(
      key: ValueKey('voice-library-${note.id}'),
      child: ListTile(
        leading: IconButton(
          key: ValueKey('voice-library-play-${note.id}'),
          tooltip: _playing ? 'Stop' : 'Play',
          onPressed: _busy ? null : _togglePlay,
          icon: Icon(
            _playing ? AppIcons.voiceNoteStopPlaying : AppIcons.voiceNotePlay,
          ),
        ),
        title: Text(
          voiceNoteLabel(context, note),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${formatVoiceLength(note.length)} · '
          'plays ${voicePlaysFor(note.length)} times',
        ),
        trailing: PopupMenuButton<String>(
          key: ValueKey('voice-library-menu-${note.id}'),
          enabled: !_busy,
          onSelected: (action) => action == 'rename' ? _rename() : _delete(),
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'rename',
              child: ListTile(
                leading: Icon(AppIcons.edit),
                title: Text('Rename'),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(AppIcons.delete),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename voice note'),
      content: TextField(
        key: const ValueKey('voice-library-name'),
        controller: _controller,
        autofocus: true,
        maxLength: kVoiceNoteNameMax,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Leave empty to show its date',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('voice-library-save-name'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
