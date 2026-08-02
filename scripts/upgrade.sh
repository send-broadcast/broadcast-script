function upgrade() {
  local target_version="${1:-}"

  if [ -n "$target_version" ]; then
    echo -e "\e[33mStopping Broadcast service for version-specific upgrade to $target_version...\e[0m"
  else
    echo -e "\e[33mStopping Broadcast service...\e[0m"
  fi
  systemctl stop broadcast

  echo -e "\e[33mUpdating Broadcast scripts...\e[0m"
  /opt/broadcast/broadcast.sh update

  # Re-exec with updated scripts to ensure new code runs
  echo -e "\e[33mReloading with updated scripts...\e[0m"
  exec /opt/broadcast/broadcast.sh _upgrade_continue "$target_version"
}

function _upgrade_continue() {
  local target_version="${1:-}"
  local current_version=$(get_current_version)

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

  # Set docker image for target version
  echo -e "\e[33mSetting Docker image for version $target_version...\e[0m"
  set_docker_image "$target_version"

  # Upgrade the Broadcast containers
  echo -e "\e[33mPulling Broadcast containers for version $target_version...\e[0m"
  su - broadcast -c 'cd /opt/broadcast && set -a && source .image && set +a && docker compose pull'

  echo -e "\e[33mRestarting Broadcast service...\e[0m"
  systemctl start broadcast

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
