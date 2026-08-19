package com.timeapp.alarm_spike

import android.app.Application
import android.util.Log
import androidx.work.Configuration

/**
 * Exists for exactly one reason: to let WorkManager initialise itself in a
 * process the OS cold-started to run a job.
 *
 * THE BUG THIS FIXES (found 2026-08-19, from a real run that produced three
 * `SCHEDULED,WORKMANAGER` rows and zero `FIRED,WORKMANAGER` rows):
 *
 * Removing `WorkManagerInitializer` from androidx.startup stopped the launch
 * crash, but it also removed the ONLY thing that initialised WorkManager. The
 * lazy init in AlarmScheduler covers the case where our own UI enqueues work —
 * and nothing else. When the alarm's actual fire time arrives the app is dead
 * by design; the system starts the process to run `SystemJobService`, no
 * activity is created, `AlarmScheduler` is never touched, WorkManager is
 * therefore uninitialised, and the worker silently never runs.
 *
 * Silently is the operative word: it produced no crash, no log line, and a
 * WORKMANAGER column full of blanks that reads exactly like "Xiaomi killed it."
 * A rig that manufactures a plausible wrong answer is worse than one that
 * crashes.
 *
 * `Configuration.Provider` is the documented on-demand path: WorkManager
 * initialises itself on first `getInstance()` in ANY process, including one the
 * job scheduler started. The crash-safety we wanted is kept — initialisation
 * now happens inside whichever component asked for it, not in a ContentProvider
 * during application startup, so a failure can no longer take down the launch.
 */
class SpikeApplication : Application(), Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setMinimumLoggingLevel(Log.INFO)
            .build()
}
