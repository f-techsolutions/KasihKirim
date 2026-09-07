# Claude Cloud Workflow

Use Claude as the implementation agent against the GitHub repository.

Rules:

1. Read the repository before coding.
2. Preserve `apps/mobile` as the reference Expo implementation until native parity is established.
3. Treat Supabase migrations, RLS, RPC signatures and tests as the backend source of truth.
4. Never invent database contracts.
5. Never place service-role secrets in Android.
6. After each coherent feature, run available tests and inspect the diff.
7. Commit logically and push to a feature branch.
8. Open a pull request.
9. GitHub Actions must pass before merge.
10. Merge only after the Android cloud build and backend verification gates pass.

Suggested Claude task:

"Inspect the repository and implement the next KasihKirim phase from the implementation plan. First prove the backend contract from migrations/tests, then implement the Kotlin/Compose feature. Do not invent RPCs, columns, enums or states. Run tests and make the smallest safe changes. Do not claim device verification unless a real Android device was tested."
