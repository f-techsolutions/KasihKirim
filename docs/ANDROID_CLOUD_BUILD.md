# Android Cloud Build Quick Start

1. Push `KasihKirim` to GitHub.
2. In GitHub: Settings -> Secrets and variables -> Actions.
3. Add `SUPABASE_URL`.
4. Add `SUPABASE_PUBLISHABLE_KEY`.
5. Go to Actions.
6. Select `KasihKirim Android Cloud Build`.
7. Click `Run workflow`.
8. Wait for the green build.
9. Open the workflow run.
10. Download artifact `KasihKirim-debug-apk`.
11. Extract it.
12. Install `app-debug.apk` on the Android phone.

No Android Studio is required on the laptop for this workflow.
