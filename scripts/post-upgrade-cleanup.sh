#!/bin/bash
#
# Post-upgrade Docker image cleanup
# Waits until all containers have been running for STABILITY_SECONDS, then
# prunes unused images.
# Triggered by: systemctl start broadcast-post-upgrade-cleanup.service
#
# This POLLS for stability instead of making a single check. The service is
# scheduled in the same breath as the stack start, so a one-shot check after
# sleep(STABILITY_SECONDS) always saw container uptime a few seconds under
# the threshold (the containers start a moment after the timer does) and
# skipped — silently, every upgrade, forever. Production evidence: four
# consecutive "running for 53s/54s (need 60s). Skipping cleanup." entries
# and 12.7GB of unpruned images.

CONTAINERS=("app" "job" "postgres")
STABILITY_SECONDS=60
MAX_WAIT_SECONDS=600
POLL_SECONDS=30

log() {
  echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') - $1"
}

log "Post-upgrade cleanup started; waiting for ${STABILITY_SECONDS}s of container stability (up to ${MAX_WAIT_SECONDS}s)..."

wait_started_epoch=$(date +%s)

while :; do
  all_stable=true
  reason=""

  for container in "${CONTAINERS[@]}"; do
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
    if [ "$status" != "running" ]; then
      all_stable=false
      reason="Container '$container' is not running (status: ${status:-not found})"
      break
    fi

    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null)
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    uptime_seconds=$((now_epoch - started_epoch))

    if [ "$uptime_seconds" -lt "$STABILITY_SECONDS" ]; then
      all_stable=false
      reason="Container '$container' has only been running for ${uptime_seconds}s (need ${STABILITY_SECONDS}s)"
      break
    fi
  done

  if [ "$all_stable" = true ]; then
    log "All containers stable. Pruning unused Docker images..."
    docker image prune -af
    log "Docker image cleanup completed."
    exit 0
  fi

  now_epoch=$(date +%s)
  if [ $((now_epoch - wait_started_epoch)) -ge "$MAX_WAIT_SECONDS" ]; then
    log "$reason"
    log "Skipping cleanup: containers did not stabilize within ${MAX_WAIT_SECONDS}s."
    exit 0
  fi

  sleep "$POLL_SECONDS"
done
