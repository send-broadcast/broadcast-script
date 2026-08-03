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
