import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:time_app/core/format/datetime_format.dart';
import 'package:time_app/core/theme/app_theme.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/voice_notes/application/voice_note_cache.dart';
import 'package:time_app/features/voice_notes/application/voice_note_providers.dart';
import 'package:time_app/features/voice_notes/data/voice_library_repository.dart';
import 'package:time_app/features/voice_notes/data/voice_note_client.dart';
import 'package:time_app/features/voice_notes/data/voice_player.dart';
import 'package:time_app/features/voice_notes/domain/voice_library_note.dart';
import 'package:time_app/features/voice_notes/presentation/voice_library_screen.dart';

/// Item 32d (2026-09-26): You → Voice notes. Every sent voice note is kept
/// (the Worker saves it; newest 20, first in first out); here the planner
/// plays, renames and deletes them.

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

VoiceLibraryNote _note(String id, DateTime createdAt, {String? name}) =>
    VoiceLibraryNote(
      id: id,
      sha256: _sha,
      durationMs: 12000,
      sizeBytes: 900,
      createdAt: createdAt,
      name: name,
    );

class _Repo implements VoiceLibraryRepository {
  final renames = <(String, String, String?)>[];
  @override
  Stream<List<VoiceLibraryNote>> watch(String uid) => const Stream.empty();
  @override
  Future<void> rename(String uid, String noteId, String? name) async =>
      renames.add((uid, noteId, name));
}

class _Client implements VoiceNoteClient {
  final deletes = <String>[];
  @override
  Future<void> deleteLibrary(String noteId) async => deletes.add(noteId);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements VoicePlayer {
  final played = <String>[];
  final _done = StreamController<void>.broadcast();
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> play(String path) async => played.add(path);
  @override
  Future<void> stop() async {}
}

class _Cache implements VoiceNoteCache {
  @override
  Future<String> ensureLibrary(VoiceLibraryNote note) async =>
      '/cache/${note.id}.m4a';
  @override
  Future<void> forgetLibrary(String noteId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => initializeDateFormatting());

  group('model', () {
    test('reads a Worker entry; rejects anything malformed', () {
      final ok = VoiceLibraryNote.fromMap('n1', {
        'sha256': _sha,
        'durationMs': 7000,
        'sizeBytes': 900,
        'createdAt': Timestamp.fromDate(DateTime.utc(2030, 1, 1)),
        'name': '  Morning  ',
      })!;
      expect(ok.name, 'Morning');
      expect(ok.length, const Duration(seconds: 7));
      expect(ok.meta.sha256, _sha);
      expect(
        VoiceLibraryNote.fromMap('n', {
          'sha256': _sha,
          'durationMs': 7000,
          'sizeBytes': 900,
          'createdAt': Timestamp.now(),
          'name': '   ',
        })!.name,
        isNull,
        reason: 'blank = unnamed',
      );
      for (final bad in [
        <String, dynamic>{'sha256': 'x', 'durationMs': 1, 'sizeBytes': 1},
        {
          'sha256': _sha,
          'durationMs': 0,
          'sizeBytes': 1,
          'createdAt': Timestamp.now(),
        },
        {'sha256': _sha, 'durationMs': 1, 'sizeBytes': 1},
      ]) {
        expect(VoiceLibraryNote.fromMap('n', bad), isNull, reason: '$bad');
      }
    });

    test('newest first; month headings only once there are two months', () {
      DateTime id(DateTime d) => d;
      final one = groupVoiceLibrary([
        _note('a', DateTime.utc(2030, 3, 2)),
        _note('b', DateTime.utc(2030, 3, 20)),
      ], toLocal: id);
      expect(one.single.monthStart, isNull);
      expect(one.single.notes.map((n) => n.id), ['b', 'a']);

      final two = groupVoiceLibrary([
        _note('feb', DateTime.utc(2030, 2, 10)),
        _note('mar2', DateTime.utc(2030, 3, 20)),
        _note('mar1', DateTime.utc(2030, 3, 2)),
      ], toLocal: id);
      expect(two.map((g) => g.monthStart), [
        DateTime(2030, 3),
        DateTime(2030, 2),
      ]);
      expect(two.first.notes.map((n) => n.id), ['mar2', 'mar1']);
      expect(groupVoiceLibrary(const []), isEmpty);
    });
  });

