#!/usr/bin/env bash
# Installs Docker and starts Nextcloud.
# Run with: sudo bash 01-setup.sh   (from any folder; it finds its own location)
# Optional environment variables:
#   USER_QUOTA="200 GB"   storage limit per user, skips the question ("none" = unlimited)
#   PHONE_REGION=DE       two-letter country code (default: taken from your locale)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi
USER_NAME=${SUDO_USER:-}
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ]; then
    echo "Run this with sudo from your normal user account, not as root directly." >&2
    exit 1
fi
if ! command -v apt-get >/dev/null; then
    echo "This script needs a Debian/Ubuntu system (apt-get). On other systems install" >&2
    echo "Docker yourself, copy .env.example to .env, and run: docker compose up -d" >&2
    exit 1
fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$DIR"

echo "== 1/5 Installing Docker =="
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1 \
   || ! command -v openssl >/dev/null; then
    apt-get update
    apt-get install -y docker.io docker-compose-v2 openssl
fi
systemctl enable --now docker
usermod -aG docker "$USER_NAME"   # lets this user run docker without sudo (after re-login)

echo
echo "== 2/5 Storage for users =="
STORE=/var/lib/docker
[ -d "$STORE" ] || STORE=/
read -r TOTAL_MB AVAIL_MB < <(df -Pm "$STORE" | awk 'NR==2 { print $2, $4 }')
read -r MEM_TOTAL_MB MEM_AVAIL_MB < <(awk '/^MemTotal/ { t=$2 } /^MemAvailable/ { a=$2 }
                                          END { print int(t/1024), int(a/1024) }' /proc/meminfo)
gb() { awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'; }

echo "Disk holding Nextcloud data ($STORE):  $(gb "$TOTAL_MB") total, $(gb "$AVAIL_MB") free"
echo "Memory:                                $(gb "$MEM_TOTAL_MB") total, $(gb "$MEM_AVAIL_MB") available"
if [ "$MEM_TOTAL_MB" -lt 2000 ]; then
    echo "Warning: under 2 GB of RAM. Nextcloud will work but may be slow."
fi
if [ "$AVAIL_MB" -lt 10240 ]; then
    echo "Warning: under 10 GB of free disk space."
fi
echo "Nextcloud limits how much each user may store (a quota). It is a cap, not a"
echo "reservation: disk space is only used as files are uploaded."
echo "Press Enter to skip: the limit is then set to half of the free space."

EXISTING=$(grep -E '^USER_QUOTA=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
if [ $(( AVAIL_MB / 2 )) -ge 1024 ]; then HALF_TXT="$(( AVAIL_MB / 2 / 1024 )) GB"
else HALF_TXT="$(( AVAIL_MB / 2 )) MB"; fi
SUGGEST=${USER_QUOTA:-${EXISTING:-$HALF_TXT}}   # a quota chosen earlier stays on rerun
QUOTA_DEFAULTED=no
[ "$SUGGEST" = "$HALF_TXT" ] && QUOTA_DEFAULTED=yes

# parse_quota "<input>": sets QUOTA_TXT (for Nextcloud) and QUOTA_MB; returns 1 if invalid.
# Accepts e.g. 500, 500G, 500 GB, 2T, 800MB (plain numbers are GB) or "none".
parse_quota() {
    local v=${1,,}
    v=${v// /}
    if [ "$v" = none ]; then QUOTA_TXT=none QUOTA_MB=0; return 0; fi
    [[ $v =~ ^([0-9]+)(m|mb|g|gb|t|tb)?$ ]] || return 1
    local n=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]:-g}
    [ "$n" -ge 1 ] || return 1
    case $unit in
        m*) QUOTA_TXT="$n MB"; QUOTA_MB=$n ;;
        g*) QUOTA_TXT="$n GB"; QUOTA_MB=$(( n * 1024 )) ;;
        t*) QUOTA_TXT="$n TB"; QUOTA_MB=$(( n * 1024 * 1024 )) ;;
    esac
}

