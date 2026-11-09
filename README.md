# Nextcloud home server

A self-hosted Nextcloud (app + MariaDB + Redis + background-jobs cron) in Docker
Compose, with optional Tailscale remote access and drive / power / service alerts.

## Requirements

- Debian or Ubuntu (the scripts use `apt`), with `sudo`
- About 2 GB RAM and 10 GB free disk space, plus room for your files
- Internet access (the first start downloads about 1 GB)
- Not on Debian/Ubuntu? Install Docker yourself, copy `.env.example` to `.env`,
  and run `docker compose up -d`

## Quick start

```bash
git clone <this repo> nextcloud-server
cd nextcloud-server
sudo bash 01-setup.sh
```

The script installs Docker, shows your free disk space and memory, and asks how much
storage each user may use. That limit is a quota: a cap per user, not space set aside
in advance. If you press Enter to skip the question, each user is limited to half of
the free space and the script tells you so. To set it without being asked, run `USER_QUOTA="200 GB" sudo -E bash 01-setup.sh` (`none` means unlimited).

It then generates random passwords in `.env`, starts everything, and prints the
address and login. `.env` is private and is not committed to git.

## Everyday commands

Run these in this folder.

- Status: `docker compose ps`
- Logs: `docker compose logs -f app`
- Stop / start: `docker compose down` / `docker compose up -d`
- Update: `docker compose pull && docker compose up -d`
- Admin CLI: `docker compose exec -u www-data app php occ <command>`
- Change the per-user storage limit:
  `docker compose exec -u www-data app php occ config:app:set files default_quota --value="500 GB"`
  (or for one user: `occ user:setting <user> files quota "1 TB"`)

Data lives in the Docker volumes `nextcloud-server_nextcloud` (files) and
`nextcloud-server_db` (database), under `/var/lib/docker/volumes`.

## Remote access (Tailscale, optional)

- Setup: `sudo bash 02-tailscale.sh`
- Status: `tailscale status`
- From any device on your tailnet: `http://nextcloud:8080` (or the 100.x address)

## Monitoring (hard drive, power and service alerts, optional)

- Setup: `sudo bash monitoring/03-monitoring.sh` (safe to rerun)
- The drive holding the Nextcloud data is detected automatically
  (set `DISK=/dev/sdX` to choose another). The power monitor is skipped on machines
  without a battery.
- Alerts: drive health problems, power cut / charger stopped, low battery, a
  container or the website going down, disk almost full
- Sent to: system log, plus optional email (Gmail App Password) and ntfy phone push
- History: `journalctl -t nextcloud-alert`
- Full guide: `monitoring/README.md`

## Security notes

- Nextcloud is served over plain HTTP on port 8080. Use it on your LAN or through
  Tailscale. To expose it to the internet, put a reverse proxy with HTTPS in front.
- `01-setup.sh` opens port 8080 in `ufw` if `ufw` is installed.
- Never commit `.env`. The `.gitignore` already excludes it.

## License

MIT, see `LICENSE`.
