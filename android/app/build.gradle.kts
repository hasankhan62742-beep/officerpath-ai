import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key: create android/key.properties (see README § Build the AAB).
// NEVER commit key.properties or the .keystore file — both are git-ignored.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.qadeerautomations.officerpath"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // ota_update (v1.3) needs Java 8+ APIs — enable desugaring.
        // NOTE: Kotlin DSL maps the Java setter to
        // isCoreLibraryDesugaringEnabled; the Groovy-style
        // coreLibraryDesugaringEnabled does NOT resolve in .kts and
        // broke the CI build (29 Nov 2026: "Unresolved reference").
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.qadeerautomations.officerpath"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // v1.2: R8 obfuscation for release builds (minify + shrink).
            // Debug builds are unaffected. Verified by building a
            // release APK with a throwaway test keystore (see
            // AUDIT_REPORT.md § v1.2) — the app still launches and
            // the APK is not debuggable.
            isMinifyEnabled = true
            isShrinkResources = true
            // R8 rules (ML Kit dontwarn etc.) — without this the release
            // build fails at minifyReleaseWithR8 on missing optional
            // ML Kit script-recognizer classes (20 Nov 2026).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // AUDIT m5: a release build must NEVER silently fall back to
            // the debug key — a debug-signed AAB could be shipped to Play
            // by mistake. Fail fast when key.properties is missing; debug
            // builds are unaffected (they never run this branch).
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else if (gradle.startParameter.taskNames.any {
                it.contains("Release", ignoreCase = true)
            }) {
                throw GradleException(
                    "Release signing key missing: create android/key.properties " +
                    "(see README § Build the AAB). Refusing to sign a release " +
                    "build with the debug key."
                )
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ota_update (v1.3) needs Java 8+ APIs on older Android versions.
    // Must be 2.1.4+ — the ota_update AAR requires it (CI 20 Nov 2026:
    // checkDebugAarMetadata failed on 2.0.3).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
