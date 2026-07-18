import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/app_router.dart';

/// Root widget. Uses MaterialApp.router so go_router owns navigation.
///
/// This is a ConsumerWidget (Riverpod's version of StatelessWidget) so it can
/// read providers via `ref`. Here it reads the router provider.
class TimeApp extends ConsumerWidget {
  const TimeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'time-app',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
