#!/usr/bin/env bash
# Provisions the tools the verification gate needs. Idempotent.
set -euo pipefail

echo "── Supabase CLI ──"
# Installed from the release tarball rather than npm: the npm package is
# deprecated for global install and the tarball works behind a proxy.
SUPABASE_VERSION="${SUPABASE_VERSION:-2.107.0}"
ARCH="$(dpkg --print-architecture)"
curl -fsSL -o /tmp/supabase.deb \
  "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_${SUPABASE_VERSION}_linux_${ARCH}.deb"
sudo dpkg -i /tmp/supabase.deb && rm -f /tmp/supabase.deb

echo "── Verify ──"
bash "$(dirname "$0")/../scripts/kasihkirim-doctor.sh" --profile=cloud || true

cat <<'MSG'

Next:
  supabase start
  supabase db reset
  supabase test db

Nothing in this repository has been executed. Expect failures on first run;
see docs/DEVELOPMENT-ENVIRONMENT.md §3.2.
MSG
