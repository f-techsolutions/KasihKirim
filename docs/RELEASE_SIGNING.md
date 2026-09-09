# KasihKirimAndroid — Release Signing

Scope note: `docs/DEPLOYMENT.md` was originally written for the Expo/EAS
pipeline of the `apps/mobile/` React Native app, predating
`docs/CLAUDE_IMPLEMENTATION_PLAN.md` §0.1's decision to build a native
Kotlin app instead (`KasihKirimAndroid/`), and names a different package
(`my.kasihkirim.app`) than the one actually shipped since Phase 1
(`com.ftechsolutions.kasihkirim`, set in `app/build.gradle.kts`). Its §8
(mobile build pipeline), §9 (OTA — doesn't apply natively), §10.2 (API
levels), §11 (secrets), §12's mobile crash-reporting row, and §15 (release
cadence) have since been corrected in place to describe the real native
build. Its Vercel/admin-console, Supabase environment, and e2e/Maestro
content was not re-verified and may still be stale — this document stays
scoped to signing specifically.

## What's already wired

`app/build.gradle.kts`'s `release` build type has had R8 minification and
resource shrinking on since Phase 1 (`isMinifyEnabled = true`,
`isShrinkResources = true`), with `proguard-rules.pro` covering
kotlinx.serialization, Ktor/OkHttp, and `SafeLog`. What was missing was a
signing config — Phase 10 adds it, conditionally:

```kotlin
val hasReleaseSigningConfig = /* all four of the values below are set */
if (hasReleaseSigningConfig) {
    signingConfigs { create("release") { ... } }
}
release {
    if (hasReleaseSigningConfig) signingConfig = signingConfigs.getByName("release")
}
```

Four values, read from environment variables first and `local.properties`
second (same fallback order the Supabase config already uses, `local.properties`
is gitignored either way):

| Variable | Value |
|---|---|
| `RELEASE_KEYSTORE_PATH` | Path to the `.jks`/`.keystore` file, resolved relative to `KasihKirimAndroid/` |
| `RELEASE_KEYSTORE_PASSWORD` | The keystore's store password |
| `RELEASE_KEY_ALIAS` | The signing key's alias inside that keystore |
| `RELEASE_KEY_PASSWORD` | That key's own password |

Any one missing leaves `release` **unminified-signing-config-absent**: R8
still runs, `.github/workflows/android-cloud-build.yml`'s two forbidden-secret
gates still apply, but the resulting APK/AAB has no signature and cannot
be installed or uploaded to Play. This is deliberate — a PR build (which
never sees repository secrets when it comes from a fork) still exercises
R8 shrinking without ever needing the real signing key.

## Generating the keystore (you hold this, not Claude)

```bash
keytool -genkeypair -v \
  -keystore kasihkirim-release.jks \
  -alias kasihkirim \
  -keyalg RSA -keysize 4096 -validity 10950 \
  -storetype JKS
```

`-validity 10950` is 30 years — Play requires the signing certificate to
outlive the app itself; a shorter validity is a real, hard-to-recover-from
mistake. Store the resulting `.jks`, its store password, the alias, and
the key password somewhere durable outside this repository (a password
manager, per `DEPLOYMENT.md` §8.2's equivalent guidance for the Expo-era
upload key) — losing all four means losing the ability to ship an update
to the same `applicationId` ever again.

Whether to enroll in **Play App Signing** (Google holds the app signing
key; you upload with a separate, replaceable upload key) or self-manage
signing entirely is a Play Console decision at first upload, not
something this repository's CI needs to know about — either way, CI signs
with whatever keystore these four secrets point to.

## Wiring it into GitHub Actions

Add these as repository secrets (Settings → Secrets and variables →
Actions), matching how `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` are
already stored there:

- `RELEASE_KEYSTORE_BASE64` — `base64 -i kasihkirim-release.jks | pbcopy` (or `base64 -w0` on Linux), the whole keystore file as one base64 blob. GitHub secrets don't hold binary well; the release workflow decodes this back to a file at build time.
- `RELEASE_KEYSTORE_PASSWORD`
- `RELEASE_KEY_ALIAS`
- `RELEASE_KEY_PASSWORD`

`.github/workflows/android-release-build.yml` (manual `workflow_dispatch`
only — it never runs on a PR or a push) decodes `RELEASE_KEYSTORE_BASE64`
into a temporary file, exports it as `RELEASE_KEYSTORE_PATH`, and passes
the other three straight through as env vars before running
`./gradlew :app:bundleRelease`. The temp keystore file lives only inside
that one runner's ephemeral filesystem and is never uploaded as an
artifact or written to the repository.

## What Phase 10 does NOT cover

- **Play Store listing content** (screenshots, description, privacy
  policy, Data Safety form) — business/design content this repository
  can't fabricate. `DEPLOYMENT.md` §10 has the Expo-era version of this
  checklist; it needs a native-build pass before it's trustworthy for
  this app.
- **Publishing to Play** — the release workflow produces a signed AAB
  artifact for you to upload manually. Automating `eas submit`-equivalent
  publishing would need a Play service account JSON this repository does
  not have and hasn't been asked to add.
- ~~**`applicationId` decision**~~ — **decided**: `com.ftechsolutions.kasihkirim`
  is the production identity. It's what's actually been built, tested,
  signed, and shipped since Phase 1; `my.kasihkirim.app` was only ever
  present in the pre-pivot Expo/EAS `DEPLOYMENT.md`, superseded by
  `docs/CLAUDE_IMPLEMENTATION_PLAN.md` §0.1's move to native Kotlin, and
  was never wired into any actual build. Switching now would mean
  reconfiguring and re-verifying everything already proven working, for
  no benefit — and a package name cannot be changed after the first Play
  upload, so this is now closed rather than left open.
