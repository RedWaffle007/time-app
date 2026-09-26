import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/voice_note_providers.dart';
import '../domain/voice_library_note.dart';
import 'voice_library_screen.dart';
import 'voice_note_recorder.dart';

/// "Choose from library" in the builder (32d): pick one of your saved voice
/// notes, newest first. Returns null if dismissed.
Future<VoiceLibraryNote?> showVoiceLibraryPicker(BuildContext context) {
  return showModalBottomSheet<VoiceLibraryNote>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _Picker(),
  );
}

class _Picker extends ConsumerWidget {
  const _Picker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(voiceLibraryProvider).value ?? const [];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              MediaQuery.sizeOf(context).height * Sizes.modalMaxHeightFraction,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          children: [
            Text('Choose a voice note', style: context.text.titleMedium),
            const SizedBox(height: Space.sm),
            if (notes.isEmpty)
              Text(
                'Voice notes you send are saved here to reuse.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            for (final note in notes)
              Card(
                child: ListTile(
                  key: ValueKey('voice-library-pick-${note.id}'),
                  leading: const Icon(AppIcons.voiceNote),
                  title: Text(
                    voiceNoteLabel(context, note),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${formatVoiceLength(note.length)} · '
                    'plays ${voicePlaysFor(note.length)} times',
                  ),
                  onTap: () => Navigator.pop(context, note),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
