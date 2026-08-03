# Next Sprint

Carried from the server-monitoring sprint (closed 2026-08-03). Context and
history in TODO.md; incident background in the broadcast repo's
TROUBLESHOOT.md (untracked).

## 1. Log persistence across `compose down` (postmortem friction 9a)

The last open item from the firstborngroup incident. `restart`/`stop` run
`docker compose down` via the systemd unit, which REMOVES containers and
destroys their logs — the standard remediation erases the evidence of the
incident it fixes. `diagnose`'s capture-first discipline mitigates but does
not remove the root cause.

Recommended shape: forward the compose `logging` driver to journald — logs
survive container removal, are queryable with `journalctl CONTAINER_NAME=app`,
and `ExecStop` semantics stay untouched (safer than switching `down` to
`stop`). Notes:
- Logging-driver changes take effect on container RECREATION, so rollout
  needs an upgrade/restart cycle to actually apply.
- `docker logs` stops working with the journald driver unless dual-logging
  is available — diagnose's log-capture step must be updated in the same
  change, and tested.
- Validate in the smoke VM: restart the stack, confirm pre-restart log
  lines are still retrievable.

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
