import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/groups/domain/group.dart';
import 'package:time_app/features/groups/presentation/group_avatar_editor.dart';
import 'package:time_app/features/social/domain/avatar.dart';
import 'package:time_app/features/social/presentation/profile_avatar_editor.dart';

void main() {
  testWidgets('profile upload helper lists exactly the accepted formats', (
    tester,
  ) async {
    const profile = UserProfile(uid: 'me', name: 'Me', homeTimezone: 'Etc/UTC');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) => Stream.value(profile)),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: ProfileAvatarEditor()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(kAvatarFormatHelperText), findsOneWidget);
  });

  testWidgets('group upload helper uses the same accepted-format copy', (
    tester,
  ) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'me',
      joinCode: 'READ42',
      memberUids: ['me'],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: GroupAvatarEditor(group: group, editable: true),
          ),
        ),
      ),
    );

    expect(find.text(kAvatarFormatHelperText), findsOneWidget);
  });
}
