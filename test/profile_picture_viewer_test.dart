import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_colors.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/social/domain/avatar.dart';
import 'package:time_app/features/social/presentation/avatar_image.dart';
import 'package:time_app/features/social/presentation/profile_picture_viewer.dart';

void main() {
  Widget host(UserProfile profile) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(child: AvatarImage(profile: profile)),
    ),
  );

  testWidgets(
    'a stored displayable avatar opens and closes the shared viewer',
    (tester) async {
      final profile = UserProfile(
        uid: 'u',
        name: 'Ari',
        homeTimezone: 'Asia/Kolkata',
        avatar: const ProfileAvatar(
          url: 'https://example.test/avatar.webp',
          storageKey: 'avatars/u/avatar.webp',
          mime: 'image/webp',
          sizeBytes: 1,
        ),
      );
      await tester.pumpWidget(host(profile));

      expect(find.bySemanticsLabel('Open profile picture'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Open profile picture'));
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('Close profile picture'), findsOneWidget);

      await tester.tap(find.byTooltip('Close profile picture'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    },
  );

  testWidgets('an initials placeholder never opens an empty viewer', (
    tester,
  ) async {
    const profile = UserProfile(
      uid: 'u',
      name: 'Ari',
      homeTimezone: 'Asia/Kolkata',
    );
    await tester.pumpWidget(host(profile));
    expect(find.bySemanticsLabel('Open profile picture'), findsNothing);
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    testWidgets('$name viewer controls remain visible over its scrim', (
      tester,
    ) async {
      final semantic = theme.extension<AppSemanticColors>()!;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(child: ProfilePictureViewerLoading()),
          ),
        ),
      );

      final loading = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(loading.color, semantic.immersiveForeground);

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const ProfilePictureViewer(imageUrl: 'not a network URL'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Profile picture could not be loaded'),
        findsOneWidget,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.error_outline)).color,
        semantic.immersiveForeground,
      );
      final close = tester.widget<IconButton>(find.byType(IconButton));
      expect(
        close.style!.backgroundColor!.resolve({}),
        semantic.immersiveControlBackground,
      );
      expect(
        close.style!.foregroundColor!.resolve({}),
        semantic.immersiveForeground,
      );
    });
  }
}
