import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/theme/app_theme.dart';

void main() {
  test('Plan TabBar labels use the centralized bold style in both themes', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      expect(theme.tabBarTheme.labelStyle!.fontWeight, FontWeight.w700);
      expect(
        theme.tabBarTheme.unselectedLabelStyle!.fontWeight,
        FontWeight.w700,
      );
      expect(theme.tabBarTheme.labelColor, theme.colorScheme.primary);
      expect(
        theme.tabBarTheme.unselectedLabelColor,
        theme.colorScheme.onSurfaceVariant,
      );
    }
  });
}
