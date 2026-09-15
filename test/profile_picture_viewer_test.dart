import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('viewer exposes an accessible image error state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const ProfilePictureViewer(imageUrl: 'not a network URL'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Profile picture could not be loaded'),
      findsOneWidget,
    );
  });
}
