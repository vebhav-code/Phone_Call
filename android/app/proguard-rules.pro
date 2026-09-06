# Flutter WebRTC Proguard Rules
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Keep WebRTC JNI native methods and annotations
-keepattributes *Annotation*
-keepclassmembers class * {
    @org.webrtc.CalledByNative *;
}
