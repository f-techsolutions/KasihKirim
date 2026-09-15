import java.util.Properties

// org.jetbrains.kotlin.android is intentionally not applied: AGP 9's
// built-in Kotlin support covers it, and the plugin now conflicts if applied.
// https://developer.android.com/build/migrate-to-built-in-kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Read the publishable Supabase config from local.properties, which is
// gitignored. Nothing secret goes here: the publishable key is public by
// design and useless without a valid JWT, because RLS is the boundary.
val localProps = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun localOr(key: String, fallback: String): String = localProps.getProperty(key) ?: fallback

// Release signing material. Never committed (see .gitignore), never routed
// through BuildConfig or local.properties defaults the way the Supabase
// publishable key is: a keystore password is an actual secret, not a public
// value. CI supplies these as environment variables from repository secrets;
// a developer who wants a local signed release build may set the same keys
// in local.properties instead (still gitignored). Any single missing value
// leaves the release build type unsigned -- R8 shrinking and the forbidden-
// secret gates still run against it, just without a distributable artifact.
fun secretEnvOrLocal(key: String): String? = System.getenv(key) ?: localProps.getProperty(key)
val releaseKeystorePath = secretEnvOrLocal("RELEASE_KEYSTORE_PATH")
val releaseKeystorePassword = secretEnvOrLocal("RELEASE_KEYSTORE_PASSWORD")
val releaseKeyAlias = secretEnvOrLocal("RELEASE_KEY_ALIAS")
val releaseKeyPassword = secretEnvOrLocal("RELEASE_KEY_PASSWORD")
val hasReleaseSigningConfig = !releaseKeystorePath.isNullOrBlank() &&
    !releaseKeystorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.ftechsolutions.kasihkirim"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.ftechsolutions.kasihkirim"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0-phase1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField("String", "SUPABASE_URL",
            "\"${localOr("SUPABASE_URL", "")}\"")
        buildConfigField("String", "SUPABASE_PUBLISHABLE_KEY",
            "\"${localOr("SUPABASE_PUBLISHABLE_KEY", "")}\"")

        // PKCE deep link. Must match [auth] additional_redirect_urls in
        // supabase/config.toml: kasihkirim://auth/callback
        manifestPlaceholders["authScheme"] = "kasihkirim"
        manifestPlaceholders["authHost"] = "auth"
    }

    if (hasReleaseSigningConfig) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Absent when the RELEASE_KEYSTORE_* secrets aren't set (e.g. a
            // PR build): the R8-shrunk release build type still exists for
            // verification, it just isn't distributable. See docs/RELEASE_SIGNING.md.
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true; buildConfig = true }
    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

// Top-level, not nested inside android {} -- that nested-call convenience
// was provided by the kotlin-android plugin, which is no longer applied.
kotlin { jvmToolchain(17) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.compose)
    implementation(libs.androidx.lifecycle.vm)
    implementation(libs.androidx.navigation)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.graphics)
    implementation(libs.compose.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    debugImplementation(libs.compose.tooling)

    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.supabase.storage)
    implementation(libs.supabase.functions)
    implementation(libs.supabase.realtime)
    implementation(libs.ktor.okhttp)
    implementation(libs.androidx.browser)
    implementation(libs.play.services.location)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)

    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.espresso.core)
    androidTestImplementation(libs.compose.test.junit4)
    debugImplementation(libs.compose.test.manifest)
}
