#!/usr/bin/env bash
# ============================================================================
# KasihKirim — regenerate MANIFEST.sha256
#
# Hashes the content Git has STAGED, not the working tree. This is the whole
# point: a Windows checkout with CRLF endings produces different bytes on disk
# from the same committed blob, so hashing the working tree yields a manifest
# that fails verification in CI. The index is identical on every platform.
#
# Workflow:
#     git add <your changes>
#     ./scripts/update-manifest.sh
#     git add MANIFEST.sha256
#     git commit
#
# Runs from any directory inside the repository. Works under Git Bash on
# Windows and on Ubuntu GitHub Actions runners.
# ============================================================================
set -euo pipefail

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# ── Tooling ─────────────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die "git not found in PATH."
if   command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum | cut -d' ' -f1; }
elif command -v shasum    >/dev/null 2>&1; then SHA() { shasum -a 256 | cut -d' ' -f1; }
else die "Neither sha256sum nor shasum found. Install coreutils."; fi

# ── Repository root ─────────────────────────────────────────────────────────
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a Git repository."
cd "$ROOT"

MANIFEST="MANIFEST.sha256"
TMP="$(mktemp "${TMPDIR:-/tmp}/kk-manifest.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# ── Refuse to run on a dirty tree ───────────────────────────────────────────
# The manifest describes what will be committed. If tracked files differ
# between the index and the working tree, the manifest would describe content
# that is not on disk -- confusing, and exactly the class of drift this script
# exists to prevent. MANIFEST.sha256 itself is exempt: we are rewriting it.
DIRTY="$(git diff --name-only -- . ':(exclude)MANIFEST.sha256' || true)"
if [ -n "$DIRTY" ]; then
  printf 'Unstaged changes to tracked files:\n' >&2
  printf '  %s\n' $DIRTY >&2
  die "Stage your changes first:  git add <files>   then re-run this script."
fi

# ── Enumerate from the INDEX, never from disk ───────────────────────────────
# `git ls-files -s` yields: <mode> <blob-sha1> <stage>\t<path>
# LC_ALL=C makes the sort byte-deterministic across locales and platforms.
count=0
while IFS= read -r -d '' entry; do
  blob="$(printf '%s' "$entry" | awk '{print $2}')"
  path="${entry#*$'\t'}"

  # Exclusions. MANIFEST.sha256 is excluded first and unconditionally: it must
  # never be enumerated while it is being written (a self-referential hash can
  # never match).
  case "$path" in
    MANIFEST.sha256)                       continue ;;
    *.patch|*.diff)                        continue ;;
    *.tar.gz|*.tgz|*.zip|*.7z)             continue ;;
    .git/*|*/.git/*)                       continue ;;
    node_modules/*|*/node_modules/*)       continue ;;
    dist/*|*/dist/*|build/*|*/build/*)     continue ;;
    .expo/*|*/.expo/*|coverage/*)          continue ;;
    ci-logs/*|*.log)                       continue ;;
  esac

  hash="$(git cat-file blob "$blob" | SHA)"
  printf '%s  ./%s\n' "$hash" "$path"
  count=$((count + 1))
done < <(git ls-files -s -z | LC_ALL=C sort -z -t$'\t' -k2) > "$TMP"

[ "$count" -gt 0 ] || die "No files matched. Refusing to write an empty manifest."

# ── Atomic replace ──────────────────────────────────────────────────────────
mv -f "$TMP" "$MANIFEST"
trap - EXIT

printf 'MANIFEST.sha256 written: %s entries\n' "$count"

# ── Verify what we just wrote ───────────────────────────────────────────────
if [ -x "$ROOT/scripts/verify-manifest.sh" ] || [ -f "$ROOT/scripts/verify-manifest.sh" ]; then
  bash "$ROOT/scripts/verify-manifest.sh" --staged
else
  printf 'WARNING: scripts/verify-manifest.sh missing; wrote without verifying.\n' >&2
fi
