package com.timeapp.time_app

import android.app.Activity

/**
 * PROFILE variant. No-op, identical to the release stub: the Firebase App
 * Distribution SDK is debug-only (Play policy forbids shipping it), and a
 * profile build carries no tester tooling either. Exists so the shared
 * [MainActivity] call site compiles for `flutter run/build --profile`, which
 * Flutter maps to its own `profile` build type with no `src/debug` on the
 * classpath. See the debug copy in `src/debug` for the real implementation.
 */
object AppDistributionUpdate {
    fun checkForUpdate(activity: Activity) {
        // Intentionally empty.
    }
}
