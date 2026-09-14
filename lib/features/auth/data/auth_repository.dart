import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/firebase/firebase_constants.dart';

/// Wraps Firebase Auth + Google Sign-In so the rest of the app doesn't touch
/// the SDKs directly.
class AuthRepository {
  AuthRepository(this._auth);

  final FirebaseAuth _auth;

  // google_sign_in v7 requires initialize() to be called exactly once per run.
  bool _googleInitialized = false;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    // serverClientId makes the returned idToken valid for Firebase Auth.
    await GoogleSignIn.instance.initialize(serverClientId: kGoogleServerClientId);
    _googleInitialized = true;
  }

  /// Interactive Google sign-in → exchange the Google ID token for a Firebase
  /// session. Cancellation is a normal return; genuine failures are rethrown.
  Future<void> signInWithGoogle() async {
    await _ensureGoogleInitialized();

    // authenticate() shows the account picker and returns the chosen account.
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      rethrow;
    }
    final idToken = account.authentication.idToken;

    if (idToken == null) {
      throw Exception('Google sign-in did not return an ID token.');
    }

    final credential = GoogleAuthProvider.credential(idToken: idToken);
    await _auth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    // Sign out of both so the next sign-in shows the account picker again.
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Ignore — Google may not have an active session (e.g. already signed out).
    }
    await _auth.signOut();
  }
}
