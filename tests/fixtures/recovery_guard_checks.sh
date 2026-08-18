#!/bin/bash
# Runs INSIDE a Linux container and exercises recover.sh's flock and timeout
# guards for real.
#
# These cannot be checked from the host: flock(1) and timeout(1) do not exist on
# macOS, so a host-run test skips there and executes for the first time on CI.
# Running inside the container makes them identical everywhere.
#
# recover.sh shells out to `docker`, which is not available in here, so a stub
# stands in for it. That is the right trade: these guards are about locking and
# timeouts, not about Docker. The docker-facing behaviour is covered by the
# host-side tests that drive real containers.
#
# THE LOCK MUST BE THE ONLY VARIABLE. An earlier version of this fixture ran its
# locked tick after a restart had already reset the failure counter and started
# the 15-minute cooldown, so that tick could not have restarted anything with or
# without a lock -- it passed with the guard deliberately sabotaged. The
# sequence below banks exactly enough failures to be one tick away from acting,
# then runs that tick twice: once locked, once not.
#
# Contract: prints RESULT key=value lines the caller parses.

ROOT=/tmp/recovery-guard
rm -rf "$ROOT"; mkdir -p "$ROOT/logs" "$ROOT/bin"

sed "s|/opt/broadcast|$ROOT|g" /src/scripts/recover.sh > "$ROOT/recover.sh"

# Stub docker. Probe outcome is driven by flag files so one stub covers the
# healthy warm-up, the failing ticks, and the hang.
cat > "$ROOT/bin/docker" <<'DOCKER'
#!/bin/bash
case "$*" in
  *inspect*State.Running*) echo true ;;
  *inspect*State.StartedAt*) echo 2026-08-01T00:00:00Z ;;
  *exec*)
    if [ -f /tmp/recovery-guard/HANG ]; then sleep 120; fi
    if [ -f /tmp/recovery-guard/HEALTHY ]; then echo 200; else echo 000; exit 7; fi ;;
esac
DOCKER
chmod +x "$ROOT/bin/docker"

printf '#!/bin/sh\necho RESTARTED >> %s/restarts.log\n' "$ROOT" > "$ROOT/bin/fake-restart"
chmod +x "$ROOT/bin/fake-restart"
export PATH="$ROOT/bin:$PATH"

# Must exist before the first read: grep -c on a missing file prints nothing,
# which reads as an empty count rather than zero.
: > "$ROOT/restarts.log"

# Each tick is its own process, exactly as cron runs it. Sourcing and calling
# recover repeatedly in ONE shell would hold the lock fd open across calls and
# test something cron never does.
tick() {
  bash -c "source $ROOT/recover.sh; RECOVERY_COMMAND=fake-restart recover" >/dev/null 2>&1
}
restarts() { grep -c RESTARTED "$ROOT/restarts.log" 2>/dev/null || echo 0; }

# Warm up past the 10-probe boot grace with a healthy probe, so the boot grace
# cannot be what suppresses the ticks below.
touch "$ROOT/HEALTHY"
for _ in $(seq 1 12); do tick; done
rm -f "$ROOT/HEALTHY"

# Bank two failures. One more would act.
tick; tick
echo "RESULT primed_restarts=$(restarts)"

# The tick that would act, with the lock held by another process.
(
  exec 9>"$ROOT/.recovery_state.lock"
  flock -n 9 && tick
)
echo "RESULT lock_held_restarts=$(restarts)"

# The same tick, lock free. Proves the only difference above was the lock.
tick
echo "RESULT lock_free_restarts=$(restarts)"

# A probe that hangs, against a 5s ceiling.
touch "$ROOT/HANG"
started=$(date +%s)
bash -c "source $ROOT/recover.sh; RECOVERY_DOCKER_TIMEOUT=5 RECOVERY_COMMAND=fake-restart recover" >/dev/null 2>&1
echo "RESULT wedged_elapsed=$(( $(date +%s) - started ))"
