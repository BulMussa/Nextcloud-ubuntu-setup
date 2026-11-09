#!/usr/bin/env bash
# Sets up alerts for hard drive health (smartd) and power loss / battery.
# Alerts always go to the system log; email and ntfy phone push are optional.
# Safe to run any number of times: installs only missing tools, shows existing
# email / ntfy settings and asks before changing them.
# Run with: sudo bash monitoring/03-monitoring.sh
# Optional: DISK=/dev/sdb sudo -E bash monitoring/03-monitoring.sh  (monitor a specific drive)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF=/etc/default/nextcloud-alerts
MSMTPRC=/etc/msmtprc

yes_no() {                                  # yes_no "<question>" <default y|n>
    local a hint="[y/N]"
    [ "$2" = y ] && hint="[Y/n]"
    read -rp "$1 $hint: " a
    a=${a:-$2}
    [[ $a =~ ^[Yy] ]]
}

keep_change_remove() {                      # prints k, c or r (Enter = k)
    local a
    while true; do
        read -rp "Keep, change or remove it? [K/c/r]: " a
        case ${a:-k} in
            [Kk]*) echo k; return ;;
            [Cc]*) echo c; return ;;
            [Rr]*) echo r; return ;;
            *) echo "Please answer k, c or r." >&2 ;;
        esac
    done
}

msmtp_value() {                             # msmtp_value <key>, empty if not set up
    [ -f "$MSMTPRC" ] || return 0
    awk -v k="$1" '$1 == k { print $2; exit }' "$MSMTPRC"
}

