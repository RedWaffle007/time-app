/// Native-only registration plugin.
///
/// The app-facing API remains in `features/reminders/data/alarm_delivery.dart`;
/// this package exists so Flutter's generated registrant installs that API's
/// Android handler in both the UI engine and Firebase Messaging's background
/// engine.
library;
