# Next Sprint

Carried from the server-monitoring sprint (closed 2026-08-03). Context and
history in TODO.md; incident background in the broadcast repo's
TROUBLESHOOT.md (untracked).

## 1. Log persistence across `compose down` — DONE (2026-08-03, TDD)

Shipped exactly in the recommended shape: journald logging driver in the
production compose file (`journalctl CONTAINER_NAME=app`), diagnose
captures journal-first with a `docker logs` fallback for pre-migration
containers, and `ExecStop` semantics untouched. Validated on a real VM:
restart-survival phase (marker survives compose down in journald, absent
from the fresh container) plus a `--test-upgrade` run proving web-UI log
streaming still works under journald via dual logging. Rollout: nightly
update delivers the compose file; the driver applies at the next container
recreation (every restart recreates, since ExecStop is `down`). Full
detail in TODO.md.

## 2. Auto-remediation supervisor tier

Parked with a settled design (see the supervision debate + TODO.md entry)
until real alert-traffic history exists to tune the restart budget against.
Reaffirmed in the pragmatism sanity check (2026-08-03).

Settled design, for when it's picked up:
- Actor: the host supervisor (existing cron cadence) — never container
  self-monitoring.
- Evidence capture BEFORE any restart (mini-diagnose bundle).
- Restart budget with escalation: e.g. 3/hour, then stop and alert
  "needs a human" — tune the numbers against observed alert frequency.
- Guards: act only while broadcast.service is active (never race a
  deliberate stop, upgrade, or restore).
- Observable: every auto-restart reported through the health channel.
- A second, separate opt-in (distinct from alerting), server-steered via
  the health response — the same pattern as heartbeat_interval.
- Prerequisite finding already banked: exit-on-death self-heals natively
  (~1s, live-verified) — this tier only needs to handle WEDGES.

## 3. Upgrade hardening: fail-safe, explicit migrations, readiness check

Motivated by a customer report (Bilal Iftikhar, firstborngroup, 2026-08-04):
servers appeared down after upgrading to v2.25.0 until a manual
`./broadcast.sh restart`. ROOT CAUSE CONFIRMED from their diagnose bundle:
a hand-edited docker-compose.yml (postgres port binding) made the upgrade's
`git pull` abort AFTER the `systemctl stop` — the site went down with the
version unchanged, and the same dirty tree had been silently killing their
nightly script update for weeks (stuck at 9f9b148). The registry-race and
big-migration theories were plausible but wrong for this incident; the
structural stop→start window gap was real either way.

SHIPPED on upgrade-hardening (2026-08-04, TDD):
- Fail-safe EXIT trap in upgrade/downgrade — a mid-window failure rolls
  .image back and restarts the previous version from the local image
  cache; exits nonzero with the original error. (smoke Phase 7b red→green)
- Update-before-stop reorder — a git failure now aborts with the site
  still serving.
- Dirty-tree detection in update — refuses the pull, names the modified
  files, points at docker-compose.override.yml.
- Compose override support — the systemd unit no longer pins the compose
  file with -f, so docker-compose.override.yml (overlay semantics, Simon's
  explicit decision — never full-file replacement) is honored; documented
  in the README incl. the `!override` list caveat; gitignored; reported by
  diagnose/fix. (smoke Phase 7c: full incident + remediation end-to-end)
- Diagnose gaps closed: git status + override contents + update/trigger
  log tails captured; cron liveness keyed off the monitor heartbeat
  (system.json mtime) instead of the false-positive log mtimes.

Still open from the original design (not needed for this incident):
- **Explicit migration step**: after the pull, before start, run
  `docker compose run --rm app bin/rails db:prepare` (as broadcast, with
  .image sourced). Upgrade then blocks on and surfaces migration failures;
  the app boots with schema current; the app/job entrypoint migration race
  becomes a no-op. Verify on a VM that `compose run` bringing up postgres
  early coexists with the subsequent `compose up` (same project). Out of
  scope: rolling migrations back on downgrade.
- **Readiness check**: after `systemctl start`, poll localhost until the
  app answers, with progress output ("migrations can take several minutes
  on large databases"); print success only when the site actually serves.
  On timeout, print next steps (`logs app`, `diagnose`) instead of the
  current unconditional success message that fires while the site is down.
- Tests when picked up: unit for migrate-step ordering and the readiness
  gate before the success message; smoke coverage of a slow-migration
  upgrade (the readiness poll must keep reporting progress, not time out).
