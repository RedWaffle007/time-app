import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/completion_celebration_repository.dart';
import '../domain/completion_celebration.dart';

final completionCelebrationRepositoryProvider =
    Provider<CompletionCelebrationStore>((ref) {
      return CompletionCelebrationRepository(FirebaseFirestore.instance);
    });

final unseenCompletionCelebrationsProvider =
    StreamProvider<List<CompletionCelebration>>((ref) {
      final uid = ref.watch(currentUidProvider);
      if (uid == null) return Stream.value(const []);
      return ref
          .watch(completionCelebrationRepositoryProvider)
          .watchUnseen(uid);
    });

/// Celebrations this device has just committed. The host plays one the moment
/// the Done transaction succeeds; the Firestore stream above remains the
/// delivery path for the other participant and for missed sessions.
class CommittedCelebrationNotifier extends Notifier<CompletionCelebration?> {
  @override
  CompletionCelebration? build() => null;

  void celebrate(CompletionCelebration event) => state = event;
}

final committedCelebrationProvider =
    NotifierProvider<CommittedCelebrationNotifier, CompletionCelebration?>(
      CommittedCelebrationNotifier.new,
    );
