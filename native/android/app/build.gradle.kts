import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Key material lives OUTSIDE the repo per
// .claude/rules/security.md — never commit storePassword / keyPassword.
// Default location: /home/dev/.mobissh-android/key.properties. Override
// with MOBISSH_KEY_PROPERTIES env var. If the file is missing, release
// builds fall through to the debug keystore (so `flutter run --release`
// still works in dev).
val keystorePropertiesFile = file(
    System.getenv("MOBISSH_KEY_PROPERTIES")
        ?: "/home/dev/.mobissh-android/key.properties"
)
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.flavordrake.mobissh"
    // #960: the file-picker plugin set pulls a flutter_plugin_android_lifecycle
    // AAR that requires consumers to compile against API 36+. Pin compileSdk to
    // 36 (was the Flutter default 34). compileSdk only widens the APIs available
    // at compile time — targetSdk/minSdk (runtime behavior / device floor) are
    // unchanged below.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (uses java.time on minSdk < 26).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.flavordrake.mobissh"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
    // Backports java.time etc. so flutter_local_notifications builds on
    // minSdk < 26 (coreLibraryDesugaringEnabled above).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
