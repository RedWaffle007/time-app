import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../reminders/application/reminder_providers.dart';
import '../data/foreground_push_presenter.dart';

/// Shares the app's ONE local-notifications plugin, so a tap on a foreground
/// push reaches the same response callback the scheduler registered.
final foregroundPushPresenterProvider = Provider<ForegroundPushPresenter>((
  ref,
) {
  return ForegroundPushPresenter(ref.watch(localNotificationsPluginProvider));
});
