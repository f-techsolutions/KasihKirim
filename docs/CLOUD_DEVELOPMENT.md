# KasihKirim Cloud-First Development

## Goal

Develop and build the Android app without installing Android Studio on the laptop.

## Stack

- Claude Code / Claude as development agent
- GitHub as source control
- GitHub Actions as Android cloud build
- Supabase as backend
- Native Kotlin + Jetpack Compose as production Android client
- Physical Android phone for final manual testing

## One-time GitHub secrets

Repository Settings -> Secrets and variables -> Actions -> New repository secret:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`

Never add a service-role key. Never commit `local.properties`.

## Cloud build

Push changes to `main`, or open Actions -> KasihKirim Android Cloud Build -> Run workflow.

The workflow installs JDK 17 and Android SDK 37 on GitHub's cloud runner, generates the Gradle wrapper, builds the APK, runs JVM tests and uploads `KasihKirim-debug-apk` as an artifact.

## Download APK

GitHub -> Actions -> successful `KasihKirim Android Cloud Build` run -> Artifacts -> `KasihKirim-debug-apk`.

Extract the artifact and install `app-debug.apk` on an Android phone.

## Important limitation

GitHub Actions builds and tests the project in the cloud. It does not replace real-device testing. Authentication, navigation, permissions, connectivity, offline behavior and business workflows must still be exercised on an actual Android phone.
