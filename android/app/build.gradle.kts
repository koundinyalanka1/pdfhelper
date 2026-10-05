import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // Kotlin is built in (see android.builtInKotlin in gradle.properties), so
    // `kotlin-android` is no longer applied here.
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI can keep credentials outside the checkout. Never fall back to a debug key
// for a release artifact; missing credentials must still allow debug builds.
val releaseKeystorePropertiesFile = rootProject.file(
    providers.gradleProperty("signingPropertiesFile").orElse("key.properties").get()
)
val releaseKeystoreProperties = Properties()
if (releaseKeystorePropertiesFile.isFile) {
    FileInputStream(releaseKeystorePropertiesFile).use { releaseKeystoreProperties.load(it) }
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

    signingConfigs {
        if (releaseKeystorePropertiesFile.isFile) {
            create("release") {
                keyAlias = releaseKeystoreProperties.getProperty("keyAlias")
                keyPassword = releaseKeystoreProperties.getProperty("keyPassword")
                storeFile = releaseKeystoreProperties.getProperty("storeFile")
                    ?.takeIf { it.isNotBlank() }?.let { file(it) }
                storePassword = releaseKeystoreProperties.getProperty("storePassword")
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
        // The exporter checks use Android's built-in instrumentation API;
        // there are no additional test dependencies or release permissions.
        testInstrumentationRunner = "com.yourmateapps.pdfhelper.PublicPdfExporterInstrumentation"
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
            signingConfig = signingConfigs.findByName("release")
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

// The bundled Firebase client is the production application ID. A debug build
// has a separate ID and deliberately runs without production crash reporting.
// Register that ID in Firebase and add src/debug/google-services.json to opt in.
tasks.matching { it.name == "processDebugGoogleServices" }.configureEach {
    enabled = file("src/debug/google-services.json").exists()
}

val verifyPdfCore by tasks.registering {
    doLast {
        val root = rootProject.file("../packages/flutter_pdf_core/android/src/main/jniLibs")
        for (abi in listOf("arm64-v8a", "armeabi-v7a", "x86_64")) {
            check(root.resolve("$abi/libpdf_ffi.so").isFile) {
                "PDF engine missing for $abi. Run bash scripts/build_pdf_core.sh android before building."
            }
        }
    }
}
tasks.named("preBuild").configure { dependsOn(verifyPdfCore) }

val verifyReleaseSigning by tasks.registering {
    doLast {
        check(releaseKeystorePropertiesFile.isFile) {
            "Release signing is required. Provide android/key.properties or " +
                "-PsigningPropertiesFile=/path/to/key.properties. Use a debug build for local testing."
        }
        for (name in listOf("keyAlias", "keyPassword", "storeFile", "storePassword")) {
            check(!releaseKeystoreProperties.getProperty(name).isNullOrBlank()) {
                "Release signing configuration is missing $name."
            }
        }
        check(file(releaseKeystoreProperties.getProperty("storeFile")).isFile) {
            "Release signing keystore does not exist. Check storeFile in the signing configuration."
        }
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyReleaseSigning)
}

// Local validation builds do not contact Crashlytics to publish symbols.
// Opt in from the release pipeline with -PuploadCrashlytics=true.
tasks.matching { it.name.startsWith("uploadCrashlytics") }.configureEach {
    onlyIf { providers.gradleProperty("uploadCrashlytics").orNull == "true" }
}
