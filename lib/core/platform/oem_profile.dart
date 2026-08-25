/// **OEM branch selection** — the one pure function that decides, from
/// `Build.MANUFACTURER` alone, whether a device belongs to a manufacturer known
/// to kill background apps behind an autostart gate with no reliable public
/// intent.
///
/// It is deliberately pure and device-free so the branch logic can be pinned in
/// a unit test (`test/onboarding_test.dart`) rather than only on hardware: the
/// failure mode of getting it wrong is a whole class of phones silently never
/// delivering a reminder, which is exactly the kind of thing that must be
/// testable without owning every OEM.
///
/// Naming, not glyph-matching: an unknown or stock manufacturer maps to
/// [OemFamily.other] with [OemProfile.autostartLikelyNeeded] false, which is
/// what makes an untested device SKIP the autostart step gracefully instead of
/// showing instructions that point nowhere.
library;

enum OemFamily {
  /// Xiaomi / Redmi / Poco (MIUI, HyperOS) — the primary test device, and the
  /// one whose Boost/OneKeyClean cleaner was observed discarding armed alarms.
  xiaomi,

  /// Oppo / Realme (ColorOS).
  oppo,

  /// Vivo / iQOO (Funtouch / OriginOS).
  vivo,

  /// OnePlus (older OxygenOS; newer builds are ColorOS-based).
  oneplus,

  /// Huawei / Honor (EMUI / MagicOS).
  huawei,

  /// Samsung (One UI). Kills background apps ("put unused apps to sleep") but
  /// exposes no per-app autostart intent, so it gets a guided card and no
  /// deep-link.
  samsung,

  /// Stock Android and everything not known to need special handling
  /// (Pixel, Motorola, Nokia, Sony, and any unrecognised manufacturer).
  other,
}

/// What onboarding needs to know about a device's manufacturer. Pure data.
class OemProfile {
  const OemProfile({
    required this.family,
    required this.displayName,
    required this.autostartLikelyNeeded,
  });

  final OemFamily family;

  /// Human-readable manufacturer name for onboarding copy ("Xiaomi", "Samsung").
  final String displayName;

  /// Whether this OEM aggressively kills background apps and needs the autostart
  /// onboarding step at all. False for stock/unknown devices — the graceful-skip
  /// case.
  final bool autostartLikelyNeeded;
}

/// Map a raw `Build.MANUFACTURER` string to an [OemProfile].
///
/// Case-insensitive and substring-based on purpose: manufacturers report
/// inconsistently ("Xiaomi", "XIAOMI", occasionally a sub-brand), and matching a
/// substring is more robust than an exact table. An empty or unrecognised string
/// — including everything reported off Android — falls through to
/// [OemFamily.other], which is the skip-the-step default.
OemProfile oemProfileFor(String manufacturer) {
  final m = manufacturer.trim().toLowerCase();

  bool has(List<String> needles) => needles.any(m.contains);

  if (has(['xiaomi', 'redmi', 'poco'])) {
    return const OemProfile(
      family: OemFamily.xiaomi,
      displayName: 'Xiaomi',
      autostartLikelyNeeded: true,
    );
  }
  if (has(['oppo', 'realme'])) {
    return const OemProfile(
      family: OemFamily.oppo,
      displayName: 'Oppo',
      autostartLikelyNeeded: true,
    );
  }
  if (has(['oneplus'])) {
    return const OemProfile(
      family: OemFamily.oneplus,
      displayName: 'OnePlus',
      autostartLikelyNeeded: true,
    );
  }
  if (has(['vivo', 'iqoo'])) {
    return const OemProfile(
      family: OemFamily.vivo,
      displayName: 'Vivo',
      autostartLikelyNeeded: true,
    );
  }
  if (has(['huawei', 'honor'])) {
    return const OemProfile(
      family: OemFamily.huawei,
      displayName: 'Huawei',
      autostartLikelyNeeded: true,
    );
  }
  if (has(['samsung'])) {
    return const OemProfile(
      family: OemFamily.samsung,
      displayName: 'Samsung',
      autostartLikelyNeeded: true,
    );
  }
  return OemProfile(
    family: OemFamily.other,
    // Preserve the reported name where there is one, so a stock device still
    // reads naturally if it is ever surfaced; empty falls back to a neutral word.
    displayName: manufacturer.trim().isEmpty ? 'your phone' : manufacturer.trim(),
    autostartLikelyNeeded: false,
  );
}
