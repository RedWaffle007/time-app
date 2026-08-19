# ---------------------------------------------------------------------------
# Spike release build. Diagnosed on-device 2026-08-19 against the Redmi.
#
# The crash was NOT "R8 stripped a class" — `androidx.work.impl.WorkDatabase`
# and `WorkDatabase_Impl` both survive R8 unrenamed (confirmed in mapping.txt).
# What R8 removed was the generated impl's **no-arg constructor**: Room creates
# it reflectively, R8 sees no caller, and drops the member while keeping the
# class. Room then fails at `newInstance()` — hence "Failed to create an
# instance of class androidx.work.impl.WorkDatabase", thrown inside
# WorkManagerInitializer, inside androidx.startup's InitializationProvider,
# during ContentProvider install — i.e. before any of our code runs, which is
# why it presented as an unavoidable launch crash.
#
# `-keep class X` alone is not enough for anything instantiated reflectively.
# The members matter, and the constructor most of all.
# ---------------------------------------------------------------------------

-keep class androidx.work.impl.WorkDatabase { *; }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(); *; }
-keep @androidx.room.Database class * { *; }
-keep class androidx.room.RoomDatabase { *; }

# The DAO impls Room resolves by name from the database impl.
-keep class androidx.work.impl.model.** { *; }

# Workers are instantiated reflectively from a class name string. Ours would
# fail exactly the same way, and it would fail LATE — at fire time, in the
# middle of an overnight run, which is the worst possible moment to discover it.
-keep class * extends androidx.work.Worker { <init>(android.content.Context, androidx.work.WorkerParameters); }
-keep class com.timeapp.alarm_spike.SpikeWorker { *; }

# Our receivers are referenced from the manifest, not from code.
-keep class com.timeapp.alarm_spike.AlarmReceiver { *; }
-keep class com.timeapp.alarm_spike.BootReceiver { *; }

-dontwarn androidx.work.**
-dontwarn androidx.room.**
