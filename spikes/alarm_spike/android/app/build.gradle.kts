plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.timeapp.alarm_spike"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.timeapp.alarm_spike"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signing with the debug keys — this is a throwaway spike, never shipped.
            signingConfig = signingConfigs.getByName("debug")

            // Flutter enables R8 for release builds by default (a mapping.txt is
            // produced even with no minify block here), and R8 is what removed
            // Room's generated constructor and crashed the app on launch.
            //
            // Turned OFF outright, on purpose. This rig measures when the OS
            // delivers an alarm; it is not a release-hygiene test, its APK size
            // is irrelevant, and every byte R8 saves buys nothing but a new way
            // for the harness to fail at 3am. proguard-rules.pro is kept and
            // wired up anyway so the build still works if this is flipped back.
            //
            // NOTE this does NOT weaken the "test in release, not debug" rule:
            // the build is still a release build, still not debuggable, and so
            // still gets normal OEM battery treatment. That was the only reason
            // release mattered here.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The WorkManager arm of the comparison. DECISIONS.md names WorkManager as
    // the durable substrate for the reminder layer; this spike is where that
    // claim gets a number next to it instead of a citation.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
