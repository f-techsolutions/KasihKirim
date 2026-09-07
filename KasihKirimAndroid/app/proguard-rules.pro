# Supabase Kotlin SDK uses kotlinx.serialization; keep generated serializers.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class com.ftechsolutions.kasihkirim.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.ftechsolutions.kasihkirim.**$$serializer { *; }

# Ktor / OkHttp
-dontwarn okhttp3.**
-dontwarn org.conscrypt.**
-keepclassmembers class io.ktor.** { volatile <fields>; }

# Never let an obfuscation rule strip the log-scrubbing guard.
-keep class com.ftechsolutions.kasihkirim.core.security.SafeLog { *; }
