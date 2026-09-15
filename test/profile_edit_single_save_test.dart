import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/auth/domain/user_profile.dart';
import 'package:time_app/features/auth/presentation/profile_edit_screen.dart';

/// Guards the unified-Save merge: the Edit Profile screen must expose exactly
/// ONE draft Save ("Save changes"), never the old second "Save profile" button,
/// and the full username rule must be shown rather than clipped to one line.
void main() {
  const profile = UserProfile(
    uid: 'uid',
    name: 'Profile name',
    homeTimezone: 'UTC',
    username: 'profile_name',
  );

  testWidgets('one Save button, no second "Save profile"', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) => Stream.value(profile)),
          appLockInitiallyEnabledProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProfileEditScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    expect(find.text('Save profile'), findsNothing);
  });

  testWidgets('username rule is shown in full, not clipped', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileProvider.overrideWith((ref) => Stream.value(profile)),
          appLockInitiallyEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const ProfileEditScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The tail of the helper is only visible if it is allowed more than one
    // ellipsised line (helperMaxLines).
    final helper = tester.widget<Text>(
      find.textContaining('starting with a letter'),
    );
    expect(helper.maxLines, isNot(1));
  });
}
