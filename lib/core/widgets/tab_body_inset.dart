import 'package:flutter/widgets.dart';

import '../theme/app_tokens.dart';

/// The extra horizontal gutter every main-tab body sits in (UI-RULES §4,
/// `Space.tabBodyInset`). Device report 2026-09-26: tab content sat too close
/// to the left edge. One widget on the four tab bodies (Plan's sub-tab view,
/// Track, Stats, You) so the gutter is changed in exactly one place; app bars
/// and the bottom bar are outside it and unaffected.
class TabBodyInset extends StatelessWidget {
  const TabBodyInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: Space.tabBodyInset, child: child);
}
