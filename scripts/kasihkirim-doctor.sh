#!/usr/bin/env bash
# ============================================================================
# KasihKirim — environment doctor
#
# Statuses:
#   PASS    tool present and executed successfully
#   FAIL    required tool missing or broken FOR THE SELECTED PROFILE
#   WARN    genuinely optional tool missing — not a failure
#   BLOCKED cannot be installed here (no registry/network egress)
#
# Never prints secrets: env vars are reported as SET/UNSET only.
# Never claims PASS without executing the tool.
#
# Usage: kasihkirim-doctor.sh [--profile=cloud|full]
#   cloud  backend verification gate only. Android tooling optional —
#          the cloud does NOT need an emulator (see DEVELOPMENT-ENVIRONMENT.md).
#   full   cloud + local Android build tooling.
# ============================================================================
set -uo pipefail

PROFILE="cloud"
for a in "$@"; do case "$a" in --profile=*) PROFILE="${a#*=}";; esac; done

P=0; F=0; W=0; B=0
NET_OK=1
row() { printf "  %-20s %-8s %s\n" "$1" "$2" "${3:-}"; }
pass()  { row "$1" "PASS" "${2:-}";    P=$((P+1)); }
fail()  { row "$1" "FAIL" "${2:-}";    F=$((F+1)); }
warn()  { row "$1" "WARN" "${2:-}";    W=$((W+1)); }
block() { row "$1" "BLOCKED" "${2:-}"; B=$((B+1)); }

# check <label> <cmd> <version-args> <required|optional>
check() {
  local label="$1" cmd="$2" varg="${3:-}" req="${4:-required}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$req" = "optional" ]; then warn "$label" "not installed (optional)"
    elif [ "$NET_OK" -eq 0 ]; then block "$label" "absent; no registry egress to install"
    else fail "$label" "not installed"; fi
    return 1
  fi
  pass "$label" "$($cmd $varg 2>&1 | head -1)"
}

echo "═══════════════════════════════════════════════════════════════"
echo " KasihKirim doctor — profile=$PROFILE — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "═══════════════════════════════════════════════════════════════"

echo; echo "NETWORK"
if command -v npm >/dev/null 2>&1 && npm ping >/dev/null 2>&1; then
  pass "npm registry" "reachable"
else
  NET_OK=0
  fail "npm registry" "unreachable — toolchain cannot be installed here"
fi

echo; echo "CORE"
check "Git"  git  --version
check "Node" node --version
check "npm"  npm  --version
# Node 20 LTS is the repository specification (.nvmrc). Node 22 is NOT
# equivalent and is reported as a mismatch, not silently accepted.
if command -v node >/dev/null 2>&1; then
  want="$(cat "$(dirname "${BASH_SOURCE[0]}")/../.nvmrc" 2>/dev/null | tr -d 'v \n')"
  have="$(node --version | tr -d 'v')"
  if [ "${have%%.*}" = "${want%%.*}" ]; then pass "Node version match" "$have matches .nvmrc major ${want%%.*}"
  else warn "Node version match" "have $have, .nvmrc wants $want — use nvm/fnm"; fi
fi

echo; echo "BACKEND  (required for the verification gate)"
check "Docker CLI" docker --version
# The single most important line in this script.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then pass "Docker daemon" "reachable"
  else fail "Docker daemon" "CLI present but daemon unreachable"; fi
else
  fail "Docker daemon" "no CLI — supabase start cannot run"
fi
check "Supabase CLI" supabase --version
check "psql"         psql     --version
check "Deno"         deno     --version

echo; echo "ANDROID  (build-only; emulator NOT required in cloud)"
ANDROID_REQ="optional"; [ "$PROFILE" = "full" ] && ANDROID_REQ="required"
check "Java"   java   -version "$ANDROID_REQ"
check "Gradle" gradle --version optional
if [ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then
  pass "Android SDK" "SET"     # path not printed
elif [ "$PROFILE" = "full" ]; then
  fail "Android SDK" "ANDROID_HOME/ANDROID_SDK_ROOT unset"
else
  warn "Android SDK" "unset — not required for profile=cloud"
fi
check "adb"     adb version optional
check "EAS CLI" eas --version optional

echo; echo "SECRETS  (presence only — values are never printed)"
for v in SUPABASE_SERVICE_ROLE_KEY OTP_PEPPER QR_PUBLIC_KEY PAYMENT_WEBHOOK_SECRET; do
  if [ -n "${!v:-}" ]; then row "$v" "SET"; else row "$v" "UNSET" "expected until provisioned"; fi
done

echo; echo "REPOSITORY"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for p in supabase/config.toml supabase/migrations supabase/tests supabase/seed.sql .nvmrc; do
  [ -e "$root/$p" ] && pass "$p" || fail "$p" "missing"
done
row "migrations" "INFO" "$(ls "$root"/supabase/migrations 2>/dev/null | wc -l | tr -d ' ') files"
row "assertions" "INFO" "$(grep -h 'SELECT plan(' "$root"/supabase/tests/*.test.sql 2>/dev/null | grep -o '[0-9]*' | paste -sd+ | bc 2>/dev/null || echo '?') PLANNED (not executed)"

echo; echo "═══════════════════════════════════════════════════════════════"
echo " PASS=$P  FAIL=$F  WARN=$W  BLOCKED=$B"
if [ "$F" -gt 0 ] || [ "$B" -gt 0 ]; then
  echo " RESULT: NOT READY — the verification gate cannot run here."
  echo " Required: reachable Docker daemon + Supabase CLI + psql + Deno."
  echo " See docs/DEVELOPMENT-ENVIRONMENT.md §2."
  exit 1
fi
echo " RESULT: READY — supabase start / db reset / test db can be attempted."
