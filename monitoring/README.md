# Monitoring: hard drive health + power / battery alerts

Sends an alert when the server's hard drive shows signs of failing, or when the
laptop stops running on the charger (power cut, unplugged charger, broken cable).

Every alert is written to the system log. It can also be sent by **email**
(Gmail) and/or as a **phone push** through the free ntfy app. Both are optional
and can be added, changed or removed later by running the script again.

## Quick start

```bash
sudo bash monitoring/03-monitoring.sh
```

Run it from the repository folder, in a normal terminal window, because it asks questions. It is safe to run
as many times as you like.

## Before you run it

**For email alerts (optional)** you need a Gmail **App Password**. Gmail does not
accept your normal password from scripts.

1. Use a separate Gmail account just for sending alerts (recommended). The App
   Password is stored on this server and gives full access to that mailbox.
2. In that account turn on **2-Step Verification**.
3. Create an App Password at <https://myaccount.google.com/apppasswords>.
   New accounts may have to wait about 7 days before this page works.

**For phone push (optional)** install the free **ntfy** app on your phone
(Google Play, F-Droid or App Store). No account is needed.

You can skip both. Monitoring still runs and alerts go to the system log only.

## What the script asks

| Question | What to answer |
|---|---|
| `Set up email alerts now? [y/N]` | `y` to set up or manage email, Enter to skip |
| `Sender email (account that sends alerts)` | the alerts Gmail account, e.g. `myserver.alerts@gmail.com` |
| `SMTP server [smtp.gmail.com]` | Enter (for Gmail) |
| `SMTP port [587]` | Enter (for Gmail) |
| `App password (hidden)` | the App Password (spaces are removed automatically) |
| `Send alerts to [...]` | the email address you check every day |
| `Set up ntfy phone push? [y/N]` | `y` to set up or manage ntfy, Enter to skip |
| `Topic name (Enter = generate a random one)` | Enter (recommended) |
| `Press Enter when subscribed...` | in the ntfy app tap **+**, enter the topic shown, then press Enter |

Anyone who knows the ntfy topic name can read the alerts, so keep it secret and
prefer the random one.

## Running it again (add, change or remove)

Each run:

1. **Checks the required tools** (msmtp, curl, smartmontools, openssl, logger,
   ca-certificates) and downloads only the missing ones.
2. **Email / ntfy:** answer `y` to the question. If it is already set up, the
   script shows the current settings (never the password) and asks
   `Keep, change or remove it? [K/c/r]`:
   - `k` or Enter: keep as it is
   - `c`: change. Each question shows the current value in brackets; Enter keeps
     it. For the password, Enter keeps the saved one.
   - `r`: remove. For email this also deletes the saved App Password.

   Answering `N` (or Enter) to the question leaves existing settings unchanged.
3. Sends a **test alert** to every channel that is set up. If it fails, the
   script stops; for email check `/var/log/msmtp.log`, fix and rerun.
4. Re-applies the drive and power monitoring and restarts both services.
5. Prints the **current drive health**.

Typical use: run it once now without email, then again when the Gmail App
Password is available and answer `y` to the email question.

## What you get alerts for

**Hard drive** (the drive holding the Nextcloud data, detected automatically and checked by `smartd`):

- SMART overall health check fails
- any new **reallocated sector** (the earliest common sign of a dying drive)
- unreadable sectors (pending / offline uncorrectable)
- drive temperature reaches **60 °C** (noted at 50 °C)
- a self-test fails. Short test daily at **02:00**, long test Sunday at **05:00**
  (takes 1-2 hours and slows the disk a bit)
- an unresolved warning is repeated after 1, 2, 4... days

**Nextcloud software** (checked every 60 seconds, alert after 2 failed checks in a row):

- a container (`app`, `db`, `redis`, `cron`) stops, is missing or turns unhealthy
- the website at `http://localhost:8080/status.php` stops answering
- the disk is 90% full or more
- a "Recovered" email follows when the problem is fixed

**Power / battery** (checked every 10 seconds):

- **On battery**: the charger stopped powering the laptop
- **Discharging while the charger is connected**: charger or cable problem
- **Battery low** at 20% and again at 10%
- **Power restored**, with how many minutes it ran on battery

During a power cut the Wi-Fi router usually loses power too, so the alert cannot
be sent right away. It is retried for up to 1 hour and shows the time the event
happened. Put the router on a small UPS or power bank to get alerts during the
outage.

## Testing

- After setup you should get **2 test alerts**: one from the script and one from smartd.
- Unplug the charger for about 20 seconds, then plug it back in. You should get
  "On battery" and then "Power restored".

## Useful commands

```bash
journalctl -t nextcloud-alert            # all alerts ever sent (or attempted)
systemctl status power-monitor           # power watcher running?
systemctl status smartmontools           # drive monitor running?
systemctl status service-monitor         # software watcher running?
sudo smartctl -H -A /dev/sdX             # drive health right now
sudo smartctl -l selftest /dev/sdX       # self-test results
sudo tail /var/log/msmtp.log             # email sending log
sudo send-alert.sh "Test" "Hello"        # send a manual test alert
```

## Files

In this folder (source, copied into place by the script):

| File | Purpose |
|---|---|
| `03-monitoring.sh` | setup script (this guide) |
| `send-alert.sh` | sends one alert to the log, email and/or ntfy |
| `power-monitor.sh` | watches the charger and battery |
| `smartd-mail.sh` | passes smartd warnings to `send-alert.sh` |
| `service-monitor.sh` | watches containers, website and disk space |

Installed on the system:

| Path | Contents |
|---|---|
| `/usr/local/bin/send-alert.sh`, `power-monitor.sh`, `smartd-mail.sh`, `service-monitor.sh` | installed copies of the scripts |
| `/etc/default/nextcloud-alerts` | recipient email and ntfy topic |
| `/etc/msmtprc` | email account and App Password (root only) |
| `/etc/smartd.conf` | drive monitoring rules (original saved as `/etc/smartd.conf.orig`) |
| `/etc/systemd/system/power-monitor.service` | runs the power watcher at boot |

After editing a script in this folder, rerun `03-monitoring.sh` to install the
new version.

## Uninstall

```bash
sudo systemctl disable --now power-monitor service-monitor
sudo rm /etc/systemd/system/power-monitor.service /etc/systemd/system/service-monitor.service
sudo systemctl daemon-reload
sudo cp /etc/smartd.conf.orig /etc/smartd.conf && sudo systemctl restart smartmontools
sudo rm -f /etc/msmtprc /etc/default/nextcloud-alerts \
    /usr/local/bin/send-alert.sh /usr/local/bin/power-monitor.sh /usr/local/bin/smartd-mail.sh /usr/local/bin/service-monitor.sh
```
