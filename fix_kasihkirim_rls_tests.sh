#!/usr/bin/env bash
set -euo pipefail

echo "== KasihKirim: fix RLS tests =="

TEST="supabase/tests/02_rls.test.sql"
HELPER="supabase/test_helpers/00_helpers.sql"
OLD_HELPER="supabase/testing/00_helpers.sql"

if [ ! -f "$TEST" ]; then
  echo "ERROR: $TEST not found. Run this from the KasihKirim repository root."
  exit 1
fi

# Fix test #14: RLS blocks the POSTED row, so the UPDATE affects 0 rows.
python - <<'PY'
from pathlib import Path
p = Path("supabase/tests/02_rls.test.sql")
s = p.read_text(encoding="utf-8")

old = """SELECT throws_ok(
  $$UPDATE public.kirim_requests SET budget_cap_sen = 1
    WHERE reference_code='KK-TEST01'$$,
  NULL, NULL, 'requester cannot edit a POSTED kirim (drafts only)');"""

new = """SELECT is(
  (
    WITH changed AS (
      UPDATE public.kirim_requests
      SET budget_cap_sen = 1
      WHERE reference_code = 'KK-TEST01'
      RETURNING id
    )
    SELECT count(*) FROM changed
  ),
  0::bigint,
  'requester cannot edit a POSTED kirim (drafts only)'
);"""

if old in s:
    s = s.replace(old, new, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print("OK: fixed RLS test #14")
elif "requester cannot edit a POSTED kirim (drafts only)" in s and "WITH changed AS" in s:
    print("OK: RLS test #14 already fixed")
else:
    print("ERROR: could not find test #14 block.")
    raise SystemExit(1)
PY

# Keep one canonical helper outside supabase/tests.
if [ -f "$OLD_HELPER" ]; then
  rm "$OLD_HELPER"
  echo "OK: removed duplicate helper: $OLD_HELPER"
fi
if [ -d "supabase/testing" ] && [ -z "$(find supabase/testing -type f -print -quit 2>/dev/null)" ]; then
  rmdir supabase/testing || true
fi

if [ ! -f "$HELPER" ]; then
  echo "ERROR: canonical helper missing: $HELPER"
  exit 1
fi

# Update CI/scripts if they still reference the old helper path.
python - <<'PY'
from pathlib import Path
for root in [Path(".github"), Path("scripts")]:
    if not root.exists():
        continue
    for p in root.rglob("*"):
        if p.is_file():
            try:
                s = p.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            ns = s.replace(
                "supabase/testing/00_helpers.sql",
                "supabase/test_helpers/00_helpers.sql"
            )
            if ns != s:
                p.write_text(ns, encoding="utf-8", newline="\n")
                print(f"OK: updated {p}")
PY

echo
echo "== Admin authentication helper =="
grep -n -A55 -B5 "CREATE OR REPLACE FUNCTION tests.authenticate_as" "$HELPER" || true

echo
echo "== CI/test helper references =="
grep -R "testing/00_helpers\|test_helpers/00_helpers\|supabase test db" -n .github scripts 2>/dev/null || true

echo
echo "== Git diff =="
git diff -- "$TEST" "$HELPER" .github scripts 2>/dev/null || true

echo
echo "== Running database tests =="
if ! command -v supabase >/dev/null 2>&1; then
  echo "ERROR: Supabase CLI not found in PATH."
  exit 1
fi

supabase test db
