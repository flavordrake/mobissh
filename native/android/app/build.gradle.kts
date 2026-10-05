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
// builds come out UNSIGNED (#1277); sign them separately with apksigner.
val keystorePropertiesFile = file(
    System.getenv("MOBISSH_KEY_PROPERTIES")
        ?: "/home/dev/.mobissh-android/key.properties"
)
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

// #1216 R13: a bundle build is the Play build (build-release-aab.sh is the only
// caller; sideload ships split APKs via assembleRelease). Keyed on the task
// name rather than a new product flavor: a flavor would rename every APK
// output path the ship scripts and the integration runner depend on, and a
// -P flag could be forgotten — `flutter build appbundle` always runs a
// bundle* task, so the Play build cannot come out with the updater in it.
val isPlayBundle = gradle.startParameter.taskNames.any {
    it.contains("bundle", ignoreCase = true)
}

android {
    namespace = "com.flavordrake.mobissh"

    sourceSets {
        if (isPlayBundle) {
            // tools:node="remove" for REQUEST_INSTALL_PACKAGES + the updater
            // FileProvider. The release source set has no manifest of its own.
            getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
        }
    }
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
            // #1277: no key.properties -> UNSIGNED, never debug-signed. The
            // buildbox builds keyless and the signer (apksigner today, the
            // isolated homelab#44 signer next) is the only thing that signs a
            // release; a debug fallback made a debug-signed APK look shippable.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
            // R8 runs on the shipped release build (proven by the #915
            // Gson/TypeToken crash from flutter_local_notifications). Make
            // minification explicit and attach the keep rules so they apply to
            // that R8 pass — without them, R8 strips the generic Signature
            // attribute Gson needs and notification cancel throws at runtime.
            isMinifyEnabled = true
            isShrinkResources = true
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
    // Backports java.time etc. so flutter_local_notifications builds on
    // minSdk < 26 (coreLibraryDesugaringEnabled above).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // #1216: FileProvider for the self-update hand-off. Already on the runtime
    // classpath via plugins (url_launcher/share_plus pull core 1.13-1.15);
    // declared so app code can compile against it. No version bump results.
    implementation("androidx.core:core:1.13.1")
}
