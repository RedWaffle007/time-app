import '../../notifications/data/foreground_push_presenter.dart';

/// Whether a cold start opened by a notification tap skips the startup screen.
///
/// **Only alarm launches skip it** — the full-screen alarm route, or a tapped
/// local reminder (payload = a bare item id, which opens the alarm route). The
/// alarm service owns the ting→ring order there, so nothing may flash or ring
/// first.
///
/// **Every push tap shows the startup screen** (directed 2026-09-26). A push
/// launch is only known when `getInitialMessage()` resolves, after the reveal
/// has mounted and its ting has already played; skipping at that point tore
/// the screen down mid-strike, so the user heard the startup sound with no
/// startup screen. The destination is routed beneath and revealed after 1.5 s.
bool launchSkipsReveal({required bool alarmLaunch, String? localPayload}) {
  if (alarmLaunch) return true;
  if (localPayload == null || localPayload.isEmpty) return false;
  return decodePushTapPayload(localPayload) == null;
}
