// The constructor takes NAMED collaborators, so the initializing-formal the lint
// wants (`required this._store`) would put a private name in the public API and
// force every call site to write `_store:`. The initializer list is correct here.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../data/app_lock_store.dart';
import '../data/device_auth.dart';
import '../data/secure_window.dart';

/// How long the app may sit in the background before it re-locks.
///
/// **Not configurable.** Nobody tunes a setting like this, and the case it
/// exists for is real and common: glance at the calendar, glance back. A
/// confirmation-free 30s covers that without covering "left my phone on the
/// table".
const kAppLockGrace = Duration(seconds: 30);

/// The app-lock state machine. Deliberately pure Dart: no `WidgetsBinding`, no
/// `BuildContext`, no plugin construction. Lifecycle is *pushed in* by
/// [AppLockGate], the clock is injected, and every collaborator is an interface
/// — which is what lets the grace window and the task-kill behaviour be pinned
/// by tests rather than argued about.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required AppLockStore store,
    required DeviceAuth auth,
    required SecureWindow secureWindow,
    required bool initiallyEnabled,
    DateTime Function() now = DateTime.now,
    Duration grace = kAppLockGrace,
  })  : _store = store,
        _auth = auth,
        _secureWindow = secureWindow,
        _enabled = initiallyEnabled,
        // THE TASK-KILL ANSWER, and it is this line. A freshly constructed
        // controller means a fresh process, and a fresh process starts LOCKED
        // whenever the lock is on. Killing the app from the recents switcher
        // therefore locks immediately and unconditionally — there is no code
        // path that could grant it grace, because the grace window lives in
        // memory (see [_leftAt]) and memory is exactly what a kill destroys.
        _locked = initiallyEnabled,
        _now = now,
        _grace = grace;

  final AppLockStore _store;
  final DeviceAuth _auth;
  final SecureWindow _secureWindow;
  final DateTime Function() _now;
  final Duration _grace;

  bool _enabled;
  bool _locked;
  bool _authInFlight = false;
  String? _notice;

  /// When the app was last backgrounded.
  ///
  /// **In memory only — never persisted, and that is load-bearing.** If this
  /// were written to `shared_preferences`, killing the app and reopening it
  /// inside 30s would restore the window and walk straight in, turning an
  /// explicit task-kill into the weakest entry point in the app. Keeping it in
  /// RAM makes "a kill always locks" true by construction rather than by a
  /// check someone could later delete.
  DateTime? _leftAt;

  bool get isEnabled => _enabled;

  /// Whether the gate should be showing. Reads `_enabled` too, so turning the
  /// lock off can never leave a stale locked state behind.
  bool get isLocked => _enabled && _locked;

  /// True while the OS prompt is up.
  bool get isAuthenticating => _authInFlight;

  /// A one-shot explanation for the user — why the toggle refused, or why the
  /// lock just turned itself off. Cleared once shown.
  String? get notice => _notice;

  void consumeNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Apply the window flag to match the persisted setting. Called once at
  /// startup: `FLAG_SECURE` is per-window and does not survive process death,
  /// so it has to be re-applied every launch, not just when the toggle moves.
  Future<void> start() async {
    await _secureWindow.setSecure(_enabled);
  }

  // --- lifecycle, pushed in by the gate ---

  /// The app went to the background (`paused` / `hidden`).
  void didBackground() {
    // The OS auth prompt backgrounds us itself. Recording a timestamp here
    // would start a grace window the user never asked for.
    //
    // This can only ever be skipped while LOCKED — [unlock] is the sole caller
    // that sets `_authInFlight`, and it only runs when locked — so ignoring it
    // can never leave an unlocked app failing to re-lock.
    if (_authInFlight) return;
    _leftAt = _now();
  }

  /// The app is being torn down (`detached`) — the explicit task-kill signal.
  ///
  /// Locks now and destroys the grace window. Belt-and-braces with the
  /// constructor: if the process actually dies, the next launch starts locked
  /// anyway; if `detached` fires while the process survives, this covers it.
  void didDetach() {
    _leftAt = null;
    if (_enabled && !_locked) {
      _locked = true;
      notifyListeners();
    }
  }

  /// The app came back to the foreground (`resumed`).
  void didForeground() {
    if (_authInFlight) return;
    if (!_enabled || _locked) return;

    final leftAt = _leftAt;
    _leftAt = null;
    // No recorded background means no real absence — a bare `resumed` (the
    // notification shade, a permission sheet) must not lock a user out of an
    // app they are looking at.
    if (leftAt == null) return;

    if (_now().difference(leftAt) >= _grace) {
      _locked = true;
      notifyListeners();
    }
  }

  // --- actions ---

  /// Run the OS prompt and unlock on success.
  Future<void> unlock() async {
    if (_authInFlight || !isLocked) return;
    _authInFlight = true;
    notifyListeners();
    try {
      // The lock became unopenable while it was on — the user removed their
      // screen lock, or wiped their enrolled biometrics. Turning it off is the
      // only honest move: leaving it on is a bricked app, and an attacker
      // cannot reach this state without already knowing the credential they
      // had to enter to remove it.
      if (!await _auth.canAuthenticate()) {
        await _disable(
          'App lock turned off: this device no longer has a screen lock or '
          'biometric set up, so there was no way left to unlock.',
        );
        return;
      }
      if (await _auth.authenticate()) {
        _locked = false;
        _leftAt = null;
      }
    } finally {
      _authInFlight = false;
      notifyListeners();
    }
  }

  /// Turn the lock on or off. Returns whether the request took effect.
  ///
  /// Turning it ON **refuses** on a device that cannot authenticate, and says
  /// why. Silently accepting would enable a lock that can never be opened —
  /// the app would be unusable from its next cold start, with the setting that
  /// caused it sitting behind the lock.
  Future<bool> setEnabled(bool value) async {
    if (value == _enabled) return true;

    if (value) {
      if (!await _auth.canAuthenticate()) {
        _notice = 'This device has no screen lock or biometric set up. Add a '
            'PIN, pattern, password or fingerprint in your device settings '
            'first — otherwise the app lock could never be opened.';
        notifyListeners();
        return false;
      }
      await _store.setEnabled(true);
      await _secureWindow.setSecure(true);
      _enabled = true;
      // Not locked: the user is holding the phone and just flipped the switch.
      _locked = false;
      _leftAt = null;
      notifyListeners();
      return true;
    }

    await _disable(null);
    return true;
  }

  Future<void> _disable(String? notice) async {
    await _store.setEnabled(false);
    await _secureWindow.setSecure(false);
    _enabled = false;
    _locked = false;
    _leftAt = null;
    _notice = notice;
    notifyListeners();
  }
}
