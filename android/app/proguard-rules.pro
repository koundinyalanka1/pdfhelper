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

# Room builds its database by reflection:
# `Class.forName(name + "_Impl").getDeclaredConstructor().newInstance()`.
#
# room-runtime 2.2.5 — the version AdMob drags in through
# play-services-ads-api -> androidx.work:work-runtime:2.7.0 — ships the
# consumer rule `-keep class * extends androidx.room.RoomDatabase`, which
# keeps the class but lets R8 delete its no-arg constructor. That was fine
# under the old ProGuard-compatible shrinker; under R8 full mode (the default
# since AGP 8) the constructor goes, and WorkManager's androidx.startup
# initializer then kills the app on launch with "Failed to create an instance
# of androidx.work.impl.WorkDatabase" — release builds only.
#
# Room fixed its own rule in later versions by adding the member spec below.
# Until the Ads SDK moves to one of those, the app supplies it.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