# detect_disk: prints the physical drive that holds the Docker data (the Nextcloud
# files and database), preferring its stable /dev/disk/by-id name.
detect_disk() {
    local src dev l
    src=$(findmnt -no SOURCE -T /var/lib/docker 2>/dev/null || findmnt -no SOURCE -T /) || return 1
    src=${src%%[*}                          # btrfs shows "/dev/sda2[/@]"
    dev=$(lsblk -nrs -o NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')
    [ -n "$dev" ] || return 1
    dev=/dev/$dev
    for l in /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-* /dev/disk/by-id/scsi-*; do
        if [ -e "$l" ] && [ "$(readlink -f "$l")" = "$dev" ]; then
            echo "$l"
            return 0
        fi
    done
    echo "$dev"
}

ALERT_TO="" NTFY_TOPIC=""
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

echo "== 1/5 Checking required tools =="
# package:command it provides
NEEDED="msmtp:msmtp curl:curl smartmontools:smartctl openssl:openssl bsdutils:logger ca-certificates:update-ca-certificates"
MISSING=()
for item in $NEEDED; do
    pkg=${item%%:*} cmd=${item#*:}
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
       && command -v "$cmd" >/dev/null; then
        echo "  ok       $pkg"
    else
        echo "  missing  $pkg"
        MISSING+=("$pkg")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Installing: ${MISSING[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
else
    echo "All tools already installed."
fi

echo
echo "== 2/5 Where to send alerts =="

# --- Email ---
setup_email() {
    local from host port pass to
    local cur_from cur_host cur_port
    cur_from=$(msmtp_value from) cur_host=$(msmtp_value host) cur_port=$(msmtp_value port)
    echo "Gmail App Password: turn on 2-Step Verification, then create one at"
    echo "  https://myaccount.google.com/apppasswords"
    [ -n "$cur_from" ] && echo "(Press Enter to keep the current value shown in brackets.)"
    read -rp "Sender email (account that sends alerts) [${cur_from}]: " from
    from=${from:-$cur_from}
    if [ -z "$from" ]; then echo "Sender email is required." >&2; return 1; fi
    read -rp "SMTP server [${cur_host:-smtp.gmail.com}]: " host
    host=${host:-${cur_host:-smtp.gmail.com}}
    read -rp "SMTP port [${cur_port:-587}]: " port
    port=${port:-${cur_port:-587}}
    if [ -n "$cur_from" ]; then
        read -rsp "App password (hidden, Enter keeps current): " pass; echo
        pass=${pass:-$(msmtp_value password)}
    else
        read -rsp "App password (hidden): " pass; echo
    fi
    pass=${pass// /}                        # Gmail shows it with spaces
    if [ -z "$pass" ]; then echo "App password is required." >&2; return 1; fi
    read -rp "Send alerts to [${ALERT_TO:-$from}]: " to
    ALERT_TO=${to:-${ALERT_TO:-$from}}

    local starttls=on
    [ "$port" = 465 ] && starttls=off       # port 465 = TLS from the start
    umask 077
    cat > "$MSMTPRC" <<EOF
defaults
auth on
tls on
tls_starttls $starttls
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account alerts
host $host
port $port
from $from
user $from
password $pass

account default : alerts
EOF
    umask 022
    echo "Email settings saved."
}

if yes_no "Set up email alerts now? Needs a Gmail App Password." n; then
    if [ -n "$ALERT_TO" ] && [ -f "$MSMTPRC" ]; then
        echo "Email alerts are already set up:"
        echo "  Sender:     $(msmtp_value from)"
        echo "  Server:     $(msmtp_value host):$(msmtp_value port)"
        echo "  Alerts to:  $ALERT_TO"
        case $(keep_change_remove) in
            c) setup_email ;;
            r) rm -f "$MSMTPRC"; ALERT_TO=""
               echo "Email alerts removed (saved password deleted)." ;;
            *) echo "Keeping current email settings." ;;
        esac
    else
        setup_email
    fi
else
    if [ -n "$ALERT_TO" ]; then
        echo "Skipped. Existing email alerts to $ALERT_TO stay as they are."
    else
        echo "Skipped. No email alerts for now."
    fi
fi

echo

# --- ntfy ---
setup_ntfy() {
    local t
    echo "Install the free 'ntfy' app on your phone (no account needed)."
    echo "Anyone who knows the topic name can read the alerts, so a random one is best."
    read -rp "Topic name (Enter = generate a random one): " t
    NTFY_TOPIC=${t:-nextcloud-$(openssl rand -hex 8)}
    echo ">>> In the ntfy app tap '+' (Subscribe to topic) and enter:  $NTFY_TOPIC"
    read -rp "Press Enter when subscribed... "
}

if yes_no "Set up ntfy phone push?" n; then
    if [ -n "$NTFY_TOPIC" ]; then
        echo "ntfy phone push is already set up:"
        echo "  Topic:  $NTFY_TOPIC"
        case $(keep_change_remove) in
            c) setup_ntfy ;;
            r) NTFY_TOPIC=""
               echo "ntfy phone push removed. You can also unsubscribe in the ntfy app." ;;
            *) echo "Keeping current ntfy topic." ;;
        esac
    else
        setup_ntfy
    fi
else
    if [ -n "$NTFY_TOPIC" ]; then
        echo "Skipped. Existing ntfy topic $NTFY_TOPIC stays as it is."
    else
        echo "Skipped. No ntfy phone push for now."
    fi
fi

umask 077
printf 'ALERT_TO=%s\nNTFY_TOPIC=%s\n' "$ALERT_TO" "$NTFY_TOPIC" > "$CONF"
umask 022
install -m 755 "$DIR/send-alert.sh" /usr/local/bin/send-alert.sh

echo
if [ -z "$ALERT_TO$NTFY_TOPIC" ]; then
    echo "No email or ntfy: alerts only go to the system log for now."
    echo "Rerun this script later to add them."
fi
if /usr/local/bin/send-alert.sh "Test: alerts work" "This is a test from the monitoring setup."; then
    echo "Test alert sent."
else
    echo "Sending the test alert failed. For email see /var/log/msmtp.log. Fix and rerun." >&2
    exit 1
fi

echo
echo "== 3/5 Hard drive monitoring (smartd) =="
DISK=${DISK:-$(detect_disk || true)}
if [ -n "$DISK" ] && ! smartctl -i "$DISK" >/dev/null 2>&1; then
    echo "Drive $DISK does not report SMART data (virtual machine or USB bridge?)."
    DISK=""
