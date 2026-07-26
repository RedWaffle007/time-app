import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../data/archive_repository.dart';

final archiveRepositoryProvider = Provider<ArchiveRepository>((ref) {
  return ArchiveRepository(FirebaseFirestore.instance);
});

/// The raw archive stream. **It cannot deliver an error**, by construction.
///
/// This is the isolation seam, and it is deliberate rather than incidental.
/// Archive is a *view convenience*: it decides which settled rows to hide. The
/// schedule is the product. So a failure to read the archive — offline before
/// the local cache is warm, or a device running against a project where the
/// `users/{uid}/state` rule isn't deployed yet — must degrade to "nothing is
/// archived" and show the full schedule. It must never be able to put My
/// Schedule or Activity into `AsyncView`'s error state, because that would let
/// a broken convenience feature take down the thing it decorates.
///
/// The transformer converts an error event into an empty-set data event. The
/// underlying Firestore snapshot stream closes after an error, so this emits
/// once and completes — leaving the provider holding `{}` rather than an error,
/// which is exactly the intended resting state.
///
/// Prefer [archivedIdsProvider] at call sites; this is exposed so a screen that
/// genuinely wants the load state (none today) could have it.
final archivedIdsStreamProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const <String>{});

  return ref.watch(archiveRepositoryProvider).watchArchivedIds(uid).transform(
        StreamTransformer<Set<String>, Set<String>>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.add(const <String>{}),
        ),
      );
});

/// The archive set as a plain value. **Loading and error both read as "nothing
/// archived".**
///
/// The second half of the isolation seam, and the one every consumer uses.
/// Watching an `AsyncValue` never rethrows (only `ref.watch(p.future)` does), so
/// reading `.value` here means an archive problem can only ever make rows
/// *appear*, never make the list fail.
///
/// The cost, named: during the first frames of a cold start the archive hasn't
/// resolved, so archived rows are briefly visible before they filter out. That
/// is the correct direction to fail — archive is decluttering, not privacy (app
/// lock is the privacy answer), so a flash of a settled item you had hidden is
/// strictly better than a schedule that won't load.
final archivedIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(archivedIdsStreamProvider).value ?? const <String>{};
});
