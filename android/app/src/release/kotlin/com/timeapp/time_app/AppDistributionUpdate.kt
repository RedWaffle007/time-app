package com.timeapp.time_app

import android.app.Activity

/**
 * RELEASE variant. No-op: the Firebase App Distribution SDK is debug-only (Play
 * policy forbids shipping it), so a release build has nothing to check. Exists so
 * the shared [MainActivity] call site compiles without the SDK on the classpath.
 * See the debug copy in `src/debug` for the real implementation.
 */
object AppDistributionUpdate {
    fun checkForUpdate(activity: Activity) {
        // Intentionally empty.
    }
}