while true; do
    if [ -n "${USER_QUOTA:-}" ] || [ ! -t 0 ]; then
        answer=$SUGGEST                             # non-interactive: no question
    else
        read -rp "Storage limit per user [Enter = ${SUGGEST}] (e.g. 200 GB, 1 TB, none): " answer
        if [ -n "$answer" ]; then QUOTA_DEFAULTED=no; fi
        answer=${answer:-$SUGGEST}
    fi
    if ! parse_quota "$answer"; then
        echo "Not understood: '$answer'. Use a number with GB/TB/MB, or 'none'." >&2
        [ -t 0 ] && [ -z "${USER_QUOTA:-}" ] && continue
        exit 1
    fi
    if [ "$QUOTA_MB" -gt "$AVAIL_MB" ]; then
        echo "Note: $QUOTA_TXT is more than the $(gb "$AVAIL_MB") currently free."
        if [ -t 0 ] && [ -z "${USER_QUOTA:-}" ]; then
            read -rp "Use it anyway? [y/N]: " yn
            [[ ${yn:-n} =~ ^[Yy] ]] || continue
        fi
    fi
    break
done
echo "Storage limit per user: $QUOTA_TXT"
if [ "$QUOTA_DEFAULTED" = yes ]; then
    echo "Notice: no limit was chosen, so each user is limited to half of the free space"
    echo "        ($QUOTA_TXT). Change it any time, see 'Everyday commands' in README.md."
fi

echo
echo "== 3/5 Generating secrets (.env) =="
if [ ! -f .env ]; then
    IP=$(hostname -I | awk '{print $1}')
    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
    cat > .env <<ENV
ADMIN_USER=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DB_PASSWORD=$(openssl rand -hex 24)
DB_ROOT_PASSWORD=$(openssl rand -hex 24)
TRUSTED_DOMAINS="localhost ${IP} $(hostname)"
ENV
    chown "$USER_NAME:$USER_NAME" .env
    chmod 600 .env
else
    echo ".env already exists, keeping it."
fi
# Remember the chosen quota (replace any earlier value).
grep -v '^USER_QUOTA=' .env > .env.tmp || true
echo "USER_QUOTA=\"$QUOTA_TXT\"" >> .env.tmp
cat .env.tmp > .env
rm -f .env.tmp

echo
echo "== 4/5 Firewall: allow Nextcloud on port 8080 =="
if command -v ufw >/dev/null; then
    ufw allow 8080/tcp
fi

echo
echo "== 5/5 Starting Nextcloud (first start downloads ~1 GB, be patient) =="
docker compose up -d

echo "Waiting for the first-time install to finish..."
for _ in $(seq 1 60); do
    if docker compose exec -T -u www-data app php occ status 2>/dev/null | grep -q "installed: true"; then
        break
    fi
    sleep 5
done

occ() { docker compose exec -T -u www-data app php occ "$@"; }

# Run background jobs via the cron container.
occ background:cron || true
occ config:app:set files default_quota --value="$QUOTA_TXT" || true

REGION=${PHONE_REGION:-$(echo "${LANG:-}" | sed -n 's/^[a-z]*_\([A-Z][A-Z]\).*/\1/p')}
if [ -n "$REGION" ]; then
    occ config:system:set default_phone_region --value="$REGION" || true
else
    echo "Phone region not set (no locale found). Set it later with:"
    echo "  docker compose exec -u www-data app php occ config:system:set default_phone_region --value=US"
fi

# shellcheck source=/dev/null
source .env
echo
echo "Done. Open:  http://$(hostname -I | awk '{print $1}'):8080"
echo "Username:    ${ADMIN_USER}"
echo "Password:    ${ADMIN_PASSWORD}   (also saved in $DIR/.env)"
echo "User storage limit: ${USER_QUOTA}"
if [ "$QUOTA_DEFAULTED" = yes ]; then
    echo "(You skipped the question, so it was set to half of the free space.)"
fi
