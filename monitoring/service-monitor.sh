#!/usr/bin/env bash
# Emails when Nextcloud software breaks: a container stops or turns unhealthy,
# the web interface stops answering, or the disk is nearly full. Also emails
# when each problem is fixed. Runs as the service-monitor service.
set -u

PROJECT=nextcloud-server
SERVICES="app db redis cron"
URL=http://localhost:8080/status.php
DISK_LIMIT=90          # percent used
INTERVAL=60            # seconds between checks
FAILS_NEEDED=2         # consecutive failed checks before alerting (avoids false alarms)

declare -A fails down

send() {
    local subject=$1 body="$2

Time: $(date '+%Y-%m-%d %H:%M:%S')"
    ALERT_RETRIES=360 /usr/local/bin/send-alert.sh "$subject" "$body" &
}

# check <name> <problem text or empty if healthy> <alert subject> <hint>
report() {
    local name=$1 problem=$2 subject=$3 hint=$4
    if [ -n "$problem" ]; then
        fails[$name]=$(( ${fails[$name]:-0} + 1 ))
        if [ "${fails[$name]}" -ge "$FAILS_NEEDED" ] && [ -z "${down[$name]:-}" ]; then
            down[$name]=$(date +%s)
            send "$subject" "$problem. $hint"
        fi
    else
        fails[$name]=0
        if [ -n "${down[$name]:-}" ]; then
            local mins=$(( ($(date +%s) - ${down[$name]}) / 60 ))
            unset "down[$name]"
            send "Recovered: ${subject#Problem: }" "Back to normal after about ${mins} min."
        fi
    fi
}

while true; do
    for svc in $SERVICES; do
        state=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
                  --filter "label=com.docker.compose.service=$svc" \
                  --format '{{.State}}|{{.Status}}' | head -1)
        problem=""
        if [ -z "$state" ]; then
            problem="Container '$svc' does not exist"
        elif [ "${state%%|*}" != running ]; then
            problem="Container '$svc' is ${state%%|*} (${state#*|})"
        elif [[ "$state" == *"(unhealthy)"* ]]; then
            problem="Container '$svc' is running but unhealthy"
        fi
        report "container-$svc" "$problem" "Problem: Nextcloud container '$svc' is down" \
               "Check with (in the nextcloud-server folder): docker compose ps && docker compose logs --tail 50 $svc"
    done

    problem=""
    if ! curl -fsS -m 15 "$URL" 2>/dev/null | grep -q '"installed":true'; then
        problem="Nextcloud web interface at $URL is not answering correctly"
    fi
    report web "$problem" "Problem: Nextcloud website is not responding" \
           "Check with (in the nextcloud-server folder): docker compose logs --tail 50 app"

    used=$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc 0-9)
    problem=""
    if [ -n "$used" ] && [ "$used" -ge "$DISK_LIMIT" ]; then
        problem="Disk is ${used}% full (limit ${DISK_LIMIT}%)"
    fi
    report disk "$problem" "Problem: server disk almost full" \
           "Free some space or Nextcloud may stop working."

    sleep "$INTERVAL"
done
