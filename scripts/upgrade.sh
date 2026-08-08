# Fail-safe for the stop->start window. broadcast.sh runs under `set -e`,
# so any failure between `systemctl stop broadcast` and the final
# `systemctl start` used to abort the script with the service still
# stopped — a customer-facing outage until a human ran restart
# (2026-08-04 report; reproduced by smoke Phase 7b). The trap converts a
# failed upgrade/downgrade into "previous version still serving": roll the
# image pin back to the version that is already in the local cache, start
# the service, and exit with the original failure code. It must be armed
# separately on both sides of the `exec` re-entry — the process
# replacement discards any armed trap.
_FAILSAFE_PREV_VERSION=""
_FAILSAFE_OPERATION=""

_arm_service_failsafe() {
  _FAILSAFE_OPERATION="$1"
  _FAILSAFE_PREV_VERSION="$(get_current_version)"
  trap _run_service_failsafe EXIT
}

_disarm_service_failsafe() {
  trap - EXIT
}

_run_service_failsafe() {
  local exit_code=$?
  trap - EXIT
  if [ "$exit_code" -eq 0 ]; then
    return 0
  fi

  echo -e "\e[31m${_FAILSAFE_OPERATION} failed (exit ${exit_code}). Restarting the previously installed version so the site stays up...\e[0m"

  # Point .image back at the version whose image is already in the local
  # cache; `pull_policy: missing` then lets the start below succeed with
  # no registry access.
  if [ -n "${_FAILSAFE_PREV_VERSION:-}" ] && [ "$_FAILSAFE_PREV_VERSION" != "unknown" ]; then
    set_docker_image "$_FAILSAFE_PREV_VERSION" || true
  fi

  if systemctl start broadcast; then
    echo -e "\e[33mPrevious version restarted. ${_FAILSAFE_OPERATION} did NOT complete — review the error above and retry.\e[0m"
  else
    echo -e "\e[31mFail-safe restart also failed. Run './broadcast.sh restart', then './broadcast.sh diagnose' if the system stays down.\e[0m"
  fi

  exit "$exit_code"
}

function upgrade() {
  local target_version="" force="" automated=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force="yes" ;;
      --automated) automated="yes" ;;
      *) target_version="$1" ;;
    esac
    shift
  done

  # Preflight BEFORE anything destructive. Stopping the service is the point
  # of no return for work a restart cannot resume — a job mid-batch is killed,
  # not requeued. An automated run defers instead of failing: a nonzero exit
  # here would turn every busy night into cron failure mail, and the queue
  # drains on its own.
  if [ -z "$force" ]; then
    if ! upgrade_preflight ${automated:+--automated} ${target_version:+$target_version}; then
      if [ -n "$automated" ]; then
        return 0
      fi
      return 1
    fi
  fi

  # Update scripts BEFORE stopping the service: a failed git pull (dirty
  # tree from a hand-edited file, unreachable GitHub) then aborts the
  # upgrade with the site still serving — it took a customer's site down
  # when this ran after the stop (2026-08-04).
  echo -e "\e[33mUpdating Broadcast scripts...\e[0m"
  /opt/broadcast/broadcast.sh update

  _arm_service_failsafe "Upgrade"

  if [ -n "$target_version" ]; then
    echo -e "\e[33mStopping Broadcast service for version-specific upgrade to $target_version...\e[0m"
  else
    echo -e "\e[33mStopping Broadcast service...\e[0m"
  fi
  # Close lingering database sessions first so postgres can shut down
  # promptly instead of being SIGKILLed mid-checkpoint (see preflight.sh).
  disconnect_database_clients

  systemctl stop broadcast

  # Re-exec with updated scripts to ensure new code runs
  echo -e "\e[33mReloading with updated scripts...\e[0m"
  exec /opt/broadcast/broadcast.sh _upgrade_continue "$target_version"
}

