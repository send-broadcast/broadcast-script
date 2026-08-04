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

Motivated by a customer report (Bilal, 2026-08-04): servers appeared down
after upgrading to v2.25.0 until a manual `./broadcast.sh restart`. Two
suspected mechanisms, neither confirmed from their servers yet (diagnose
bundle requested): the pre-fix registry race at startup (shipped 2026-08-03
in the boot-resilience commit), and large migrations making the app look
hard-down while `db:prepare` runs. Regardless of which one it was, the
upgrade path has structural gaps this item closes. TDD like items 1–2.

Design, settled 2026-08-04:
- **Fail-safe trap**: any error between `systemctl stop` (upgrade.sh:9)
  and `systemctl start` (upgrade.sh:96) currently strands the server down
  under `set -e`. Trap errors and attempt `systemctl start broadcast` so a
  failed upgrade leaves the OLD version serving. The trap must exist in
  both `upgrade()` and `_upgrade_continue()` — the `exec` between them
  wipes the first — and must still exit nonzero and report loudly, never
  masking the failure. Same treatment for downgrade.
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
- Tests: unit in test_upgrade_downgrade.sh (trap presence + sequencing,
  migrate-step ordering, readiness gate before the success message); smoke
  phase that kills an upgrade mid-window and asserts the service comes
  back on the old version.
