#!/usr/bin/env bash
# ============================================================================
# KasihKirim — verification gate
#
# Runs the 12 gates IN ORDER and STOPS at the first failure. Gates 10-12
# (supabase start / db reset / test db) are unreachable unless gates 1-9 pass.
#
# This script exists so that "the database is verified" can only ever be said
# after the commands actually ran. It prints real output; it never infers.
#
# Compensating for a missing Docker daemon by removing migrations, mocking
# Postgres, skipping tests or weakening assertions is prohibited. If Docker
# does not work, the correct action is to fix the environment.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

G=0
gate() { G=$((G+1)); printf "\n──── GATE %-2s %s\n" "$G" "$1"; }
die()  { printf "\n════════════════════════════════════════════════\n"; \
         printf " STOPPED AT GATE %s: %s\n" "$G" "$1"; \
         printf " Gates %s-12 NOT ATTEMPTED.\n" "$((G+1))"; \
         printf " Nothing may be described as verified.\n"; \
         printf "════════════════════════════════════════════════\n"; exit 1; }
run()  { echo "  \$ $*"; "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }

echo "════════════════════════════════════════════════"
echo " KasihKirim verification gate — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "════════════════════════════════════════════════"

gate "cloud environment provisioned"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "  ${PRETTY_NAME:-unknown}"; fi
echo "  cpus=$(nproc 2>/dev/null || echo '?')  mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $2"GB"}' || echo '?')"
[ "$(nproc 2>/dev/null || echo 0)" -ge 2 ] || die "insufficient CPU for the Supabase stack"

gate "doctor passes"
bash scripts/kasihkirim-doctor.sh --profile=cloud >/dev/null 2>&1 \
  || { bash scripts/kasihkirim-doctor.sh --profile=cloud | tail -8; die "doctor reported FAIL/BLOCKED"; }
echo "  doctor: PASS"

gate "docker info"
command -v docker >/dev/null 2>&1 || die "docker CLI not installed"
run docker info >/dev/null || die "docker daemon unreachable — DO NOT compensate; fix the environment"
echo "  docker daemon: reachable"

gate "docker run hello-world"
run docker run --rm hello-world >/dev/null || die "docker cannot run containers"
echo "  container runtime: working"

gate "supabase --version"
command -v supabase >/dev/null 2>&1 || die "supabase CLI not installed"
run supabase --version || die "supabase CLI broken"

gate "psql --version"
command -v psql >/dev/null 2>&1 || die "psql not installed"
run psql --version || die "psql broken"

gate "node --version confirms Node 20"
command -v node >/dev/null 2>&1 || die "node not installed"
WANT="$(tr -d 'v \n' < .nvmrc)"; HAVE="$(node --version | tr -d 'v')"
echo "  .nvmrc=$WANT  installed=$HAVE"
[ "${HAVE%%.*}" = "${WANT%%.*}" ] \
  || die "Node major ${HAVE%%.*} != required ${WANT%%.*}. Run 'nvm use'. Do NOT adopt the ambient version."

gate "deno --version"
command -v deno >/dev/null 2>&1 || die "deno not installed"
run deno --version || die "deno broken"

gate "npm ping"
run npm ping || die "no registry egress"

echo
echo "════════════════════════════════════════════════"
echo " GATES 1-9 PASSED. Database steps may proceed."
echo "════════════════════════════════════════════════"

gate "supabase start"
run supabase start || die "supabase stack failed to start"

gate "supabase db reset"
run supabase db reset || die "migrations failed — capture the full error, fix the smallest thing, rerun"

gate "install pgTAP helpers"
run psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
      -v ON_ERROR_STOP=1 -f supabase/testing/00_helpers.sql \
  || die "helper install failed"

gate "supabase test db"
run supabase test db || die "assertions failed — fix the defect, DO NOT weaken the test"

echo
echo "════════════════════════════════════════════════"
echo " ALL 12 GATES PASSED."
echo " Database verified by execution on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "════════════════════════════════════════════════"