function _upgrade_continue() {
  local target_version="${1:-}"
  local current_version=$(get_current_version)

  # Re-arm after the exec re-entry: the service is stopped and stays
  # stopped until the start below, so every failure in between needs the
  # fail-safe.
  _arm_service_failsafe "Upgrade"

  if [ -z "$target_version" ]; then
    target_version="latest"
  fi

  # Install post-upgrade cleanup service if not present (for upgrades from older versions)
  if [ ! -f /etc/systemd/system/broadcast-post-upgrade-cleanup.service ]; then
    echo -e "\e[33mInstalling post-upgrade Docker image cleanup service...\e[0m"
    cp /opt/broadcast/scripts/broadcast-post-upgrade-cleanup.service /etc/systemd/system/
    chmod +x /opt/broadcast/scripts/post-upgrade-cleanup.sh
    systemctl daemon-reload
    echo -e "\e[32mPost-upgrade cleanup service installed.\e[0m"
  fi

  # Install log streaming trigger watcher if not present (for upgrades from older versions)
  if ! systemctl is-enabled broadcast-logs-watcher &>/dev/null; then
    echo -e "\e[33mInstalling log streaming trigger watcher...\e[0m"

    # Install inotify-tools if not present
    if ! command -v inotifywait &>/dev/null; then
      apt-get install -y inotify-tools
    fi

    # Install and enable the systemd service
    cp /opt/broadcast/scripts/broadcast-logs-watcher.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable broadcast-logs-watcher
    systemctl start broadcast-logs-watcher
    echo -e "\e[32mLog streaming trigger watcher installed.\e[0m"
  fi

  # A long-running watcher holds the old logs.sh / watcher code in memory, so a
  # git pull of new scripts does not take effect until the service restarts.
  # Restart it here so an upgrade actually delivers script changes. This is
  # auxiliary (read-only docker calls only) and must never abort the upgrade,
  # hence `|| true` under the `set -e` in broadcast.sh.
  echo -e "\e[33mRestarting log streaming trigger watcher to pick up updated scripts...\e[0m"
  systemctl restart broadcast-logs-watcher || true

  # Add the health-reporting cron entry if missing (for upgrades from older
  # versions — existing installs pull new script files via the daily update,
  # but only the upgrade path can add new cron entries on their machines)
  if ! crontab -l 2>/dev/null | grep -q "broadcast.sh health"; then
    echo -e "\e[33mAdding health reporting cron entry...\e[0m"
    (crontab -l 2>/dev/null || true; echo "* * * * * /opt/broadcast/broadcast.sh health >> /opt/broadcast/logs/cron/health.log 2>&1") | crontab -
  fi

  # Add Active Record encryption keys if missing (required for encrypted fields like API keys)
  if ! grep -q "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" /opt/broadcast/app/.env 2>/dev/null; then
    echo -e "\e[33mAdding Active Record encryption keys...\e[0m"
    echo "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env
    echo "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env
    echo "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env
    echo -e "\e[32mActive Record encryption keys added.\e[0m"
  fi

  # The broadcast.service unit was historically written only at install, so
  # template fixes (boot-resilience settings) never reached existing
  # servers. Refresh it here — the service is stopped at this point, and
  # the daemon-reload lands before the start below.
  source /opt/broadcast/scripts/init-services.sh
  if refresh_broadcast_service; then
    echo -e "\e[33mbroadcast.service unit refreshed to the current template.\e[0m"
  fi

  # Set docker image for target version
  echo -e "\e[33mSetting Docker image for version $target_version...\e[0m"
  set_docker_image "$target_version"

  # Upgrade the Broadcast containers
  echo -e "\e[33mPulling Broadcast containers for version $target_version...\e[0m"
  su - broadcast -c 'cd /opt/broadcast && set -a && source .image && set +a && docker compose pull'

  echo -e "\e[33mRestarting Broadcast service...\e[0m"
  systemctl start broadcast

  # The service is running again — the window the fail-safe guards is closed.
  _disarm_service_failsafe

  # Schedule post-upgrade image cleanup (runs after containers stabilize)
  echo -e "\e[33mScheduling post-upgrade Docker image cleanup...\e[0m"
  systemctl start broadcast-post-upgrade-cleanup.service --no-block

  # Log version change to history
  log_version_change "upgrade" "$current_version" "$target_version"

  if [ "$target_version" != "latest" ]; then
    echo -e "\e[32mBroadcast upgrade to version $target_version completed successfully!\e[0m"
  else
    echo -e "\e[32mBroadcast upgrade completed successfully!\e[0m"
  fi
}
