package com.timeapp.time_app

import android.app.Activity
import com.google.firebase.appdistribution.FirebaseAppDistribution

/**
 * DEBUG variant. Asks Firebase App Distribution whether a newer tester build
 * exists and, if so, shows the in-app "New version available" dialog — signing
 * the tester in (a one-time Google prompt) on the first check. Called from
 * [MainActivity.onResume], so every foreground re-checks.
 *
 * This file exists ONLY in the debug source set. The App Distribution SDK must
 * never ship to Google Play, so release builds compile against the no-op copy in
 * `src/release`. Both copies expose the same `checkForUpdate(Activity)` so the
 * shared MainActivity compiles in either variant.
 */
object AppDistributionUpdate {
    fun checkForUpdate(activity: Activity) {
        // Fire-and-forget: the SDK owns the sign-in + update dialog UI. Failures
        // (offline, tester not enrolled) are surfaced by the SDK, not fatal.
        FirebaseAppDistribution.getInstance().updateIfNewReleaseAvailable()
    }
}
