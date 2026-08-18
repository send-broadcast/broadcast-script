# Local auto-recovery.
#
# Runs from cron every minute, probes Puma directly, and restarts the stack when
# Puma has been unreachable for long enough that it is not coming back on its
# own.
#
# Why this is separate from health.sh. They answer different questions and have
# different privacy contracts. health.sh is TELEMETRY: it reports upstream to
# sendbroadcast.net and is opt-in, with a kill switch that promises zero
# phone-home. Recovery is LOCAL: it talks to nothing, and an install that opted
# out of monitoring still deserves to come back up. Entangling them would mean
# either leaking data from installs that opted out, or leaving those installs
# permanently un-recovered.
#
# Why the Puma probe specifically. Customer incident 2026-08-15: the app
# exhausted its file descriptors and stopped serving, but the process never
# exited. The container stayed Running, `restart: always` never fired, and
# `docker ps` showed it Up for the whole 31-minute outage, so nothing in
# Docker's model could see the failure. Thruster answered on :80 throughout --
# it was serving 502s. The only probe on the box that saw through it was a
# direct request to Puma on :3000, which is what this does.

RECOVERY_FAILURE_THRESHOLD=3
RECOVERY_COOLDOWN_SECONDS=900
RECOVERY_DEFAULT_COMMAND="systemctl restart broadcast"

# Probes a freshly started container gets before recovery may act on it, on top
# of the failure threshold. Counted in PROBES rather than seconds because cron
# runs this once a minute, so the two are the same unit, and because tests can
# then exercise the boundary without sleeping through it.
#
# A cold boot including the full migration suite measures around 9 seconds, so
# ten probes is generous. It is meant to cover the slow cases -- a migration
# rebuilding an index on a large table -- not the ordinary one.
RECOVERY_BOOT_GRACE_PROBES=10

# EXTENSION POINT — admin alerting.
#
# Today this writes a local line to /opt/broadcast/logs/recovery.log, which is
# collected by `./broadcast.sh diagnose`. It is deliberately the ONLY place that
# knows how a recovery is announced, so alerting can be added here without
# touching the decision logic above it.
#
# When adding a channel, keep these properties:
#   - never abort recovery: the restart matters more than the announcement, so
#     a failing notifier must not take the server down with it
#   - respect .no_health_reports for anything that leaves the machine; that
#     flag is a promise of zero phone-home, and an alert is phone-home
#   - stay quiet in steady state: this fires once per recovery, not per probe
_recovery_notify_admin() {
  local reason="$1"
  local log_file="/opt/broadcast/logs/recovery.log"

  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  echo "[$(date)] RECOVERY: $reason" >> "$log_file" 2>/dev/null || true

  # Future channels go here (email via the dashboard, webhook, syslog).
  # Guard anything outbound:
  #   [ -f /opt/broadcast/.no_auto_recovery_alerts ] && return 0
  #   [ -f /opt/broadcast/.no_health_reports ] && return 0
  return 0
}

_recovery_write_state() {
  cat > "$state_file.tmp" <<STATE
consecutive_failures=$consecutive_failures
last_recovery_at=$last_recovery_at
container_started_at=$container_started_at
probes_since_start=$probes_since_start
STATE
  mv "$state_file.tmp" "$state_file"
}

function recover() {
  local state_file="/opt/broadcast/.recovery_state"

  # Operator kill switch: some admins want to be the only thing that restarts
  # their server. Checked before anything else so it is a true no-op.
  if [ -f /opt/broadcast/.no_auto_recovery ]; then
    return 0
  fi

  local now
  now=$(date +%s)

  local consecutive_failures=0 last_recovery_at=0
  local container_started_at="" probes_since_start=0
  if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
  fi

  local container="${RECOVERY_CONTAINER:-app}"

  # GUARD 1 -- is there a container to recover at all?
  #
  # `upgrade` runs: systemctl stop broadcast (compose down removes the
  # containers) -> docker compose pull -> systemctl start broadcast. Between
  # the stop and the start there is no app container, and the image pull sits in
  # the middle, so that window is minutes. A probe fails there because there is
  # nothing to probe, and restarting the service into a running upgrade fights
  # the thing that removed the container in the first place.
  #
  # An absent or stopped container is a deploy, a stop, or an upgrade. Docker's
  # own restart: always and the operator own that case; recovery stays out. The
  # incident this exists for looked nothing like it: the container was Running
  # the entire time.
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) || running=""
  if [ "$running" != "true" ]; then
    consecutive_failures=0
    probes_since_start=0
    _recovery_write_state
    return 0
  fi

  # GUARD 2 -- is this container old enough to judge?
  #
  # A container that just started is booting: migrations run before Puma
  # listens, and to this probe that is indistinguishable from the outage. Track
  # the instance by StartedAt; a change means a new container, so the count
  # starts again. That also stops recovery restarting the container it just
  # restarted.
  local started_at
  started_at=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null) || started_at=""
  if [ "$started_at" != "$container_started_at" ]; then
    container_started_at="$started_at"
    consecutive_failures=0
    probes_since_start=0
  fi
  probes_since_start=$((probes_since_start + 1))

  # The probe that saw the outage. Not through Thruster: Thruster answers 502
  # perfectly happily while there is nothing behind it.
  local puma
  puma=$(docker exec "$container" curl -s -o /dev/null \
    -w "%{http_code}" -m 10 http://localhost:3000/up 2>/dev/null) || puma="000"

  if [ "$puma" = "200" ]; then
    consecutive_failures=0
    _recovery_write_state
    return 0
  fi

  # Hysteresis. A single failed probe is a deploy, a slow boot, or a container
  # mid-recreate. Restarting on one would turn every ordinary event into a
  # self-inflicted outage.
  consecutive_failures=$((consecutive_failures + 1))
  if [ "$consecutive_failures" -lt "$RECOVERY_FAILURE_THRESHOLD" ]; then
    echo "[$(date)] recovery: Puma probe failed ($puma), $consecutive_failures/$RECOVERY_FAILURE_THRESHOLD before acting"
    _recovery_write_state
    return 0
  fi

  if [ "$probes_since_start" -lt "$RECOVERY_BOOT_GRACE_PROBES" ]; then
    echo "[$(date)] recovery: Puma unreachable, but this container has only been up for $probes_since_start/$RECOVERY_BOOT_GRACE_PROBES probes; treating it as still booting"
    _recovery_write_state
    return 0
  fi

  # Flap guard. A server that cannot stay up should be restarted once and then
  # left alone: restarting it every three minutes destroys the evidence, and
  # each restart kills whatever send was in flight.
  local since_last=$((now - last_recovery_at))
  if [ "$last_recovery_at" -gt 0 ] && [ "$since_last" -lt "$RECOVERY_COOLDOWN_SECONDS" ]; then
    echo "[$(date)] recovery: Puma still unreachable, but a restart ${since_last}s ago is within the ${RECOVERY_COOLDOWN_SECONDS}s cooldown; not restarting"
    _recovery_write_state
    return 0
  fi

  local reason="Puma unreachable on :3000 for $consecutive_failures consecutive probes (last code: $puma); restarting the stack"
  echo "[$(date)] recovery: $reason"

  # Overridable so integration tests can drive a container instead of systemd.
  ${RECOVERY_COMMAND:-$RECOVERY_DEFAULT_COMMAND} || \
    echo "[$(date)] recovery: restart command failed"

  last_recovery_at=$now
  consecutive_failures=0
  _recovery_write_state

  _recovery_notify_admin "$reason"

  return 0
}
