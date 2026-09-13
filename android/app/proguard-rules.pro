# The Rust core is reached through dart:ffi by symbol name, not through JNI,
# so R8 never sees a reference to it. Keep the plugin's classes so the .so
# stays bundled and loadable.
-keep class com.yourmateapps.flutter_pdf_core.** { *; }

# Flutter deferred components / Play Core are referenced by the embedding but
# are not present in a plain APK build.
-dontwarn com.google.android.play.core.**

# flutter_local_notifications keeps its scheduled-notification models via
# reflection when the app is woken by the OS.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
