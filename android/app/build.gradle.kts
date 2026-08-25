plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
    debugImplementation("com.google.firebase:firebase-appdistribution:16.0.0-beta20")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
