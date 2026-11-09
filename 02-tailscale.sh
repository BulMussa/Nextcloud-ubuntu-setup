#!/usr/bin/env bash
# Installs Tailscale and lets Nextcloud answer on the Tailscale address.
# Run with: sudo bash 02-tailscale.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== 1/3 Installing Tailscale =="
if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

echo "== 2/3 Logging in =="
echo "A login link will appear below. Open it in a browser and sign in"
echo "(Google, Microsoft, GitHub or Apple account). The script continues after that."
tailscale up --hostname=nextcloud

TS_IP=$(tailscale ip -4)
TS_NAME=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')

echo "== 3/3 Adding Tailscale address to Nextcloud trusted domains =="
occ() { docker compose exec -T -u www-data app php occ "$@"; }
occ config:system:set trusted_domains 10 --value="$TS_IP"
occ config:system:set trusted_domains 11 --value="$TS_NAME"
occ config:system:set trusted_domains 12 --value="nextcloud"

echo
echo "Done. From any device logged into the same Tailscale account, open:"
echo "  http://${TS_NAME}:8080"
echo "  http://${TS_IP}:8080"
