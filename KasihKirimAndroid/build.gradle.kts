// org.jetbrains.kotlin.android is intentionally not applied: AGP 9's
// built-in Kotlin support covers it, and the plugin now conflicts if applied.
// https://developer.android.com/build/migrate-to-built-in-kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
