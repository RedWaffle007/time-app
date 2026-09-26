import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The real keystore + passwords live in android/key.properties,
// which is gitignored (never committed) — see android/key.properties.example for
// the shape. When the file is ABSENT (fresh clone, CI without secrets) we fall
// back to debug signing so `flutter run --release` still works locally; a store
// build MUST have the file. `hasReleaseKeystore` gates the buildType below.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.timeapp.time_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // REQUIRED BY flutter_local_notifications (v10+). The plugin's scheduling
        // path uses `java.time`, which does not exist below API 26; desugaring is
        // what back-fills it on our minSdk 23. Without this the build fails
        // outright — it is not an optimisation.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.timeapp.time_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Firebase Auth 6.x requires at least API 23.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Desugaring pushes the method count up; multidex keeps a debug build on
        // API 23-24 (pre-native-multidex) from failing to install.
        multiDexEnabled = true
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release keystore when key.properties is present;
            // otherwise fall back to debug so a local `flutter run --release` still
            // installs. A Play Store build REQUIRES key.properties — a debug-signed
            // release is not shippable and its SHA-1 differs from the release cert.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // The desugared java.time (and friends) implementation. Version is the one
    // flutter_local_notifications 22.x documents as its minimum.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Firebase App Distribution — the in-app "new version available" prompt for
    // tester builds. DEBUG ONLY, and this is not optional: the full
    // `firebase-appdistribution` SDK self-downloads/installs APKs, which Google
    // Play policy forbids in a shipped app. It exists only in the debug variant;
    // release builds compile against the no-op `AppDistributionUpdate` in
    // src/release. (`-api` is the lightweight feedback SDK and does NOT show the
    // update dialog, so it is deliberately not the one used here.)
    //
    // VERSION IS PINNED EXPLICITLY, on purpose: the full App Distribution SDK is
    // a BETA library and is NOT part of `firebase-bom` (the BoM covers only GA
    // libraries), so a versionless `firebase-appdistribution` resolves to an
    // EMPTY version and fails `:app:mergeDebugAssets`. A BoM does nothing for it.
    // 16.0.0-beta20 is the latest published on Google's Maven (dl.google.com).
    // See DECISIONS.md "Firebase App Distribution (2026-08-24)".
    //
    // DISABLED 2026-08-27: even with our own `updateIfNewReleaseAvailable()` call
    // gated off, merely COMPILING this SDK into the debug build makes it
    // auto-initialize (via its own ContentProvider) and post the "enable
    // tester/in-app features" prompt on its own — the never-ending popup. Removed
    // from the build so the SDK isn't present at all; the debug
    // `AppDistributionUpdate` is a no-op like release. Re-add this line (and
    // restore the SDK call in src/debug/AppDistributionUpdate.kt) for a
    // deliberate tester-distribution session.
    // debugImplementation("com.google.firebase:firebase-appdistribution:16.0.0-beta20")

    // App-owned native regression tests. Keep this deliberately to plain JUnit:
    // the alarm state machines below are pure Kotlin, so they do not need a
    // simulated Android runtime. That also avoids coupling our suite to the
    // Robolectric/host-JDK mismatch in flutter_local_notifications' own tests.
    testImplementation("junit:junit:4.13.2")
    // The real org.json for JVM unit tests (Android's is a stub there): the
    // alarm reboot store's codec is tested against it (item 32c-2).
    testImplementation("org.json:json:20240303")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
