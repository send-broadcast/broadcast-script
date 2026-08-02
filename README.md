# Broadcast Installer

## Introduction

This script installs the Broadcast script on a Linux server. It sets up the necessary user and group, configures sudo for passwordless access, and ensures the script is executable.

## System Requirements

- Ubuntu Server 24.04 (fresh install)
- Minimum 2GB RAM
- Minimum 40GB disk space

## Usage

Run the following commands as root:

```bash
rm -rf /opt/broadcast && git clone https://github.com/send-broadcast/broadcast-script.git /opt/broadcast && cd /opt/broadcast && chmod +x broadcast.sh && ./broadcast.sh install
```

## Commands

All commands are run as root from `/opt/broadcast`:

```bash
cd /opt/broadcast && ./broadcast.sh <command>
```

### Service management

- **`start`** / **`stop`** / **`restart`** — Start, stop, or restart the Broadcast services (the app, background job processor, and database containers, managed via systemd). Always use these instead of raw `docker` commands — they are the supported path.
- **`logs <app|job|db>`** — Follow the live logs of a specific service: `app` (web application), `job` (background jobs), or `db` (PostgreSQL).

### Installing and updating

- **`install`** — Install Broadcast onto a fresh Ubuntu server: creates the `broadcast` user, configures the firewall (ports 22/80/443), fail2ban, swap, automatic security updates, Docker, the systemd service, and monitoring cron jobs. Reboots the server when finished.
- **`update`** — Update these management scripts to the latest version (`git pull`). Runs automatically once a day via cron.
- **`upgrade [version]`** — Upgrade Broadcast itself: updates the scripts, pulls new Docker images, and restarts the system. With no version it upgrades to the latest release; pass a version (e.g. `upgrade 1.2.3`) to pin a specific one.
- **`downgrade <version>`** — Roll Broadcast back to a specific earlier version (e.g. `downgrade 1.2.0`). The version argument is required. Only downgrade after confirming compatibility with support.

### Backup and restore

- **`backup_database`** — Create a timestamped, compressed backup of the primary database with a `.sha256` integrity checksum, and make it available in the app's storage for download. Only the newest backup is kept on disk.
- **`restore <file> [--yes]`** — Restore the primary database from a backup tarball. Verifies the backup's checksum before touching anything, refuses backups made on a newer Broadcast version than the installed one, and runs database migrations afterwards. Prompts for confirmation unless `--yes` is passed. **This replaces all data in your database.**
- **`backup`** — Reserved for full backups to S3; not yet implemented. Use `backup_database` today.

### Diagnostics

- **`diagnose`** — Collect a support bundle: container logs, system state, and layered health checks, packed into a tarball you can attach to a support email. See Troubleshooting below.
- **`fix`** — Repair installation drift: recreates missing directories, restores permissions and ownership, reinstalls and starts missing services, re-adds missing cron entries, and generates missing encryption keys. Safe to run at any time; it only changes what is actually wrong and reports each check as `ok:` or `fixed:`.
- **`monitor`** — Report host metrics (CPU, memory, disk) to the Broadcast dashboard. Runs automatically every minute via cron; you should not need to run it by hand.
- **`health`** — Report server health to your sendbroadcast.net dashboard, if you have enabled monitoring for this server there. Sends only health status codes and basic system facts (disk, memory, version, whether a restart is pending) — never logs, configuration, or subscriber data. Runs automatically every minute via cron; when monitoring is not enabled, it stays quiet apart from an hourly check-in to see if it has been turned on.
- **`trigger`** — Check for and execute actions requested from the Broadcast web interface (upgrades, backups, domain changes). Also runs automatically every minute via cron.

### Configuration

- **`change_installation_domain`** — Change the primary domain of this installation. Updates the configuration and SSL certificates and restarts services; make sure your DNS points at this server first.
- **`validate_license`** — Re-validate your license key against the licensing server and refresh registry credentials.
- **`generate_encryption_keys`** — Generate the Active Record encryption keys in `app/.env` if they are missing (normally created during install; needed for encrypted fields such as API keys).
- **`help`** — Show the list of available commands.

## Troubleshooting

If your installation is misbehaving (site down, errors, slow responses), run:

```bash
cd /opt/broadcast && ./broadcast.sh diagnose
```

This checks each layer of your installation, prints a report you can copy
straight into a support email, and saves a tarball with the full container
logs under `/opt/broadcast/logs/` in case support needs more detail. Run it
**before** restarting anything — restarting destroys the container logs
that explain what happened.

## License

This script is intended for customers of Broadcast. Please refer to the license that came with your Broadcast product for the terms of use.
