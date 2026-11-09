#!/usr/bin/env bash
# Sends one alert: always to the system log, plus email and/or ntfy phone push
# when configured in /etc/default/nextcloud-alerts.
# Usage: [ALERT_RETRIES=n] send-alert.sh "<subject>" "<body>"
# Each channel is retried every 10 s up to ALERT_RETRIES times (default 1 try).
# Exits non-zero if any configured channel never succeeded.
set -u
ALERT_TO="" NTFY_TOPIC=""
# shellcheck source=/dev/null
. /etc/default/nextcloud-alerts
subject="[$(hostname)] $1" body=$2 tries=${ALERT_RETRIES:-1}

logger -t nextcloud-alert -- "$subject: $body"

retry() {
    for _ in $(seq 1 "$tries"); do
        "$@" && return 0
        sleep 10
    done
    logger -t nextcloud-alert -- "failed to deliver via $1: $subject"
    return 1
}

email() {
    printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$ALERT_TO" "$subject" "$body" | msmtp -t
}

ntfy() {
    curl -fsS -m 20 -H "Title: $subject" -d "$body" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
}

pids=()
if [ -n "$ALERT_TO" ] && [ -f /etc/msmtprc ]; then retry email & pids+=($!); fi
if [ -n "$NTFY_TOPIC" ]; then retry ntfy & pids+=($!); fi

rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
exit $rc
