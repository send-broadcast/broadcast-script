Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project ships as a rolling release (Docker image tag `latest`) and does not
yet use version tags, so all entries live under `[Unreleased]`. When a tagged
release cadence begins, dated version sections will be promoted from this list.

## [Unreleased]

### Added
- `./broadcast.sh monitor-enable` / `monitor-disable` control health reporting from the server itself. Disable is a verifiable zero-phone-home switch (creates `/opt/broadcast/.no_health_reports`; the reporter exits immediately while it exists — not even the hourly check-in is sent). Enable removes it, clears any backoff, and checks in immediately.
- Health reporting transmission is now opt-in, not just storage: until the dashboard confirms monitoring is enabled, the install sends only an hourly key+domain handshake with no status, probe, or system data. Installs already reporting are migrated seamlessly.
- `./broadcast.sh health` reports server health to the sendbroadcast.net dashboard for servers that opted in to monitoring there (new cron entry, every minute). Probes each layer (app, web server, HTTPS), applies 3-strike hysteresis so restarts and deploy blips never false-alarm, sends status transitions immediately and steady-state heartbeats on a server-steered interval, spreads fleet traffic with per-domain jitter, and backs off exponentially (dropping reports rather than queuing) when the dashboard is unreachable. Payload is status codes and basic system facts only (disk, memory, load, cores, version, OS, reboot-pending) — never logs, configuration, or subscriber data — and non-opted-in servers stay silent apart from an hourly opt-in check.
- `./broadcast.sh fix` repairs installation drift idempotently: recreates missing directories, restores ownership and executable bits (including the watcher/cleanup helper scripts), the sudoers entry and docker group membership, regenerates a lost `.image` file pinned to the installed version, restores the broadcast user's registry login from stored credentials, installs/enables/starts missing systemd units (verifying each action took effect — a start that did not stick is reported FAIL, never claimed as fixed), recreates the logrotate config, re-adds missing cron entries without touching existing ones, and repairs app/.env essentials (encryption keys, SECRET_KEY_BASE, TLS_DOMAIN from `.domain`, DATABASE_PASSWORD restored from db/.env). Unfixable problems exit 1 and say so: missing Docker or compose plugin (points at a full install), a lost db/.env (the database password is unrecoverable — contact support before restarting), or mismatched database passwords (cannot know which is correct).
- README now documents every `./broadcast.sh` command with what it does and when to use it, grouped by service management, install/update, backup/restore, diagnostics, and configuration.
- `./broadcast.sh diagnose` collects a one-shot support bundle: full container logs (captured first, since a restart destroys them), a noise-filtered app log that surfaces Puma crashes, identity and a brew-doctor-style permission check (ownership, docker group, sudoers), system specs (OS, CPU, memory, disk and inodes, time sync), top processes, port listeners with a warning when a non-Docker web server holds 80/443, live SSL certificate status, Broadcast/image versions with container restart counts, a kernel OOM check, and layered health probes (Puma direct, Thruster HTTP, HTTPS origin via `--resolve`) with an interpretation summary that flags the "container Up but app dead" fingerprint. Also collects job-queue depth and failed-job counts (via postgres, so a dead app container cannot hide its own queue), database connection/size/slow-query state with a pending-migrations check, backup freshness with staleness warnings, per-directory disk attribution, an incident timeline (version/domain history, reboots, failed units, unattended upgrades, container OOM flags), cron liveness, error-only views of the job and postgres logs, and outbound network checks (license server reachability, SMTP egress — commonly blocked on cloud hosts). Prints a delimited copy-paste report (summary, probes, container/system state, filtered log tail) for the support email, plus a tarball with the full logs if support needs to dig deeper — collapsing multi-email diagnostic round-trips into one command.
- Backups now write a `.sha256` checksum sidecar next to the tarball, and `./broadcast.sh restore` verifies it before touching the system — a backup corrupted in transit (offsite download, copy between hosts) is refused before services are stopped. Backups without a sidecar restore as before.

### Fixed
- `./broadcast.sh validate_license` no longer appends duplicate registry credential lines to `.env` on every run — existing `BROADCAST_REGISTRY_*` lines are replaced, and unrelated lines are preserved.
- Automatic post-upgrade Docker image pruning never actually ran: the cleanup service starts alongside the stack, slept exactly the 60s stability threshold, and then found the containers a few seconds too young — so it skipped silently on every upgrade (observed: four consecutive skips and 12.7GB of dead images on a production install). The script now polls until the containers have been stable for 60s (up to 10 minutes) before pruning. the compose file's `pull_policy: always` made `docker compose run app` re-pull the image, but restore runs as root, which has no registry login. Migrations now run with `--pull never` against the local image (guaranteed present — the app was running before the restore stopped it). Found by the new smoke-test backup/restore cycle; this very likely broke every real-world restore's migration step until now.
- `./broadcast.sh restore` no longer aborts midway (with services stopped) on current installs: it copied the dump via `docker cp` to a container named `broadcast-postgres`, but the compose file names the container `postgres`. The copy now goes through `docker compose cp` against the postgres service, which is immune to container-name drift.
- Restore steps (loading `.image`, starting postgres, copying the dump, post-restore migrations) now fail the restore explicitly with a clear error instead of falling through — a failed step can no longer end in a "RESTORE COMPLETE" banner with nothing restored.

