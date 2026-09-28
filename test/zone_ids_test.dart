import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/core/format/zone_ids.dart';
import 'package:time_app/features/auth/presentation/timezone_picker.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Device report 2026-09-28: some phones showed "Asia/Calcutta", others
/// "Asia/Kolkata". DECISIONS.md "One name per timezone".
void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('old names read as the current one', () {
    expect(canonicalZone('Asia/Calcutta'), 'Asia/Kolkata');
    expect(canonicalZone('Asia/Kolkata'), 'Asia/Kolkata');
    expect(canonicalZone('Europe/Kiev'), 'Europe/Kyiv');
    expect(canonicalZone('US/Eastern'), 'America/New_York');
    expect(canonicalZone('Asia/Saigon'), 'Asia/Ho_Chi_Minh');
    expect(canonicalZone('UTC'), 'Etc/UTC');
    // A current name in its own right is never folded into another city.
    expect(canonicalZone('Europe/Oslo'), 'Europe/Oslo');
    expect(canonicalZone('Asia/Karachi'), 'Asia/Karachi');
  });

  test('the picker lists each zone once, by its current name', () {
    expect(kPickerZones.toSet(), hasLength(kPickerZones.length));
    for (final zone in kPickerZones) {
      expect(kZoneAliases.containsKey(zone), isFalse, reason: zone);
    }
    expect(kPickerZones, contains('Asia/Kolkata'));
    expect(kPickerZones, isNot(contains('Asia/Calcutta')));
  });

  test('every alias resolves in the bundled tz data', () {
    for (final entry in kZoneAliases.entries) {
      final zone = canonicalZone(entry.key);
      expect(() => tz.getLocation(zone), returnsNormally, reason: entry.key);
    }
  });

  testWidgets('the picker shows Kolkata, never Calcutta', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TimezonePicker()));
    await tester.enterText(find.byType(TextField), 'kol');
    await tester.pump();
    expect(find.text('Asia/Kolkata'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'calc');
    await tester.pump();
    expect(find.text('Asia/Calcutta'), findsNothing);
  });
}
