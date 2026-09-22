// Non-production Firebase options used only by GitHub Actions.
// The workflow copies this file to the ignored generated-file location.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => ci;

  static const FirebaseOptions ci = FirebaseOptions(
    apiKey: 'ci-not-a-real-api-key',
    appId: '1:000000000000:android:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'time-app-ci',
    storageBucket: 'time-app-ci.invalid',
  );
}
