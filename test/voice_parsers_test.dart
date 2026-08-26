import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/voice/application/voice_parsers.dart';

void main() {
  group('parseTrackUtterance', () {
    test('task + digit minutes', () {
      final d = parseTrackUtterance('walking 30 mins');
      expect(d.taskName, 'walking');
      expect(d.minutes, 30);
    });

    test('multi-word task, spelled unit', () {
      final d = parseTrackUtterance('German practice 45 minutes');
      expect(d.taskName, 'German practice'); // casing preserved
      expect(d.minutes, 45);
    });

    test('hours convert to minutes', () {
      final d = parseTrackUtterance('deep work 2 hours');
      expect(d.taskName, 'deep work');
      expect(d.minutes, 120);
    });

    test('decimal hours', () {
      final d = parseTrackUtterance('reading 1.5 hours');
      expect(d.minutes, 90);
    });

    test('fused number+unit', () {
      final d = parseTrackUtterance('run 20min');
      expect(d.taskName, 'run');
      expect(d.minutes, 20);
    });

    test('"an hour" is 60, not 1', () {
      final d = parseTrackUtterance('gym an hour');
      expect(d.taskName, 'gym');
      expect(d.minutes, 60);
    });

    test('"half an hour" is 30, not 90', () {
      final d = parseTrackUtterance('walk half an hour');
      expect(d.taskName, 'walk');
      expect(d.minutes, 30);
    });

    test('"an hour and a half" is 90', () {
      final d = parseTrackUtterance('coding an hour and a half');
      expect(d.taskName, 'coding');
      expect(d.minutes, 90);
    });

    test('spelled minutes', () {
      final d = parseTrackUtterance('stretching thirty minutes');
      expect(d.taskName, 'stretching');
      expect(d.minutes, 30);
    });

    test('compound spelled minutes', () {
      final d = parseTrackUtterance('call twenty five minutes');
      expect(d.taskName, 'call');
      expect(d.minutes, 25);
    });

    test('no unit → whole thing is the task, minutes null', () {
      final d = parseTrackUtterance('route 66');
      expect(d.taskName, 'route 66');
      expect(d.minutes, isNull);
    });

    test('empty utterance', () {
      final d = parseTrackUtterance('   ');
      expect(d.taskName, '');
      expect(d.minutes, isNull);
    });

    test('duration only, no task', () {
      final d = parseTrackUtterance('45 minutes');
      expect(d.taskName, '');
      expect(d.minutes, 45);
    });
  });

  group('parsePlanUtterance', () {
    // A fixed Wednesday for deterministic weekday math.
    final wed = DateTime(2026, 8, 26); // 2026-08-26 is a Wednesday

    test('fixture date really is a Wednesday', () {
      expect(wed.weekday, DateTime.wednesday);
    });

    test('weekday + am time + title', () {
      final d = parsePlanUtterance('Monday 7am gym', now: wed);
      expect(d.title, 'gym');
      expect(d.time, const TimeOfDay(hour: 7, minute: 0));
      // Next Monday from Wednesday = +5 days.
      expect(d.date, DateTime(2026, 8, 31));
    });

    test('tomorrow + pm time', () {
      final d = parsePlanUtterance('tomorrow 3 pm dentist', now: wed);
      expect(d.title, 'dentist');
      expect(d.time, const TimeOfDay(hour: 15, minute: 0));
      expect(d.date, DateTime(2026, 8, 27));
    });

    test('today + colon 24h time', () {
      final d = parsePlanUtterance('today 19:30 dinner', now: wed);
      expect(d.title, 'dinner');
      expect(d.time, const TimeOfDay(hour: 19, minute: 30));
      expect(d.date, DateTime(2026, 8, 26));
    });

    test('half past seven', () {
      final d = parsePlanUtterance('Friday half past seven standup', now: wed);
      expect(d.title, 'standup');
      expect(d.time, const TimeOfDay(hour: 7, minute: 30));
    });

    test('quarter to eight', () {
      final d = parsePlanUtterance('quarter to eight breakfast', now: wed);
      expect(d.time, const TimeOfDay(hour: 7, minute: 45));
    });

    test('seven thirty (bare, no meridian) with trailing pm', () {
      final d = parsePlanUtterance('meeting 7:30pm', now: wed);
      expect(d.title, 'meeting');
      expect(d.time, const TimeOfDay(hour: 19, minute: 30));
    });

    test('noon', () {
      final d = parsePlanUtterance('today noon lunch', now: wed);
      expect(d.time, const TimeOfDay(hour: 12, minute: 0));
    });

    test('leading filler stripped from title', () {
      final d = parsePlanUtterance('tomorrow 9am set an alarm for standup',
          now: wed);
      expect(d.title, 'standup');
    });

    test('interior article kept in title', () {
      final d = parsePlanUtterance('tomorrow 6pm clean the kitchen', now: wed);
      expect(d.title, 'clean the kitchen');
    });

    test('no day → date null, still parses time and title', () {
      final d = parsePlanUtterance('8am medication', now: wed);
      expect(d.date, isNull);
      expect(d.time, const TimeOfDay(hour: 8, minute: 0));
      expect(d.title, 'medication');
    });

    test('no time → time null', () {
      final d = parsePlanUtterance('Monday gym', now: wed);
      expect(d.time, isNull);
      expect(d.title, 'gym');
    });

    test('bare weekday equal to today resolves to today', () {
      final d = parsePlanUtterance('Wednesday 10am review', now: wed);
      expect(d.date, DateTime(2026, 8, 26));
    });

    test('same-weekday with an already-past time rolls to next week', () {
      // Wednesday 2pm; "Wednesday 10am" this week is behind us, so the next
      // occurrence is a week out — never a past instant.
      final wedAfternoon = DateTime(2026, 8, 26, 14, 0);
      final d = parsePlanUtterance('Wednesday 10am review', now: wedAfternoon);
      expect(d.date, DateTime(2026, 9, 2));
      expect(d.time, const TimeOfDay(hour: 10, minute: 0));
    });

    test('same-weekday with a still-future time stays today', () {
      final wedMorning = DateTime(2026, 8, 26, 8, 0);
      final d = parsePlanUtterance('Wednesday 10am review', now: wedMorning);
      expect(d.date, DateTime(2026, 8, 26));
    });

    test('spoken "a.m." is a meridian, not title text', () {
      final d = parsePlanUtterance('Wednesday 8 a.m. gym', now: wed);
      expect(d.time, const TimeOfDay(hour: 8, minute: 0));
      expect(d.title, 'gym');
    });

    test('spoken "p.m." variant', () {
      final d = parsePlanUtterance('meeting 7 p.m.', now: wed);
      expect(d.time, const TimeOfDay(hour: 19, minute: 0));
      expect(d.title, 'meeting');
    });

    test('empty utterance', () {
      final d = parsePlanUtterance('', now: wed);
      expect(d.title, '');
      expect(d.date, isNull);
      expect(d.time, isNull);
    });

    test('calendar date "30 aug" parses day + time + title', () {
      final d = parsePlanUtterance('30 aug 9pm study', now: wed);
      expect(d.date, DateTime(2026, 8, 30));
      expect(d.time, const TimeOfDay(hour: 21, minute: 0));
      expect(d.title, 'study');
    });

    test('calendar date month-first with ordinal "august 30th"', () {
      final d = parsePlanUtterance('august 30th gym', now: wed);
      expect(d.date, DateTime(2026, 8, 30));
      expect(d.title, 'gym');
    });

    test('a calendar date already past this year rolls to next year', () {
      final d = parsePlanUtterance('5 jan 7am medication', now: wed);
      expect(d.date, DateTime(2027, 1, 5));
    });

    test('explicit year is honoured', () {
      final d = parsePlanUtterance('30 august 2028 study', now: wed);
      expect(d.date, DateTime(2028, 8, 30));
    });

    test('impossible calendar date is rejected (no roll-over)', () {
      final d = parsePlanUtterance('30 feb workout', now: wed);
      expect(d.date, isNull);
    });
  });
}
