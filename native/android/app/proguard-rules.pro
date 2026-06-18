# R8/ProGuard keep rules for the MobiSSH native release build.
#
# flutter_local_notifications + Gson (#915):
# The plugin serializes scheduled-notification metadata with Gson, which uses
# reflective TypeToken<...> instances. R8 (release-only) strips the generic
# `Signature` attribute that Gson needs to reconstruct those types, so
# FlutterLocalNotificationsPlugin.cancel -> loadScheduledNotifications throws
#   PlatformException: TypeToken must be created with a type argument ...
# These are the documented flutter_local_notifications R8 rules.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.dexterous.** { *; }
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
