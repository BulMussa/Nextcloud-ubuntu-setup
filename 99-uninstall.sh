#!/usr/bin/env bash
# Removes what 01-setup.sh, 02-tailscale.sh and monitoring/03-monitoring.sh installed.
# Your files and database (the Docker volumes) are KEPT unless you explicitly
# confirm deleting them. Docker, Tailscale and other packages are not uninstalled.
# Run with: sudo bash 99-uninstall.sh
# Preview without changing anything: DRY_RUN=1 bash 99-uninstall.sh
set -uo pipefail

DRY_RUN=${DRY_RUN:-}
if [ -z "$DRY_RUN" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo (or preview with: DRY_RUN=1 bash $0)." >&2
    exit 1
fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$DIR" || exit 1
PROJECT=nextcloud-server

run() {                                     # run a command, or only show it in dry-run mode
    if [ -n "$DRY_RUN" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

yes_no() {                                  # yes_no "<question>" <default y|n>
    local a hint="[y/N]"
    [ "$2" = y ] && hint="[Y/n]"
    if [ ! -t 0 ]; then a=$2; else read -rp "$1 $hint: " a; a=${a:-$2}; fi
    [[ $a =~ ^[Yy] ]]
}

[ -n "$DRY_RUN" ] && echo "DRY RUN: nothing will be changed."
echo "This will stop Nextcloud and remove the alert services and their settings."
echo "Your Nextcloud files and database are kept unless you confirm deleting them below."
CONTINUE_DEFAULT=n
[ -n "$DRY_RUN" ] && CONTINUE_DEFAULT=y     # a preview is harmless, so no need to ask
yes_no "Continue?" "$CONTINUE_DEFAULT" || { echo "Cancelled."; exit 0; }

echo
echo "== 1/5 Monitoring services and alert settings =="
for svc in power-monitor service-monitor; do
    run systemctl disable --now "$svc" 2>/dev/null || true
    run rm -f "/etc/systemd/system/$svc.service" "/usr/local/bin/$svc.sh"
done
run systemctl daemon-reload
run rm -f /usr/local/bin/send-alert.sh /usr/local/bin/smartd-mail.sh \
          /etc/default/nextcloud-alerts /etc/msmtprc
if [ -f /etc/smartd.conf.orig ]; then
    run mv /etc/smartd.conf.orig /etc/smartd.conf
    run systemctl restart smartmontools || true
    echo "Original /etc/smartd.conf restored."
fi
echo "Removed. (Email password in /etc/msmtprc deleted. Packages like msmtp stay installed.)"

echo
echo "== 2/5 Stopping Nextcloud =="
if [ -f docker-compose.yml ] && command -v docker >/dev/null; then
    run docker compose down --remove-orphans
else
    echo "Docker or docker-compose.yml not found, nothing to stop."
fi

echo
echo "== 3/5 Your data =="
VOLUMES=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true)
DELETED_DATA=no
if [ -z "$VOLUMES" ]; then
    echo "No Nextcloud data volumes found."
else
    echo "Found data volumes (all your files, users and settings):"
    # shellcheck disable=SC2086
    printf '  %s\n' $VOLUMES
    echo "KEEPING them is the default. Reinstalling later with 01-setup.sh picks them up again."
    if yes_no "Permanently DELETE all Nextcloud data? This cannot be undone." n; then
        if [ -t 0 ]; then
            read -rp "Type 'delete my data' to confirm: " phrase
        else
            phrase=""
        fi
        if [ "$phrase" = "delete my data" ]; then
            # shellcheck disable=SC2086
            run docker volume rm $VOLUMES && DELETED_DATA=yes
            echo "Data deleted."
        else
            echo "Confirmation did not match: data kept."
        fi
    else
        echo "Data kept."
    fi
fi

echo
echo "== 4/5 Firewall and Tailscale =="
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '8080'; then
    run ufw delete allow 8080/tcp
fi
if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    if yes_no "Log this machine out of Tailscale?" n; then
        run tailscale logout
    fi
fi

echo
echo "== 5/5 Settings file (.env) =="
if [ "$DELETED_DATA" = yes ]; then
    if yes_no "Data is gone, so delete .env (generated passwords) too?" y; then
        run rm -f .env
    fi
elif [ -f .env ]; then
    echo "Keeping .env: it holds the database passwords your kept data needs."
fi

echo
echo "Done. Not removed: Docker, Tailscale, msmtp, smartmontools, downloaded images,"
echo "and this folder. To free image space: docker image prune -a"
