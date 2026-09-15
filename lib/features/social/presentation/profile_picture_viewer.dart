import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';

/// Opens the one immersive viewer used by every displayable profile picture.
///
/// It accepts only a URL already approved by [UserProfile.displayAvatarUrl].
/// Callers therefore cannot accidentally open a withheld/rejected upload or an
/// initials placeholder. The original network image is intentionally used with
/// no decode-size hints so animated GIF/WebP files retain their playback.
Future<void> showProfilePictureViewer(BuildContext context, String imageUrl) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => ProfilePictureViewer(imageUrl: imageUrl),
  );
}

/// Full-screen content used by [showProfilePictureViewer]. Public so the
/// loading/error affordances can be embedded and regression-tested directly.
class ProfilePictureViewer extends StatelessWidget {
  const ProfilePictureViewer({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final cs = context.colors;
    final foreground = context.immersiveForeground;
    final controlBackground = context.immersiveControlBackground;
    return PopScope(
      canPop: true,
      child: Material(
        color: cs.scrim,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return const ProfilePictureViewerLoading();
                    },
                    errorBuilder: (context, error, stackTrace) =>
                        const ProfilePictureViewerError(),
                  ),
                ),
              ),
              Positioned(
                top: Space.sm,
                right: Space.sm,
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: controlBackground,
                    foregroundColor: foreground,
                  ),
                  tooltip: 'Close profile picture',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading affordance for an image fetched into the immersive viewer.
class ProfilePictureViewerLoading extends StatelessWidget {
  const ProfilePictureViewerLoading({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: Sizes.emptyStateIcon,
    height: Sizes.emptyStateIcon,
    child: CircularProgressIndicator(color: context.immersiveForeground),
  );
}

/// Accessible failure affordance for an image that could not be fetched.
class ProfilePictureViewerError extends StatelessWidget {
  const ProfilePictureViewerError({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Profile picture could not be loaded',
    child: Icon(
      AppIcons.error,
      size: Sizes.emptyStateIcon,
      color: context.immersiveForeground,
    ),
  );
}
