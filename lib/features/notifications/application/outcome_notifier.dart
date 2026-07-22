import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/http_outcome_notifier.dart';

/// The app's seam between "an outcome was recorded" and "the planner gets a
/// push." The UI depends ONLY on this abstraction — never on the Worker URL —
/// so the transport can change underneath it.
///
/// Card-day (see DECISIONS.md): when the push moves to a Firestore-triggered
/// Cloud Function, swap [outcomeNotifierProvider] to return [NoopOutcomeNotifier]
/// — the server then fires on the write and this call becomes a no-op. That is
/// the ONLY app-side change required.
abstract class OutcomeNotifier {
  Future<void> notifyOutcome({
    required String targetUid,
    required String itemId,
    required OutcomeResult outcome,
  });
}

/// The card-day implementation: does nothing, because the server sends on write.
class NoopOutcomeNotifier implements OutcomeNotifier {
  const NoopOutcomeNotifier();

  @override
  Future<void> notifyOutcome({
    required String targetUid,
    required String itemId,
    required OutcomeResult outcome,
  }) async {}
}

final outcomeNotifierProvider = Provider<OutcomeNotifier>((ref) {
  // No-card transport for now. Swap to `const NoopOutcomeNotifier()` on card-day.
  return HttpOutcomeNotifier();
});
