import 'dart:collection';

import '../domain/completion_celebration.dart';

/// Session queue that prevents a live Firestore re-emission from displaying an
/// event twice before its acknowledgement reaches the server.
class CompletionCelebrationQueue {
  final Queue<CompletionCelebration> _waiting = Queue();
  final Set<String> _knownIds = {};

  CompletionCelebration? current;

  void addAll(Iterable<CompletionCelebration> events) {
    for (final event in events) {
      if (_knownIds.add(event.id)) {
        _waiting.add(event);
      }
    }
  }

  CompletionCelebration? takeNext() {
    current ??= _waiting.isEmpty ? null : _waiting.removeFirst();
    return current;
  }

  void complete(String id) {
    if (current?.id == id) {
      current = null;
    }
  }

  void clear() {
    _waiting.clear();
    _knownIds.clear();
    current = null;
  }
}
