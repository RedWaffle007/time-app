import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/application/stats_providers.dart';
import 'package:time_app/features/social/domain/avatar.dart';
import 'package:time_app/features/social/domain/friendship.dart';
import 'package:time_app/features/social/domain/profile_visibility.dart';
import 'package:time_app/features/social/presentation/avatar_image.dart';
import 'package:time_app/features/social/presentation/friends_screen.dart';
import 'package:time_app/features/social/presentation/profile_picture_viewer.dart';
import 'package:time_app/features/social/presentation/user_profile_screen.dart';

void main() {
  const avatar = ProfileAvatar(
    url: 'https://example.test/animated.gif',
    storageKey: 'avatars/friend/animated.gif',
    mime: 'image/gif',
    sizeBytes: 100,
  );
  const profile = UserProfile(
    uid: 'friend',
    name: 'Amina',
    homeTimezone: 'Etc/UTC',
    username: 'amina',
    avatar: avatar,
  );

  testWidgets('friend-list picture opens the viewer instead of the profile', (
    tester,
  ) async {
    const friendship = Friendship(id: 'friend_me', uidA: 'friend', uidB: 'me');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('me'),
          myFriendshipsProvider.overrideWithValue(
            const AsyncData([friendship]),
          ),
          incomingRequestCountProvider.overrideWithValue(0),
          profileByUidProvider(
            'friend',
          ).overrideWith((ref) => Stream.value(profile)),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const FriendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AvatarImage), findsOneWidget);
    await tester.tap(find.byType(AvatarImage));
    await tester.pumpAndSettle();

    expect(find.byType(ProfilePictureViewer), findsOneWidget);
    expect(find.text('Profile'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile header picture opens the shared viewer', (tester) async {
    final visibility = visibilityFor(
      relation: ProfileRelation.self,
      isPublic: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUidProvider.overrideWithValue('friend'),
          profileByUidProvider(
            'friend',
          ).overrideWith((ref) => Stream.value(profile)),
          profileVisibilityProvider(
            'friend',
          ).overrideWithValue(AsyncData(visibility)),
          friendCountForProvider('friend').overrideWithValue(0),
          profileStatsProvider('friend').overrideWithValue(const AsyncData([])),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const UserProfileScreen(uid: 'friend'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AvatarImage), findsOneWidget);
    await tester.tap(find.byType(AvatarImage));
    await tester.pump();

    expect(find.byType(ProfilePictureViewer), findsOneWidget);
  });
}
