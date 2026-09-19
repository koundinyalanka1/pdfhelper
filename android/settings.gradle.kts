pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    // Declared, never applied. Built-in Kotlin otherwise compiles with the
    // KGP that AGP 9.1 bundles (2.2.10), which is below Flutter's 2.2.20
    // minimum; naming a version here is what raises it.
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
