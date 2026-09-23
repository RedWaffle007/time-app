import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/completion_celebration_repository.dart';
import '../domain/completion_celebration.dart';

final completionCelebrationRepositoryProvider =
    Provider<CompletionCelebrationRepository>((ref) {
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
