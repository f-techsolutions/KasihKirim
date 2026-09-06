#!/usr/bin/env bash
set -euo pipefail

FILE="supabase/tests/02_rls.test.sql"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found."
  echo "Run this script from the KasihKirim repository root."
  exit 1
fi

python - <<'PY'
from pathlib import Path

p = Path("supabase/tests/02_rls.test.sql")
s = p.read_text(encoding="utf-8")

old = """SELECT is(
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

new = """WITH changed AS (
  UPDATE public.kirim_requests
  SET budget_cap_sen = 1
  WHERE reference_code = 'KK-TEST01'
  RETURNING id
)
SELECT is(
  (SELECT count(*) FROM changed),
  0::bigint,
  'requester cannot edit a POSTED kirim (drafts only)'
);"""

if old not in s:
    print("ERROR: Expected broken test block was not found.")
    print("The file may already have been changed.")
    raise SystemExit(1)

p.write_text(s.replace(old, new, 1), encoding="utf-8", newline="\n")

print("SUCCESS: RLS test #14 syntax fixed.")
PY

echo
echo "Checking test #14:"
grep -n -A14 -B2 "WITH changed AS" "$FILE"

echo
echo "Running Supabase database tests..."
supabase test db