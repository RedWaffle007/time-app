import 'dart:async';
import 'dart:math' as math;

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
import 'package:time_app/features/celebrations/presentation/completion_confetti.dart';
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
  _committedCelebrationTests();

  test('visual contract matches the 42-frame reference at 30 fps', () {
    expect(completionCelebrationDuration, const Duration(milliseconds: 1400));
  });

  test(
    'burst is dense, deterministic, varied, and reaches the viewport edges',
    () {
      final first = CompletionConfettiBurst.seeded(42);
      final again = CompletionConfettiBurst.seeded(42);

      expect(first.particles, hasLength(completionConfettiParticleCount));
      expect(
        first.particles.every(
          (particle) =>
              particle.originX > 0.47 &&
              particle.originX < 0.53 &&
              particle.originY > 0.51 &&
              particle.originY < 0.57,
        ),
        isTrue,
        reason: 'all particles must originate in one compact burst, not rain',
      );
      expect(
        first.particles.where((particle) => particle.velocityX < 0).length,
        greaterThan(50),
      );
      expect(
        first.particles.where((particle) => particle.velocityX > 0).length,
        greaterThan(50),
      );
      expect(first.particles.every((particle) => particle.gravity > 0), isTrue);
      expect(
        first.particles.map((particle) => particle.shape).toSet(),
        CompletionConfettiShape.values.toSet(),
      );
      expect(first.particles.first.velocityX, again.particles.first.velocityX);

      final expansion = first.particles
          .map((particle) => particle.sample(0.36))
          .where((sample) => sample.opacity > 0)
          .toList();
      expect(
        expansion.map((sample) => sample.x).reduce(math.min),
        lessThan(0.08),
      );
      expect(
        expansion.map((sample) => sample.x).reduce(math.max),
        greaterThan(0.92),
      );
      expect(
        expansion.map((sample) => sample.y).reduce(math.min),
        lessThan(0.16),
      );
      expect(
        expansion.map((sample) => sample.y).reduce(math.max),
        greaterThan(0.78),
      );
    },
  );

  test('particles burst outward, reverse under gravity, rotate, and fade', () {
    final burst = CompletionConfettiBurst.seeded(91);
    final particle = burst.particles[1];
    final early = particle.sample(0.08 / 1.4);
    final apex = particle.sample(0.62 / 1.4);
    final falling = particle.sample(1.22 / 1.4);

    expect(
      (apex.x - particle.originX).abs(),
      greaterThan((early.x - particle.originX).abs()),
    );
    expect(falling.y, greaterThan(apex.y));
    expect(falling.rotation, isNot(equals(early.rotation)));
    expect(falling.opacity, lessThan(apex.opacity));
    expect(
      burst.particles.every((entry) => entry.sample(1).opacity == 0),
      isTrue,
    );
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
      var underlyingTaps = 0;
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
          child: MaterialApp(
            home: CompletionCelebrationHost(
              child: Scaffold(
                body: TextButton(
                  key: const ValueKey('underlying-action'),
                  onPressed: () => underlyingTaps++,
                  child: const Text('APP'),
                ),
              ),
            ),
          ),
        ),
      );
      events.add([event('one')]);
      await tester.pump();
      await tester.pump();

      final first = find.byKey(const ValueKey('completion-celebration-one'));
      expect(first, findsOneWidget);
      expect(tester.getSize(first), tester.getSize(find.byType(Scaffold)));
      await tester.tap(find.byKey(const ValueKey('underlying-action')));
      expect(underlyingTaps, 1, reason: 'the overlay must never consume taps');
      // `forward()` is invoked from a post-frame callback. Give the controller
      // its first ticker frame so the measured 1,400ms starts at time zero,
      // rather than spending the first timed pump establishing the epoch.
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 700));
      events.add([event('one')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 699));
      expect(first, findsOneWidget);
      // Flutter completes a ticker on the first rendered frame *past* its
      // duration. The controller contract remains exactly 1,400ms; 1,401ms is
      // the first synthetic frame on which its completion listener can clean up.
      await tester.pump(const Duration(milliseconds: 2));
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
      await tester.pump(); // establish this controller run's first ticker frame
      expect(
        find.descendant(of: second, matching: find.byType(RepaintBoundary)),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 2));
      expect(
        second,
        findsOneWidget,
        reason: 'background time must pause, not finish or replay, the burst',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(); // establish the resumed ticker's new time origin
      await tester.pump(const Duration(milliseconds: 999));
      expect(second, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2));
      expect(second, findsNothing);
      expect(store.acknowledged, ['one', 'two']);
    },
  );
}

