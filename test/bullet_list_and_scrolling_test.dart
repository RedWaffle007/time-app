import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_icons.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/core/widgets/bullet_list.dart';

void main() {
  testWidgets('BulletList gives wrapped text a hanging indent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: SizedBox(
            width: 180,
            child: BulletList(
              items: [
                Text(
                  'A deliberately long instruction that wraps onto another line.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(AppIcons.bullet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('onboarding uses the shared graphic bullet treatment', () {
    final source = File(
      'lib/features/onboarding/presentation/onboarding_screen.dart',
    ).readAsStringSync();
    expect(source, contains('BulletList('));
    expect(source, isNot(contains("Text('•")));
  });

  test(
    'collapsible date groups build rows lazily through sliver delegates',
    () {
      final source = File(
        'lib/core/widgets/collapsible_day_groups.dart',
      ).readAsStringSync();
      expect(source, contains('SliverChildBuilderDelegate'));
      expect(source, contains('SliverList('));
      expect(
        source,
        isNot(contains('ListView(\n      controller: widget.controller')),
      );
    },
  );
}
