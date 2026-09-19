import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Kotlin is built in (see android.builtInKotlin in gradle.properties), so
    // `kotlin-android` is no longer applied here.
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yourmateapps.pdfhelper"
    // Pinned ahead of flutter.compileSdkVersion (36): permission_handler_android
    // 14 compiles against SDK 37, and Gradle warns on every build until the app
    // matches the highest SDK its plugins need. Android SDKs are backward
    // compatible, so this does not change what the app runs on — targetSdk and
    // minSdk still follow Flutter.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Enable core library desugaring for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

}

// Kotlin 2.3 removed the string-valued `kotlinOptions.jvmTarget`; the
// compilerOptions DSL with a typed JvmTarget is the replacement. It lives
// outside the `android` block because it configures the Kotlin plugin, not AGP.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {

    // Release signing is configured only when android/key.properties exists.
    // Reading the properties unconditionally used to fail *every* build,
    // debug included, on a fresh clone with "null cannot be cast to
    // non-null type kotlin.String".
    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    val hasKeystore = keystorePropertiesFile.exists()
    if (hasKeystore) {
        FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yourmateapps.pdfhelper"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Required for flutter_local_notifications
        multiDexEnabled = true
    }

    buildTypes {
        debug {
            // Installs as com.yourmateapps.pdfhelper.debug, so a development
            // build can sit alongside the published app on the same phone
            // instead of demanding an uninstall (which would take the released
            // app's data with it). Everything that keys off applicationId —
            // the FileProvider authority, for one — follows automatically.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }

        release {
            // Without key.properties this falls through to the debug key, so
            // `flutter build apk --release` still produces an installable
            // (but unpublishable) APK instead of failing.
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "android/key.properties not found — signing the release " +
                        "build with the debug key. Do not publish this artifact."
                )
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring for flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
