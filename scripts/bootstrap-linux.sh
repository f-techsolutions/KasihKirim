#!/usr/bin/env bash
# ============================================================================
# KasihKirim — provision a plain Debian/Ubuntu Linux host.
#
# Platform-independent: works on a VPS, a cloud VM, WSL2, or any Linux box.
# Codespaces and Gitpod are conveniences, not requirements.
#
# Requires sudo and outbound network. Idempotent.
# ============================================================================
set -euo pipefail
NODE_MAJOR=20
SUPABASE_VERSION="${SUPABASE_VERSION:-2.107.0}"

echo "── base packages ──"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg git build-essential postgresql-client openjdk-17-jdk-headless

echo "── Docker Engine ──"
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker "$USER" || true
sudo systemctl enable --now docker || echo "  NOTE: no systemd — start the daemon manually"

echo "── Node ${NODE_MAJOR} LTS (via nvm; .nvmrc is the source of truth) ──"
export NVM_DIR="$HOME/.nvm"
[ -d "$NVM_DIR" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR" && nvm alias default "$NODE_MAJOR"

echo "── Deno ──"
command -v deno >/dev/null 2>&1 || curl -fsSL https://deno.land/install.sh | sh

echo "── Supabase CLI ──"
if ! command -v supabase >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
  curl -fsSL -o /tmp/supabase.deb \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_${SUPABASE_VERSION}_linux_${ARCH}.deb"
  sudo dpkg -i /tmp/supabase.deb && rm -f /tmp/supabase.deb
fi

echo
echo "Done. Log out and back in for docker group membership, then:"
echo "  ./scripts/verify-gate.sh"
