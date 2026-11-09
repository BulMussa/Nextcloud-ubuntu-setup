#!/usr/bin/env bash
# Emails when the laptop loses mains power (or stops charging) and when power
# comes back, plus warnings at low battery. Runs as the power-monitor service.
set -u

AC=$(grep -l Mains /sys/class/power_supply/*/type | head -1 | xargs -r dirname)
BAT=$(grep -l Battery /sys/class/power_supply/*/type | head -1 | xargs -r dirname)

if [ -z "$AC" ] || [ -z "$BAT" ]; then
    echo "No battery / charger found: nothing to monitor." >&2
    exit 0
fi

# Send in the background and retry for up to 1 hour: during a power cut the
# router is often down too, so the alert goes out once the internet is back.
send() {
    local subject=$1 body="$2

Time: $(date '+%Y-%m-%d %H:%M:%S')"
    ALERT_RETRIES=360 /usr/local/bin/send-alert.sh "$subject" "$body" &
}

on_battery() {
    [ "$(cat "$AC/online")" = 0 ] || [ "$(cat "$BAT/status")" = Discharging ]
}

was_on_battery=no
on_battery && was_on_battery=yes
since=$(date +%s)
warned=100

while true; do
    level=$(cat "$BAT/capacity")
    if on_battery; then
        if [ "$was_on_battery" = no ]; then
            was_on_battery=yes; since=$(date +%s); warned=100
            if [ "$(cat "$AC/online")" = 0 ]; then
                send "On battery: mains power lost (${level}%)" \
                     "The server is no longer powered by the charger and is running on battery (${level}%)."
            else
                send "Battery discharging while charger is connected (${level}%)" \
                     "The charger is reported as connected but the battery is discharging. Check the charger and cable."
            fi
        fi
        for t in 20 10; do
            if [ "$level" -le "$t" ] && [ "$warned" -gt "$t" ]; then
                warned=$t
                send "Battery low: ${level}%" \
                     "The server is still on battery and has ${level}% left. It will shut down soon unless power returns."
            fi
        done
    elif [ "$was_on_battery" = yes ]; then
        was_on_battery=no
        mins=$(( ($(date +%s) - since) / 60 ))
        send "Power restored (${level}%)" \
             "The charger is powering the server again after about ${mins} min on battery. Battery: ${level}%."
    fi
    sleep 10
done
