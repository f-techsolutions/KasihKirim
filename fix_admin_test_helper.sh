#!/usr/bin/env bash
set -euo pipefail

FILE="supabase/test_helpers/00_helpers.sql"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found."
  echo "Run this from the KasihKirim repository root."
  exit 1
fi

python - <<'PY'
from pathlib import Path

p = Path("supabase/test_helpers/00_helpers.sql")
s = p.read_text(encoding="utf-8")

old = """CREATE OR REPLACE FUNCTION tests.authenticate_as(p_handle TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$"""

new = """CREATE OR REPLACE FUNCTION tests.authenticate_as(p_handle TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, tests, pg_temp
AS $$"""

if old not in s:
    if "CREATE OR REPLACE FUNCTION tests.authenticate_as(p_handle TEXT)" in s and "SECURITY DEFINER" in s:
        print("OK: authenticate_as is already SECURITY DEFINER.")
    else:
        print("ERROR: authenticate_as function definition not found.")
        raise SystemExit(1)
else:
    p.write_text(s.replace(old, new, 1), encoding="utf-8", newline="\n")
    print("SUCCESS: authenticate_as() changed to SECURITY DEFINER.")

PY

echo
echo "Checking helper:"
grep -n -A22 -B3 "CREATE OR REPLACE FUNCTION tests.authenticate_as" "$FILE"

echo
echo "Running Supabase tests..."
supabase test db