import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Device report 2026-09-28: the You tab took about a second to load on every
/// visit. Everything it reads is now listened from app start in the shell.
void main() {
  test('the shell keeps the You tab\'s data warm from app start', () {
    final shell = File(
      'lib/features/home/presentation/home_shell.dart',
    ).readAsStringSync();
    for (final provider in [
      'ref.listen(profileByUidProvider(me)',
      'ref.listen(profileStatsProvider(me)',
      'ref.listen(myFriendCountProvider',
      'precacheImage(',
    ]) {
      expect(shell, contains(provider), reason: provider);
    }
  });

  test('the You tab reads exactly those providers', () {
    final body = File(
      'lib/features/social/presentation/user_profile_screen.dart',
    ).readAsStringSync();
    expect(body, contains('ref.watch(profileByUidProvider(uid))'));
    final stats = File(
      'lib/features/social/presentation/stats_section.dart',
    ).readAsStringSync();
    expect(stats, contains('ref.watch(profileStatsProvider(uid))'));
  });
}