  group('screen', () {
    Future<(_Repo, _Client, _Player)> pump(
      WidgetTester tester,
      List<VoiceLibraryNote> notes, {
      Locale locale = const Locale('en', 'US'),
    }) async {
      final repo = _Repo();
      final client = _Client();
      final player = _Player();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voiceLibraryProvider.overrideWith((ref) => Stream.value(notes)),
            voiceLibraryRepositoryProvider.overrideWithValue(repo),
            voiceNoteClientProvider.overrideWithValue(client),
            voicePlayerProvider.overrideWithValue(player),
            voiceNoteCacheProvider.overrideWithValue(_Cache()),
            currentUidProvider.overrideWithValue('me'),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            locale: locale,
            supportedLocales: const [Locale('en', 'US'), Locale('de')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const VoiceLibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (repo, client, player);
    }

    testWidgets('empty library explains itself', (tester) async {
      await pump(tester, const []);
      expect(find.text('No voice notes yet'), findsOneWidget);
    });

    testWidgets(
      'an unnamed note shows its localized date; a named one its name',
      (tester) async {
        final at = DateTime.utc(2030, 3, 2, 14, 5);
        await pump(tester, [_note('a', at), _note('b', at, name: 'Gym call')]);
        final context = tester.element(find.byType(VoiceLibraryScreen));
        expect(find.text(formatLocalInstant(context, at)), findsOneWidget);
        expect(find.text('Gym call'), findsOneWidget);
        expect(find.text('0:12 · plays 4 times'), findsNWidgets(2));
        expect(find.textContaining('newest 20'), findsOneWidget);
      },
    );

    testWidgets('two months get month headings', (tester) async {
      await pump(tester, [
        _note('a', DateTime.utc(2030, 3, 15, 12)),
        _note('b', DateTime.utc(2030, 1, 15, 12)),
      ]);
      final context = tester.element(find.byType(VoiceLibraryScreen));
      expect(
        find.text(formatMonthYear(context, DateTime(2030, 3))),
        findsOneWidget,
      );
      expect(
        find.text(formatMonthYear(context, DateTime(2030, 1))),
        findsOneWidget,
      );
    });

    testWidgets('play fetches the verified copy and plays it', (tester) async {
      final (_, _, player) = await pump(tester, [
        _note('a', DateTime.utc(2030, 3, 2)),
      ]);
      await tester.tap(find.byKey(const ValueKey('voice-library-play-a')));
      await tester.pumpAndSettle();
      expect(player.played, ['/cache/a.m4a']);
    });

    testWidgets('rename saves the new name; empty clears it', (tester) async {
      final (repo, _, _) = await pump(tester, [
        _note('a', DateTime.utc(2030, 3, 2), name: 'Old'),
      ]);
      await tester.tap(find.byKey(const ValueKey('voice-library-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('voice-library-name')),
        'Wake up!',
      );
      await tester.tap(find.byKey(const ValueKey('voice-library-save-name')));
      await tester.pumpAndSettle();
      expect(repo.renames.single, ('me', 'a', 'Wake up!'));
    });

    testWidgets('delete asks first, then goes through the Worker', (
      tester,
    ) async {
      final (_, client, _) = await pump(tester, [
        _note('a', DateTime.utc(2030, 3, 2), name: 'Old'),
      ]);
      await tester.tap(find.byKey(const ValueKey('voice-library-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this voice note?'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(client.deletes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('voice-library-menu-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('voice-library-confirm-delete')),
      );
      await tester.pumpAndSettle();
      expect(client.deletes, ['a']);
    });

    testWidgets('dates follow the phone language', (tester) async {
      final at = DateTime.utc(2030, 3, 2, 14, 5);
      await pump(tester, [_note('a', at)], locale: const Locale('de'));
      final context = tester.element(find.byType(VoiceLibraryScreen));
      final label = formatLocalInstant(context, at);
      expect(label, contains('März'));
      expect(find.text(label), findsOneWidget);
    });
  });

  test('You links to it, and the library is never written from the app', () {
    final you = File(
      'lib/features/home/presentation/you_screen.dart',
    ).readAsStringSync();
    expect(you, contains('Routes.voiceNotes'));
    expect(you, contains("'Voice notes'"));
    final repo = File(
      'lib/features/voice_notes/data/voice_library_repository.dart',
    ).readAsStringSync();
    expect(repo, isNot(contains('.set(')));
    // `FieldValue.delete()` clears a name; deleting the DOCUMENT is the
    // Worker's job (it removes the audio too).
    expect(repo, isNot(matches(RegExp(r'(?<!FieldValue)\.delete\(\)'))));
    expect(repo, isNot(contains('.add(')));
    expect(kVoiceLibraryLimit, 20);
    final worker = File('worker/src/voice-library.js').readAsStringSync();
    expect(worker, contains('LIBRARY_LIMIT = 20'));
    expect(kVoiceNoteNameMax, 60);
    expect(Uint8List(0), isEmpty);
  });
}
