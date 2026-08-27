package com.timeapp.time_app

import android.app.Activity

/**
 * DEBUG variant — currently a NO-OP.
 *
 * The Firebase App Distribution SDK was removed from the debug build on
 * 2026-08-27: simply having it on the classpath makes it auto-initialize (via
 * its own ContentProvider) and repeatedly post the "enable tester / in-app
 * features" prompt on every foreground — a never-ending popup that also covered
 * the cold-start splash. Gating our own `updateIfNewReleaseAvailable()` call was
 * not enough because the SDK prompts on its own.
 *
 * To restore tester distribution: re-add the
 * `debugImplementation("com.google.firebase:firebase-appdistribution:…")` line
 * in `android/app/build.gradle.kts`, then reinstate the SDK call below
 * (`FirebaseAppDistribution.getInstance().updateIfNewReleaseAvailable()`).
 *
 * Kept as a separate file from `src/release` so [MainActivity] compiles in
 * either variant against the same `checkForUpdate(Activity)` signature.
 */
object AppDistributionUpdate {
    fun checkForUpdate(activity: Activity) {
        // No-op. See the class doc for why, and how to re-enable.
    }
}
