# TODO

## Server health monitoring (SHIPPED 2026-08-02, live in production)

End-to-end opt-in monitoring: `broadcast.sh health` (per-minute cron;
hysteresis, jittered server-steered heartbeats, lossy backoff) reports to
sendbroadcast.net, which stores whitelisted status/system facts, shows
them on the dashboard Servers page (friendly detail view, progressive
disclosure), and emails the owner on down/stale/recovery transitions —
from infrastructure that is not the down email platform itself.

Live-fire verified on broadcast.furvur.com (2026-08-02): container
stopped 13:38:52 UTC → two silent probe failures (hysteresis) →
unhealthy sent 13:41:01 (+ down-alert email) → restarted 13:41:22 →
healthy sent 13:42:01 (+ recovery email). Detection-to-alert ~2 minutes,
vs the 2-day silent outage that motivated the feature.

Carried to a future sprint:
- [ ] Auto-remediation tier (second opt-in beyond alerting): host
      supervisor restarts the app container on unhealthy, with
      evidence capture BEFORE restart and a restart budget
      (3/hour → stop and escalate). Design settled in the supervision
      debate: external actor, never container self-monitoring.
- [ ] Log persistence across `compose down` (postmortem friction 9a);
      journald forwarding is the preferred shape.
- [ ] Rails-repo items: procps in the image (friction 9), entrypoint
      exits when Puma dies (cheap exit-based layer; wedges stay with
      the external supervisor).
- [ ] README: list Ubuntu 26.04 as supported (smoke-validated).
- [ ] Dashboard data hygiene: duplicate broadcast.furvur.com
      registration (two licenses; only one can ever report).

## Support tooling (from broadcast/TROUBLESHOOT.md, firstborngroup 520 case)

Source: 2-day outage where Puma died inside the app container while Thruster
(PID 1) kept serving 502s — `docker ps` showed "Up", restart policies never
fired, and the standard remediation (`broadcast.sh restart`) destroyed the
container logs that held the evidence.

- [x] **`./broadcast.sh diagnose`** — shipped TDD-first (2026-08-01;
      tests/unit/test_diagnose.sh written red, then scripts/diagnose.sh).
      Captures FULL container logs FIRST (restart wipes them), a
      noise-filtered app log, docker/system state, kernel OOM check, and
      layered health probes (Puma direct via docker exec, Thruster HTTP,
      HTTPS origin via curl --resolve) with an interpretation summary that
      flags the Thruster-up/Puma-down fingerprint and only recommends
      restart AFTER evidence is captured. Produces a tarball for a
      one-round-trip support email. Consider a smoke-test phase exercising
      it on a real VM in a future pass.
- [ ] **App container healthcheck + restart-on-unhealthy** — compose has no
      healthcheck on `app`, and Thruster surviving Puma's death means
      `restart: always` never triggers. Decide the mechanism deliberately:
      compose `healthcheck` on `localhost:3000/up` is visibility only — the
      restart action needs either the monitor/trigger cron reacting to
      `unhealthy`, or the image entrypoint exiting when Puma dies (Rails-repo
      change). Validate in the smoke VM.
- [ ] **Stop `broadcast.sh restart` from destroying logs** — the systemd unit
      uses `ExecStop=docker compose down`, which removes containers and all
      their logs. Options: forward logging to journald, mount a log volume,
      or ExecStop=stop (semantics change — needs thought). Interim
      mitigation: diagnose captures logs before any restart advice.

# TODO: Test Coverage Expansion

Goal: real test coverage for every management script, so a regression in the
deploy/ops tooling is caught before it ships to customer servers.

Context: the test suite previously contained "pattern tests" that asserted on
re-implemented copies of script logic rather than the scripts themselves.
Those have been converted to execute the real code via the sandbox harness
(`tests/script_harness.sh`), which rewrites only the hardcoded
`/opt/broadcast` / `/etc/systemd/system` path constants at load time and
shims external commands via PATH. No implementation files were modified.

## Completed (2026-07-31)