fi
if [ -z "$DISK" ]; then
    echo "No monitorable drive found, skipping drive health alerts."
    echo "To monitor a specific drive: DISK=/dev/sdX sudo -E bash $0"
    systemctl disable --now smartmontools 2>/dev/null || true
else
    MODEL=$(smartctl -i "$DISK" | awk -F: '/Device Model|Model Number|Product/ { gsub(/^ +/, "", $2); print $2; exit }')
    echo "Monitoring: $DISK (${MODEL:-unknown model})"
    install -m 755 "$DIR/smartd-mail.sh" /usr/local/bin/smartd-mail.sh
    [ -f /etc/smartd.conf.orig ] || cp /etc/smartd.conf /etc/smartd.conf.orig
    # -o/-S/-R are ATA-only; NVMe drives get the common checks.
    case $(readlink -f "$DISK") in
        *nvme*) ATA_OPTS="" ;;
        *)      ATA_OPTS="-o on -S on -R 5!" ;;
    esac
    # smartd requires -m; the real recipients come from send-alert.sh.
    cat > /etc/smartd.conf <<EOF
# ${MODEL:-Drive} ($DISK). Original config: /etc/smartd.conf.orig
#  -a           check health, attributes, error and self-test logs
#  -o on -S on  enable automatic offline tests and attribute autosave
#  -R 5!        alert on any new reallocated sector (early failure sign)
#  -W 4,50,60   report temp changes of 4C, note at 50C, alert at 60C
#  -s ...       short self-test daily 02:00, long self-test Sunday 05:00
#  -M diminishing  repeat an unresolved warning after 1, 2, 4... days
$DISK -a $ATA_OPTS -W 4,50,60 -s (S/../.././02|L/../../7/05) -m root -M diminishing -M exec /usr/local/bin/smartd-mail.sh
EOF
    systemctl enable smartmontools
    systemctl restart smartmontools
    echo "smartd is $(systemctl is-active smartmontools)."

    echo "$DISK -H -m root -M test -M exec /usr/local/bin/smartd-mail.sh" > /tmp/smartd-test.conf
    smartd -c /tmp/smartd-test.conf -q onecheck >/dev/null && echo "smartd test alert sent."
    rm -f /tmp/smartd-test.conf
fi

echo
echo "== 4/5 Power / battery monitoring =="
if grep -qs Battery /sys/class/power_supply/*/type && grep -qs Mains /sys/class/power_supply/*/type; then
    install -m 755 "$DIR/power-monitor.sh" /usr/local/bin/power-monitor.sh
    cat > /etc/systemd/system/power-monitor.service <<'EOF'
[Unit]
Description=Alerts on power loss and low battery
After=network-online.target

[Service]
ExecStart=/usr/local/bin/power-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable power-monitor
    systemctl restart power-monitor
    echo "power-monitor is $(systemctl is-active power-monitor)."
else
    echo "No battery and charger found (desktop or server): skipping power alerts."
    systemctl disable --now power-monitor 2>/dev/null || true
fi

echo
echo "== Nextcloud software monitoring =="
install -m 755 "$DIR/service-monitor.sh" /usr/local/bin/service-monitor.sh
cat > /etc/systemd/system/service-monitor.service <<'EOF'
[Unit]
Description=Alerts when Nextcloud containers or website go down
After=network-online.target docker.service

[Service]
ExecStart=/usr/local/bin/service-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable service-monitor
systemctl restart service-monitor
echo "service-monitor is $(systemctl is-active service-monitor)."

echo
echo "== 5/5 Current drive health =="
[ -z "$DISK" ] || smartctl -H -A "$DISK" | grep -E 'overall-health|Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Temperature_Celsius|Reported_Uncorrect' || true

echo
echo "Done. You should have 2 test alerts. Unplug the charger for ~20 s to test power alerts."
echo "See all alerts any time with:  journalctl -t nextcloud-alert"
