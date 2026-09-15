# ──────────────────────────────────────────────────────────────────
# Flutter / Dart AOT
# ──────────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# ──────────────────────────────────────────────────────────────────
# Firebase core & FCM
# The background-message isolate is launched by FlutterFirebaseMessagingService.
# R8 must not rename or remove any of these classes.
# ──────────────────────────────────────────────────────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# FlutterFire Messaging service (background handler entry point)
-keep class io.flutter.plugins.firebase.messaging.** { *; }
-keep class com.google.firebase.messaging.FirebaseMessagingService { *; }

# ──────────────────────────────────────────────────────────────────
# flutter_local_notifications
# ──────────────────────────────────────────────────────────────────
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# ──────────────────────────────────────────────────────────────────
# General safety
# ──────────────────────────────────────────────────────────────────
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception
