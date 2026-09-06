#!/usr/bin/env bash
# ============================================================================
# KasihKirim — verify MANIFEST.sha256
#
#   ./scripts/verify-manifest.sh            verify against the WORKING TREE
#   ./scripts/verify-manifest.sh --staged   verify against the GIT INDEX
#
# Use --staged on Windows, and in CI. Plain `sha256sum -c` reads the working
# tree, so a CRLF checkout reports false failures for files that are byte-
# identical in Git. --staged compares canonical committed content and is
# therefore platform-independent.
# ============================================================================
set -uo pipefail

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git not found in PATH."
if   command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum | cut -d' ' -f1; }
elif command -v shasum    >/dev/null 2>&1; then SHA() { shasum -a 256 | cut -d' ' -f1; }
else die "Neither sha256sum nor shasum found."; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a Git repository."
cd "$ROOT"
[ -f MANIFEST.sha256 ] || die "MANIFEST.sha256 not found."

MODE="worktree"; [ "${1:-}" = "--staged" ] && MODE="staged"
ok=0; bad=0; missing=0

while read -r want path; do
  [ -n "${want:-}" ] || continue
  rel="${path#./}"
  if [ "$MODE" = "staged" ]; then
    blob="$(git ls-files -s -- "$rel" 2>/dev/null | awk '{print $2}')"
    if [ -z "$blob" ]; then
      printf '  MISSING FROM INDEX  %s\n' "$rel"; missing=$((missing+1)); continue
    fi
    got="$(git cat-file blob "$blob" | SHA)"
  else
    if [ ! -f "$rel" ]; then
      printf '  MISSING FROM DISK   %s\n' "$rel"; missing=$((missing+1)); continue
    fi
    got="$(SHA < "$rel")"
  fi
  if [ "$got" = "$want" ]; then ok=$((ok+1))
  else printf '  FAILED              %s\n' "$rel"; bad=$((bad+1)); fi
done < MANIFEST.sha256

printf 'manifest verify (%s): %s OK, %s FAILED, %s MISSING\n' "$MODE" "$ok" "$bad" "$missing"
[ "$bad" -eq 0 ] && [ "$missing" -eq 0 ] || exit 1
