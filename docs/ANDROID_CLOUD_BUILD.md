# Android Cloud Build

`.github/workflows/android-cloud-build.yml` builds the native `KasihKirimAndroid/`
app (Kotlin + Jetpack Compose) in GitHub Actions. No Android Studio or local
Android SDK is required to get a debug APK.

## When it runs

| Trigger | Purpose |
|---|---|
| `push` to `main` (paths: `KasihKirimAndroid/**`, this workflow file) | Build every change that lands on `main`. |
| `pull_request` targeting `main` (same paths) | PR gate: every pull request touching the Android app must build and pass its security gates before merge. |
| `workflow_dispatch` | Manual run from the Actions tab, any time. |

Runs for the same PR (or the same ref, for push/dispatch) supersede each
other: a new commit cancels the in-progress run for that PR via
`concurrency: android-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}`.

## Required GitHub secrets

Configure these once, under **Settings -> Secrets and variables -> Actions**:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`

The workflow writes them into a CI-generated `KasihKirimAndroid/local.properties`
(never committed — see `KasihKirimAndroid/local.properties.example` for the
local-dev equivalent). Only the **publishable** key belongs here: it is public
by design and useless without a valid user JWT, because Postgres Row Level
Security is the actual authorization boundary, not this key.

If either secret is missing, the build fails immediately with a clear error
rather than silently producing an APK with an empty Supabase config.

### Fork pull requests

**Pull requests from forks never see these secrets.** GitHub withholds
repository secrets from workflows triggered by a `pull_request` event coming
from a fork, so that a fork can't exfiltrate them via a crafted workflow
change. This is a GitHub platform restriction, not a bug in this workflow,
and it cannot be worked around from inside the workflow itself. When a fork
PR hits the "Configure Supabase build values" step, the failure message says
so explicitly and points at the fix: a maintainer must build the change from
a branch on the base repository (or trigger it manually via
`workflow_dispatch`) to get a real build and pass the gate.

## What the build does, in order

1. **Checkout** the repository.
2. **Java/Android setup** — JDK 17 (Temurin), Android SDK platform
   `android-37` and build-tools `37.0.0`, Gradle `9.6.0`.
3. **Configure Supabase build values** — writes `local.properties` from the
   `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` secrets (see above).
4. **Security gate — Android sources.** Scans `KasihKirimAndroid/` for
   key-shaped material (`sb_secret_...` service keys, JWT-shaped tokens,
   `SERVICE_ROLE`/`SERVICE_KEY` assignments, raw `postgres(ql)://` connection
   strings) and confirms `local.properties` was never committed. A match
   fails the build before anything is compiled.
5. **JVM tests** — `./gradlew test`, run before the APK is assembled so a
   broken change fails fast without spending time on a full Android build.
6. **Build debug APK** — `./gradlew :app:assembleDebug`.
7. **Security gate — APK.** Runs `strings` over the built APK and fails the
   build if any secret-shaped string (`service_role`, `sb_secret_`, a
   `postgres(ql)://` URI) made it into the packaged binary. This inspects the
   actual artifact, independent of gate 4.
8. **Upload the APK.**

Both security gates are hard failures — no workflow input weakens or skips
them, including on `workflow_dispatch` or `push`.

## Artifacts

| Artifact | When | Contents |
|---|---|---|
| `KasihKirim-debug-apk` | Every successful build | `app-debug.apk`, retained 14 days. |
| `KasihKirim-jvm-test-reports` | Only when JVM tests fail | The Gradle HTML/XML test reports (`app/build/reports/tests/`), retained 14 days, to speed up diagnosing the failure without re-running locally. |

## Getting the APK without Android Studio

1. Push `KasihKirim` to GitHub, with `SUPABASE_URL` and
   `SUPABASE_PUBLISHABLE_KEY` configured as repository secrets.
2. Open a pull request touching `KasihKirimAndroid/**` (or push to `main`, or
   run the workflow manually via **Actions -> KasihKirim Android Cloud
   Build -> Run workflow**).
3. Wait for the green build.
4. Open the workflow run and download the `KasihKirim-debug-apk` artifact.
5. Extract it and install `app-debug.apk` on an Android phone.
