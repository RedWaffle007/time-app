/// The permissions first-run onboarding walks, in order of consequence.
///
/// The order is not cosmetic: it is the order in which a missing permission
/// breaks delivery. [notifications] decides whether a reminder appears at all;
/// [exactAlarms] whether it appears on time; [fullScreenIntent] whether it rings
/// over another app; [battery] whether the process survives Doze to fire; and
/// [autostart] whether an OEM lets it run at all. A user who grants only the
/// first few still gets a working-but-degraded reminder, which is why the most
/// consequential ask comes first.
enum OnboardingStep {
  /// POST_NOTIFICATIONS — a runtime system dialog (the only one in the set).
  notifications,

  /// SCHEDULE_EXACT_ALARM — deep-link to the app's Alarms & reminders toggle.
  exactAlarms,

  /// USE_FULL_SCREEN_INTENT — deep-link to the app's full-screen-intent toggle.
  fullScreenIntent,

  /// Battery / Doze exemption — the direct system dialog.
  battery,

  /// OEM autostart — a resolve-checked deep-link, with a per-OEM guided card
  /// fallback. The one step whose grant cannot be read back, so it is offered on
  /// aggressive OEMs regardless and never shows as "done".
  autostart,
}
