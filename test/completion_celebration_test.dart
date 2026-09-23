import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/applock/application/app_lock_controller.dart';
import 'package:time_app/features/applock/application/app_lock_providers.dart';
import 'package:time_app/features/applock/data/app_lock_store.dart';
import 'package:time_app/features/applock/data/device_auth.dart';
import 'package:time_app/features/applock/data/secure_window.dart';
import 'package:time_app/features/auth/application/auth_providers.dart';
import 'package:time_app/features/celebrations/application/celebration_providers.dart';
import 'package:time_app/features/celebrations/application/celebration_queue.dart';
import 'package:time_app/features/celebrations/data/completion_celebration_repository.dart';
import 'package:time_app/features/celebrations/domain/completion_celebration.dart';
import 'package:time_app/features/celebrations/presentation/completion_celebration_host.dart';

CompletionCelebration event(String id) => CompletionCelebration(
  id: id,
  itemId: 'item-$id',
  targetUid: 'target',
  plannerUid: 'planner',
  participantUids: const ['target', 'planner'],
  seenByUids: const [],
);

void main() {
  test('visual contract is exactly 1.5 seconds', () {
    expect(completionCelebrationDuration, const Duration(milliseconds: 1500));
  });

  test('an event is queued only once across repeated live snapshots', () {
    final queue = CompletionCelebrationQueue();
    final completion = event('one');

    queue.addAll([completion]);
    queue.addAll([completion]);
    expect(queue.takeNext()?.id, 'one');
    queue.complete('one');
    expect(queue.takeNext(), isNull);
  });

  test('events retain arrival order while another celebration is active', () {
    final queue = CompletionCelebrationQueue();
    queue.addAll([event('one'), event('two')]);

    expect(queue.takeNext()?.id, 'one');
    queue.complete('one');
    expect(queue.takeNext()?.id, 'two');
  });

  test('only unseen participants are eligible for display', () {
    final completion = CompletionCelebration(
      id: 'one',
      itemId: 'item',
      targetUid: 'target',
      plannerUid: 'planner',
      participantUids: const ['target', 'planner'],
      seenByUids: const ['target'],
    );

    expect(completion.isUnseenBy('target'), isFalse);
    expect(completion.isUnseenBy('planner'), isTrue);
    expect(completion.isUnseenBy('outsider'), isFalse);
  });

  testWidgets(
    'duplicate snapshots do not restart a celebration and later tasks still play',
    (tester) async {
      final events = StreamController<List<CompletionCelebration>>.broadcast();
      final store = _RecordingCelebrationStore(events.stream);
      final lock = AppLockController(
        store: _NoopLockStore(),
        auth: _NoopDeviceAuth(),
        secureWindow: _NoopSecureWindow(),
        initiallyEnabled: false,
      );
      addTearDown(events.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUidProvider.overrideWithValue('target'),
            completionCelebrationRepositoryProvider.overrideWithValue(store),
            appLockControllerProvider.overrideWithValue(lock),
          ],
          child: const MaterialApp(
            home: CompletionCelebrationHost(child: Scaffold(body: Text('APP'))),
          ),
        ),
      );
      events.add([event('one')]);
      await tester.pump();
      await tester.pump();

      final first = find.byKey(const ValueKey('completion-celebration-one'));
      expect(first, findsOneWidget);
      expect(tester.getSize(first), tester.getSize(find.byType(Scaffold)));

      await tester.pump(const Duration(milliseconds: 700));
      events.add([event('one')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(
        first,
        findsNothing,
        reason: 'a repeated snapshot must not restart',
      );
      expect(store.acknowledged, ['one']);

      // Keep the first acknowledgement unresolved: the second visual must not
      // wait for network bookkeeping from the first.
      events.add([event('one'), event('two')]);
      final second = find.byKey(const ValueKey('completion-celebration-two'));
      for (var frame = 0; frame < 4 && second.evaluate().isEmpty; frame++) {
        await tester.pump();
      }
      expect(second, findsOneWidget);
    },
  );
}

class _RecordingCelebrationStore implements CompletionCelebrationStore {
  _RecordingCelebrationStore(this.stream);

  final Stream<List<CompletionCelebration>> stream;
  final acknowledged = <String>[];
  final neverCompletes = Completer<void>();

  @override
  Stream<List<CompletionCelebration>> watchUnseen(String uid) => stream;

  @override
  Future<void> acknowledge(CompletionCelebration event, String uid) {
    acknowledged.add(event.id);
    return neverCompletes.future;
  }
}

class _NoopLockStore implements AppLockStore {
  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool value) async {}
}

class _NoopDeviceAuth implements DeviceAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopSecureWindow implements SecureWindow {
  @override
  Future<void> setSecure(bool enabled) async {}
}
