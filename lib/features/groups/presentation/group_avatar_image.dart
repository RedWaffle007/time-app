import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../social/presentation/avatar_image.dart';
import '../domain/group.dart';

/// A group's picture with the same shape, fallbacks, animation, and viewer as
/// profile pictures.
class GroupAvatarImage extends StatelessWidget {
  const GroupAvatarImage({
    super.key,
    required this.group,
    this.size = Sizes.avatarRow,
  });

  final Group group;
  final double size;

  @override
  Widget build(BuildContext context) => DisplayAvatarImage(
    displayName: group.name,
    imageUrl: group.displayAvatarUrl,
    size: size,
    openSemanticsLabel: 'Open group picture',
    viewerDescription: 'Group picture',
  );
}