/// Regression (2026-09-25): the burst waited for the Firestore echo — a second
/// network round trip after the Done had already committed.
void _committedCelebrationTests() {
  testWidgets(
    'a committed Done plays on the next frame with no Firestore echo',
    (tester) async {
      final events = StreamController<List<CompletionCelebration>>.broadcast();
      addTearDown(events.close);
      final store = _RecordingCelebrationStore(events.stream);
      await tester.pumpWidget(_celebrationHost(store));
      final container = ProviderScope.containerOf(
        tester.element(find.text('APP')),
      );

      container
          .read(committedCelebrationProvider.notifier)
          .celebrate(
            CompletionCelebration.committed(
              targetUid: 'target',
              itemId: 'item-one',
              plannerUid: 'planner',
            ),
          );
      // Frame 1 runs the host's post-frame start; frame 2 paints the overlay.
      // No stream emission is involved.
      await tester.pump();
      await tester.pump();

      final burst = find.byKey(
        const ValueKey('completion-celebration-target_item-one'),
      );
      expect(burst, findsOneWidget);

      // The durable echo arrives mid-burst and must not replay it.
      await tester.pump(const Duration(milliseconds: 600));
      events.add([
        CompletionCelebration(
          id: 'target_item-one',
          itemId: 'item-one',
          targetUid: 'target',
          plannerUid: 'planner',
          participantUids: const ['target', 'planner'],
          seenByUids: const [],
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(burst, findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(burst, findsNothing, reason: 'the echo never replays');
      expect(store.acknowledged, ['target_item-one']);
    },
  );

  testWidgets('another account\'s committed event is ignored', (tester) async {
    final events = StreamController<List<CompletionCelebration>>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(
      _celebrationHost(_RecordingCelebrationStore(events.stream)),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('APP')),
    );

    container
        .read(committedCelebrationProvider.notifier)
        .celebrate(
          CompletionCelebration.committed(
            targetUid: 'someone-else',
            itemId: 'x',
            plannerUid: 'someone-else',
          ),
        );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('completion-celebration-someone-else_x')),
      findsNothing,
    );
  });

  test('a committed event mirrors the durable document identity', () {
    final self = CompletionCelebration.committed(
      targetUid: 'me',
      itemId: 'item',
      plannerUid: 'me',
    );
    final shared = CompletionCelebration.committed(
      targetUid: 'me',
      itemId: 'item',
      plannerUid: 'friend',
    );

    expect(self.id, CompletionCelebration.eventId('me', 'item'));
    expect(self.participantUids, ['me']);
    expect(shared.participantUids, ['me', 'friend']);
    expect(shared.isUnseenBy('me'), isTrue);
  });
}

Widget _celebrationHost(CompletionCelebrationStore store) => ProviderScope(
  overrides: [
    currentUidProvider.overrideWithValue('target'),
    completionCelebrationRepositoryProvider.overrideWithValue(store),
    appLockControllerProvider.overrideWithValue(
      AppLockController(
        store: _NoopLockStore(),
        auth: _NoopDeviceAuth(),
        secureWindow: _NoopSecureWindow(),
        initiallyEnabled: false,
      ),
    ),
  ],
  child: const MaterialApp(
    home: CompletionCelebrationHost(child: Scaffold(body: Text('APP'))),
  ),
);

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
