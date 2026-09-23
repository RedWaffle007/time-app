import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/celebrations/application/celebration_queue.dart';
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
  test('visual and sound contract is exactly 1.5 seconds', () {
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
}
