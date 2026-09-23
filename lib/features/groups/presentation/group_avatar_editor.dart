import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../social/application/social_providers.dart';
import '../../social/data/avatar_uploader.dart';
import '../../social/data/worker_avatar_uploader.dart';
import '../../social/domain/avatar.dart';
import '../../social/presentation/avatar_selection.dart';
import '../application/group_providers.dart';
import '../domain/group.dart';
import 'group_avatar_image.dart';

class GroupAvatarEditor extends ConsumerStatefulWidget {
  const GroupAvatarEditor({
    super.key,
    required this.group,
    required this.editable,
  });

  final Group group;
  final bool editable;

  @override
  ConsumerState<GroupAvatarEditor> createState() => _GroupAvatarEditorState();
}

class _GroupAvatarEditorState extends ConsumerState<GroupAvatarEditor> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    return Column(
      children: [
        SizedBox(
          width: Sizes.avatarEditable,
          height: Sizes.avatarEditable,
          child: Stack(
            alignment: Alignment.center,
            children: [
              GroupAvatarImage(group: widget.group, size: Sizes.avatarEditable),
              if (_busy) const CircularProgressIndicator(),
            ],
          ),
        ),
        if (widget.editable) ...[
          const SizedBox(height: Space.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickAndUpload,
                icon: const Icon(AppIcons.editPhoto),
                label: Text(
                  widget.group.avatar == null ? 'Add photo' : 'Change',
                ),
              ),
              if (widget.group.avatar != null) ...[
                const SizedBox(width: Space.sm),
                TextButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(AppIcons.removePhoto),
                  label: const Text('Remove'),
                ),
              ],
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            kAvatarFormatHelperText,
            textAlign: TextAlign.center,
            style: context.text.labelSmall?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }

  Future<void> _pickAndUpload() async {
    final AvatarSelection? selection;
    try {
      selection = await pickAvatarSelection();
    } catch (_) {
      if (mounted) _toast('Could not open the picture picker.');
      return;
    }
    if (selection == null) return;

    final rejection = checkAvatarUpload(
      mime: selection.mime,
      bytes: selection.bytes.length,
    );
    if (rejection != AvatarRejection.none) {
      _toast(describeAvatarRejection(rejection, selection.mime));
      return;
    }

    setState(() => _busy = true);
    try {
      final avatar = await ref
          .read(avatarUploaderProvider)
          .uploadGroup(
            groupId: widget.group.id,
            bytes: selection.bytes,
            mime: selection.mime,
            previousKey: widget.group.avatar?.storageKey,
          );
      await ref
          .read(groupRepositoryProvider)
          .setAvatar(groupId: widget.group.id, avatar: avatar);
      ref.invalidate(myGroupsProvider);
    } on AvatarUploadFailure catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('Could not upload the group picture. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final key = widget.group.avatar?.storageKey;
    setState(() => _busy = true);
    try {
      await ref.read(groupRepositoryProvider).clearAvatar(widget.group.id);
      ref.invalidate(myGroupsProvider);
      if (key != null && key.isNotEmpty) {
        await ref
            .read(avatarUploaderProvider)
            .removeGroup(groupId: widget.group.id, storageKey: key);
      }
    } catch (_) {
      if (mounted) _toast('Could not remove the group picture. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