- [x] `tests/script_harness.sh` — sandbox harness: loads unmodified scripts
      against a scratch root, logs all external command calls for
      order/argument assertions
- [x] Convert `tests/unit/test_version_functions.sh` to real code
      (validate_semantic_version, compare_versions, get_current_version,
      log_version_change cap, set_docker_image arch detection,
      generate_encryption_keys idempotency)
- [x] Convert `tests/integration/test_workflow_patterns.sh` to real code
      (trigger dispatch for all four trigger files, backup_database archive +
      checksum + retention, upgrade entry sequence, update remote migration)
- [x] Convert `tests/mocks/test_functional_patterns.sh` to real code
      (validate_license against mocked curl — 200/401/500/malformed/partial
      responses; load_registry_info)
- [x] New `tests/unit/test_upgrade_downgrade.sh` — downgrade validation,
      stop→update→re-exec sequencing, full `_upgrade_continue` /
      `_downgrade_continue` behavior (service installs, key backfill,
      version history)
- [x] Smoke harness: `run_install_state_checks` phase verifying the
      security/system half of install.sh (UFW, fail2ban, swap, UTC/chrony,
      unattended upgrades, docker group, sudoers, ownership, update cron,
      logrotate, systemd units, arch-correct `.image`, inotify-tools)
- [x] READMEs updated so coverage claims match what tests actually execute
- [x] `tests/unit/test_monitor.sh` — real monitor() with shimmed metric
      commands; JSON validity, all keys/values, unknown-version fallback,
      write-as-broadcast-user
- [x] `tests/unit/test_broadcast_routing.sh` — real main() dispatch: no-args
      help, unknown command exit 1, downgrade/logs argument validation,
      version forwarding to upgrade/_continue commands, restore file+flag
      forwarding, install pinning the image to :latest first
- [x] `tests/unit/test_system_services.sh` — real create_broadcast_service
      (unit file content, disable/reload/enable sequencing) and the real
      post-upgrade-cleanup.sh stability gate (prunes when stable, skips on
      down or freshly-restarted containers)

- [x] Smoke test validated green on Ubuntu 24.04 AND 26.04 (2026-08-01):
      78/78 checks including the new install-state phase. First run exposed
      quoting bugs in 4 of the new checks (vm_exec_root's nested
      vagrant-ssh/sudo quoting mangles single-quoted patterns — keep remote
      grep patterns quote-free) plus an over-strict ownership scan; all were
      test bugs, fixed. The installer itself passed everything on both
      versions.

## Remaining
- [x] **`change_installation_domain` smoke phase** — always-on final smoke
      phase feeding the interactive prompts from a file: invalid domain
      rejected, cancellation leaves state untouched, confirmed change updates
      .domain/TLS_DOMAIN/.domain_history and the system recovers
      (validation run on Ubuntu 24.04 in progress 2026-08-01)
- [x] **CI wiring** — already in place: `.github/workflows/tests.yml` runs
      `bash tests/run_all_tests.sh -v` on push/PR (20-min timeout). All new
      suites are registered in that runner, so CI picks them up with no
      workflow changes needed.

## Explicitly not worth testing (agreed scope)

- `start.sh` / `stop.sh` / `restart.sh` — one-line systemctl wrappers
- `logs.sh` streaming — already covered by `tests/unit/test_logs_streaming.sh`

## Known limitation

The harness's path-rewrite means a typo in the `/opt/broadcast` literal
itself would slip past the sandbox tests; only the smoke test (which uses the
real paths on a real VM) catches that class of bug.

## Running the tests

```bash
./tests/run_all_tests.sh              # full local suite (seconds)
./tests/run_all_tests.sh -v           # verbose
./tests/run_all_tests.sh -s unit      # one suite: unit | integration | mocks
bash tests/unit/test_upgrade_downgrade.sh   # any file standalone

# VM smoke test (~3-5 min/version; needs Vagrant + QEMU + license key)
./tests/smoke/test_multipass_smoke.sh --ubuntu 24.04 --local
```
