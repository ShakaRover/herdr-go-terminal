plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues =
    mapOf(
        "ANDROID_KEYSTORE_FILE" to System.getenv("ANDROID_KEYSTORE_FILE"),
        "ANDROID_KEYSTORE_PASSWORD" to System.getenv("ANDROID_KEYSTORE_PASSWORD"),
        "ANDROID_KEY_ALIAS" to System.getenv("ANDROID_KEY_ALIAS"),
        "ANDROID_KEY_PASSWORD" to System.getenv("ANDROID_KEY_PASSWORD"),
    )
val missingReleaseSigningValues =
    releaseSigningValues.filterValues { it.isNullOrBlank() }.keys
val releaseBuildRequested =
    gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }

if (releaseBuildRequested) {
    require(missingReleaseSigningValues.isEmpty()) {
        "Release signing is not configured; missing: ${missingReleaseSigningValues.joinToString()}"
    }
    require(file(releaseSigningValues.getValue("ANDROID_KEYSTORE_FILE")!!).isFile) {
        "ANDROID_KEYSTORE_FILE does not point to a file"
    }
}

android {
    namespace = "dev.herdr.herdrgo"
    compileSdk = flutter.compileSdkVersion
    // EasyTier JNI is built with this NDK locally and in release CI.
    ndkVersion = "28.2.13676358"

    val releaseSigningConfig =
        if (missingReleaseSigningValues.isEmpty()) {
            signingConfigs.create("release") {
                storeFile = file(releaseSigningValues.getValue("ANDROID_KEYSTORE_FILE")!!)
                storePassword = releaseSigningValues.getValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = releaseSigningValues.getValue("ANDROID_KEY_ALIAS")
                keyPassword = releaseSigningValues.getValue("ANDROID_KEY_PASSWORD")
            }
        } else {
            null
        }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 需要。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.herdr.herdrgo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = releaseSigningConfig
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
