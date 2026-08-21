/// **Username validation and canonicalisation — pure, no Firestore.**
///
/// Lives in `domain/` and imports nothing, because the rules it encodes are
/// asserted in three places that must agree exactly:
///
///   1. the edit field, which greys out Save;
///   2. [UsernameRepository.claim], which writes the reservation;
///   3. `firestore.rules`, which is the only one of the three that is
///      *enforcement* rather than convenience.
///
/// When they disagree the failure is silent in the worst direction: a name the
/// client accepts and the server refuses produces a `PERMISSION_DENIED` on Save
/// with nothing to explain it. So the constraints are stated once here, and the
/// rules file quotes this doc comment rather than inventing its own.
///
/// **The canonical form is lowercase.** `usernames/{handle}` is keyed by it, so
/// `Ana` and `ana` are the same reservation and cannot both be claimed. What
/// the user *typed* is not preserved: unlike a display name (which is
/// `UserProfile.name` and stays exactly as entered), a handle is an identifier
/// people retype, and a case-preserving identifier that is case-insensitively
/// unique invites exactly the confusion it pretends to avoid.
library;

/// Lower bound. Three characters is short enough to be worth having and long
/// enough that the space isn't trivially exhaustible by a squatter.
const int kUsernameMinLength = 3;

/// Upper bound. Twenty fits a search result row and a profile header at
/// `titleMedium` without eliding on a narrow phone.
const int kUsernameMaxLength = 20;

/// Handles nobody may claim.
///
/// Two kinds, and both matter. **Route names** would make `/u/settings`
/// ambiguous the day a vanity URL exists — cheaper to reserve now than to
/// migrate someone's handle later. **Impersonation risks** are the ones with a
/// victim: a user calling themselves `admin` or `support` in an app whose whole
/// premise is *someone you trust schedules your day* is a social-engineering
/// vector, not a naming quirk.
///
/// Enforced on the CANONICAL form, so `Admin` and `ADMIN` are both refused.
const Set<String> kReservedUsernames = {
  // Routes and namespaces.
  'about', 'account', 'admin', 'api', 'app', 'archived', 'auth', 'blocked',
  'chatbot', 'dev', 'friends', 'groups', 'help', 'home', 'invite', 'login',
  'logout', 'me', 'new', 'notifications', 'outcome', 'privacy', 'profile',
  'search', 'settings', 'signin', 'signout', 'signup', 'support', 'terms',
  'user', 'users',
  // Impersonation.
  'moderator', 'official', 'root', 'staff', 'system', 'timeapp', 'time_app',
};

/// Why a candidate handle was refused, or [none].
///
/// An enum rather than a `String?` so the *message* lives in the presentation
/// layer where the locale does, and so a test asserts on the reason rather than
/// on English copy that is free to change.
enum UsernameProblem {
  none,
  tooShort,
  tooLong,
  badCharacters,
  mustStartWithLetter,
  reserved,
}

/// The canonical form of what the user typed: trimmed and lowercased.
///
/// `toLowerCase()` without a locale is deliberate. Dart's locale-sensitive
/// lowercasing would map Turkish `I` to a dotless `ı`, so the same handle typed
/// on a Turkish phone and an English one would canonicalise to two different
/// reservation keys — a uniqueness guarantee that silently depends on the
/// typist's device. The character class below admits only ASCII anyway, so the
/// invariant costs nothing.
String canonicalUsername(String raw) => raw.trim().toLowerCase();

/// Validates the CANONICAL form. Call [canonicalUsername] first; this does not
/// trim or lowercase, so that a caller cannot accidentally validate one string
/// and store another.
UsernameProblem validateUsername(String canonical) {
  if (canonical.length < kUsernameMinLength) return UsernameProblem.tooShort;
  if (canonical.length > kUsernameMaxLength) return UsernameProblem.tooLong;
  // ASCII only, and no dots or hyphens. Dots invite homograph pairs that read
  // identically in a list (`a.na` / `an.a`), and both would need normalising
  // into the reservation key to be safe — a second canonical form, which is
  // exactly the drift this file exists to prevent.
  if (!RegExp(r'^[a-z0-9_]+$').hasMatch(canonical)) {
    return UsernameProblem.badCharacters;
  }
  // A leading digit or underscore lets a handle imitate an id or a system
  // token. It also keeps the door open for a future `@`-mention parser, which
  // needs an unambiguous first character.
  if (!RegExp(r'^[a-z]').hasMatch(canonical)) {
    return UsernameProblem.mustStartWithLetter;
  }
  if (kReservedUsernames.contains(canonical)) return UsernameProblem.reserved;
  return UsernameProblem.none;
}

/// Convenience for call sites that only need a yes/no.
bool isValidUsername(String canonical) =>
    validateUsername(canonical) == UsernameProblem.none;