### Added
- `./broadcast.sh restore <file> --yes` (or `BROADCAST_ASSUME_YES=1`) skips the interactive confirmation so restores can run non-interactively from automation.
- GitHub Actions CI running the full test suite (`tests/run_all_tests.sh`), including the Docker-based backup/restore integration tests, on every push and pull request.
- Smoke test now clones the canonical remote (`https://github.com/send-broadcast/broadcast-script.git`) by default so it exercises exactly what end users install; pass `--local` to fall back to copying the local working tree.
- Smoke test now runs against Ubuntu 24.04 and 26.04 by default, with a `--ubuntu VERSION` flag to filter to one and per-version pass/fail reporting in the summary.

### Changed
- README now lists Ubuntu Server 26.04 alongside 24.04 as a supported platform (both are exercised by the VM smoke suite).
- `./broadcast.sh validate_license` now prints an operator summary after validating: license name and status, buyer (masked email), masked key, server usage (e.g. "2 of 5 used"), this server's registration plus other registered domains, installed vs latest version with an upgrade hint, and whether health monitoring is enabled for this server. Older server responses without these fields simply skip the summary.
- `./broadcast.sh monitor` now prints the metrics it wrote when run manually at a terminal, so an interactive run no longer looks like it did nothing. Cron runs remain silent, keeping the per-minute cron log clean.
- Smoke test switched from VMware Fusion to QEMU using HashiCorp-published `cloud-image/ubuntu-{24.04,26.04}` boxes — single trustworthy publisher across both Ubuntu releases, no commercial-license dependency, and 26.04 is available today (bento has not published a 26.04 box yet). Setup now requires `brew install qemu && vagrant plugin install vagrant-qemu` instead of the VMware plugin chain.
- Vagrant-based end-to-end smoke test (`tests/smoke/test_multipass_smoke.sh`) that boots a disposable VM, runs the real installer, and verifies containers, HTTP endpoints, systemd, and cron.
- Auto-prune of unused Docker images after upgrade, gated by a stability check so a freshly broken image is not reaped.
- Auto-migration of installations from the legacy `broadcast` registry namespace to `send-broadcast`.
- Docker-based integration tests for backup and restore (`tests/integration/test_backup_restore.sh`).
- Version-compatibility checking in the backup/restore flow so a restore aborts when the on-disk schema is incompatible with the installed image.
- Database restore from backup (`./broadcast.sh restore`) with automatic post-restore Rails migration.
- Instant log streaming trigger watcher using `inotifywait` for the web UI's on-demand log viewer.
- `restart-jobs` trigger to restart only the job container without bouncing the whole stack.
- On-demand log streaming for the web UI.
- Active Record encryption key generation during install so encrypted fields work out of the box.
- `BROADCAST_MANAGED` environment variable so managed installations can be identified at runtime.

### Changed
- Copyright notice updated to 2024–2026.
- Upgrades now pin to specific image version tags rather than pulling `latest`, so a rollback path exists if a bad image ships.

### Fixed
- Web UI log streaming now survives container recreation. `docker logs -f` is bound to a container instance and exited silently whenever `app`/`job` were recreated on upgrade, leaving the viewer stuck on "Streaming / 0 lines" with a stale `application.log`. Each follow is now supervised in a re-attach loop, the watcher runs a periodic flock-guarded `check_log_streaming_trigger` reconcile (the function existed but was never called) to self-heal a dead streamer, and the trigger watch now includes `modify`/`close_write` so clicking Start over a lingering trigger re-arms streaming. `start_log_streaming` is idempotent and `stop_log_streaming` kills the whole process group.
- Upgrades now restart `broadcast-logs-watcher` so updated `logs.sh` / watcher scripts actually take effect — a long-running watcher otherwise keeps the old code in memory across a `git pull` until reboot. Guarded with `|| true` so it can never abort an upgrade.
- Replaced the removed `ntp` package with `chrony` in the installer so fresh installs succeed on Ubuntu 26.04.
- License API response is validated before being parsed with `jq`, surfacing a clearer error when the API returns non-JSON or an error body.
- Database migrations now run automatically after a restore so the app boots against the restored schema.
- Installer fails fast with a helpful error when `.domain` is missing instead of producing confusing downstream errors.
- `DOCKER_IMAGE` is exported during install and image pulls so ARM hosts pick up the correct registry path.
- Update script now re-execs itself after pulling new code so the rest of the run uses the updated logic instead of the stale in-memory copy.
