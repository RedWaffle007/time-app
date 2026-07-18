import 'dart:async';

import 'package:flutter/foundation.dart';

/// Bridges a Stream to a Listenable so go_router can re-run its `redirect`
/// whenever the stream emits. Standard go_router pattern for auth streams.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
