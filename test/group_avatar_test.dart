import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/groups/application/group_providers.dart';
import 'package:time_app/features/groups/data/group_repository.dart';
import 'package:time_app/features/groups/domain/group.dart';
import 'package:time_app/features/groups/presentation/group_avatar_editor.dart';
import 'package:time_app/features/groups/presentation/group_avatar_image.dart';
import 'package:time_app/features/groups/presentation/groups_screen.dart';
import 'package:time_app/features/social/domain/avatar.dart';
import 'package:time_app/features/social/application/social_providers.dart';
import 'package:time_app/features/social/data/avatar_uploader.dart';
import 'package:time_app/features/social/presentation/profile_picture_viewer.dart';

void main() {
  const base = Group(
    id: 'group-1',
    name: 'Readers',
    ownerUid: 'owner',
    joinCode: 'READ42',
    memberUids: ['owner'],
  );

  Widget host(Group group) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Center(child: GroupAvatarImage(group: group)),
    ),
  );

  testWidgets('legacy group without a picture retains its initial fallback', (
    tester,
  ) async {
    await tester.pumpWidget(host(base));

    expect(find.text('R'), findsOneWidget);
    expect(find.bySemanticsLabel('Open group picture'), findsNothing);
  });

  testWidgets('displayable animated group picture opens the shared viewer', (
    tester,
  ) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'owner',
      joinCode: 'READ42',
      memberUids: ['owner'],
      avatar: ProfileAvatar(
        url: 'https://example.test/group.webp',
        storageKey: 'group-avatars/group-1/group.webp',
        mime: 'image/webp',
        sizeBytes: 100,
      ),
    );
    await tester.pumpWidget(host(group));

    await tester.tap(find.bySemanticsLabel('Open group picture'));
    await tester.pump();

    expect(find.byType(ProfilePictureViewer), findsOneWidget);
    expect(find.byTooltip('Close group picture'), findsOneWidget);
  });

  testWidgets('rejected group picture falls back and cannot open', (
    tester,
  ) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'owner',
      joinCode: 'READ42',
      memberUids: ['owner'],
      avatar: ProfileAvatar(
        url: 'https://example.test/rejected.png',
        storageKey: 'group-avatars/group-1/rejected.png',
        mime: 'image/png',
        sizeBytes: 100,
        moderation: AvatarModeration.rejected,
      ),
    );
    await tester.pumpWidget(host(group));

    expect(find.text('R'), findsOneWidget);
    expect(find.bySemanticsLabel('Open group picture'), findsNothing);
  });

  testWidgets('broken group picture URL falls back to the group initial', (
    tester,
  ) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'owner',
      joinCode: 'READ42',
      memberUids: ['owner'],
      avatar: ProfileAvatar(
        url: 'not a network URL',
        storageKey: 'group-avatars/group-1/broken.png',
        mime: 'image/png',
        sizeBytes: 100,
      ),
    );
    await tester.pumpWidget(host(group));
    await tester.pumpAndSettle();

    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('group list renders the stored group picture', (tester) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'owner',
      joinCode: 'READ42',
      memberUids: ['owner'],
      avatar: ProfileAvatar(
        url: 'https://example.test/group.gif',
        storageKey: 'group-avatars/group-1/group.gif',
        mime: 'image/gif',
        sizeBytes: 100,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myGroupsProvider.overrideWithValue(const AsyncData([group])),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const GroupsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GroupAvatarImage), findsOneWidget);
    await tester.tap(find.byType(GroupAvatarImage));
    await tester.pump();
    expect(find.byType(ProfilePictureViewer), findsOneWidget);
  });

  testWidgets('non-owner group detail cannot edit the picture', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: GroupAvatarEditor(group: base, editable: false)),
        ),
      ),
    );

    expect(find.text('Add photo'), findsNothing);
    expect(find.text('Change'), findsNothing);
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('owner removal clears metadata and requests object deletion', (
    tester,
  ) async {
    const group = Group(
      id: 'group-1',
      name: 'Readers',
      ownerUid: 'owner',
      joinCode: 'READ42',
      memberUids: ['owner'],
      avatar: ProfileAvatar(
        url: 'https://example.test/group.png',
        storageKey: 'group-avatars/group-1/group.png',
        mime: 'image/png',
        sizeBytes: 100,
      ),
    );
    final groups = _RecordingGroupRepository();
    final uploader = _RecordingAvatarUploader();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupRepositoryProvider.overrideWithValue(groups),
          avatarUploaderProvider.overrideWithValue(uploader),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: GroupAvatarEditor(group: group, editable: true),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(groups.cleared, ['group-1']);
    expect(uploader.removed, [('group-1', 'group-avatars/group-1/group.png')]);
  });
}

class _RecordingGroupRepository implements GroupRepository {
  final cleared = <String>[];

  @override
  Future<void> clearAvatar(String groupId) async => cleared.add(groupId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingAvatarUploader implements AvatarUploader {
  final removed = <(String, String)>[];

  @override
  Future<void> removeGroup({
    required String groupId,
    required String storageKey,
  }) async => removed.add((groupId, storageKey));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
