import 'package:flutter/widgets.dart';

/// **An overlay for everything above the router** (device report 2026-10-05).
///
/// The app-wide hosts — the splash, the app lock, the celebration, the Missed
/// pop-up — sit in `MaterialApp.builder`, ABOVE the router's navigator and so
/// above the only `Overlay` the app had. Anything in them that needs one — a
/// tooltip (the Missed pop-up's ✕ "Close"), a menu, a dropdown — threw "No
/// Overlay widget found" and the phone showed Flutter's red error screen.
/// This gives that whole layer an overlay of its own.
///
/// It is ONLY an overlay, not a navigator: `showDialog` still finds the
/// router's navigator from every screen, so where dialogs open and how Back
/// closes them is unchanged. Screens keep using their navigator's own overlay
/// (the nearest one), so nothing inside the app moves either.
///
/// The one entry is created once and rebuilt when [child] changes, so the
/// hosts below keep their state across rebuilds.
class AppOverlayScope extends StatefulWidget {
  const AppOverlayScope({super.key, required this.child});

  final Widget child;

  @override
  State<AppOverlayScope> createState() => _AppOverlayScopeState();
}

class _AppOverlayScopeState extends State<AppOverlayScope> {
  late final OverlayEntry _entry = OverlayEntry(
    maintainState: true,
    builder: (_) => widget.child,
  );

  @override
  void didUpdateWidget(AppOverlayScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
