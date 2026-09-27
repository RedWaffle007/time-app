import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/social/data/avatar_uploader.dart';

/// 2026-09-27: on a dead connection the picture spinner ran forever (the
/// Firestore write after the upload never completes offline, and the token
/// fetch had no limit). Every network step is now bounded.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the upload and its sign-in token are time-limited', () {
    final uploader = read(
      'lib/features/social/data/worker_avatar_uploader.dart',
    );
    expect(uploader, contains('_timeout = Duration(seconds: 30)'));
    expect(uploader, contains('getIdToken().timeout(_tokenTimeout)'));
    expect(uploader, contains('on TimeoutException'));
    // No raw exception text in front of the user.
    expect(uploader, isNot(contains("server. \$e")));
  });

  test('the profile and group picture saves stop waiting and say why', () {
    expect(kAvatarSaveTimeout, const Duration(seconds: 15));
    expect(kAvatarSavePendingMessage, contains('back online'));
    for (final path in [
      'lib/features/social/presentation/profile_avatar_editor.dart',
      'lib/features/groups/presentation/group_avatar_editor.dart',
    ]) {
      final source = read(path);
      expect(source, contains('.timeout(kAvatarSaveTimeout)'), reason: path);
      expect(source, contains('kAvatarSavePendingMessage'), reason: path);
    }
  });

  test('my own picture is pre-loaded before the You tab opens', () {
    final shell = read('lib/features/home/presentation/home_shell.dart');
    expect(shell, contains('precacheImage('));
    expect(shell, contains('displayAvatarUrl'));
  });
}
