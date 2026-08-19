#!/bin/bash

# Broadcast System Installation and Management Script
#
# This script provides functionality to install, upgrade, reboot, backup, and restore
# Broadcast, the email automation software.

# Usage: ./broadcast.sh {install|upgrade|reboot|backup|restore}

set -e
set -u

function getCurrentDir() {
  local current_dir="${BASH_SOURCE%/*}"
  if [[ ! -d "${current_dir}" ]]; then current_dir="$PWD"; fi
  echo "${current_dir}"
}

function includeDependencies() {
  source "${current_dir}/scripts/common.sh"
  source "${current_dir}/scripts/install.sh"
  source "${current_dir}/scripts/start.sh"
  source "${current_dir}/scripts/stop.sh"
  source "${current_dir}/scripts/restart.sh"
  source "${current_dir}/scripts/backup.sh"
  source "${current_dir}/scripts/restore.sh"
  source "${current_dir}/scripts/preflight.sh"
  source "${current_dir}/scripts/upgrade.sh"
  source "${current_dir}/scripts/downgrade.sh"
  source "${current_dir}/scripts/monitor.sh"
  source "${current_dir}/scripts/diagnose.sh"
  source "${current_dir}/scripts/fix.sh"
  source "${current_dir}/scripts/health.sh"
  source "${current_dir}/scripts/recover.sh"
  source "${current_dir}/scripts/trigger.sh"
  source "${current_dir}/scripts/update.sh"
  source "${current_dir}/scripts/logs.sh"
}

# Single switch for the developer 'edge' channel. Enabling a host means TWO
# gates (kept separate on purpose — the app checks the env flag, the upgrade
# path checks the marker), but the decision is one, so one command sets both:
#   * /opt/broadcast/.edge_enabled           — host accepts automated edge upgrades
#   * BROADCAST_EDGE_ENABLED=1 in app/.env   — app shows the developer-builds card
# The app only reads its env at boot, so both commands restart it by default;
# --no-restart defers that (the env half stays pending until the next restart).
# Strip any BROADCAST_EDGE_ENABLED line from an env file, in pure bash —
# no grep/sed, so it behaves identically on GNU systems and dev machines
# with shimmed tools.
function _remove_edge_env_flag() {
  local env_file="$1" tmp="${1}.tmp" line
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      BROADCAST_EDGE_ENABLED=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$env_file"
  mv "$tmp" "$env_file"
}

function edge_enable() {
  local no_restart=""
  [ "${1:-}" = "--no-restart" ] && no_restart="yes"

  touch /opt/broadcast/.edge_enabled

  local env_file="/opt/broadcast/app/.env"
  touch "$env_file"
  _remove_edge_env_flag "$env_file"
  echo "BROADCAST_EDGE_ENABLED=1" >> "$env_file"

  echo "Edge channel enabled: this host accepts dashboard-triggered upgrades to the unreleased 'edge' build,"
  echo "and the Broadcast UI will show the developer-builds card."
  echo "Dev/throwaway servers only — edge migrations can make returning to a release unsafe."

  if [ -n "$no_restart" ]; then
    echo "Restart skipped (--no-restart): the UI card appears after the next app restart."
  else
    restart
  fi
}

function edge_disable() {
  local no_restart=""
  [ "${1:-}" = "--no-restart" ] && no_restart="yes"

  rm -f /opt/broadcast/.edge_enabled

  local env_file="/opt/broadcast/app/.env"
  [ -f "$env_file" ] && _remove_edge_env_flag "$env_file"

  echo "Edge channel disabled: automated upgrades to 'edge' will be refused again and the UI card is hidden."

  if [ -n "$no_restart" ]; then
    echo "Restart skipped (--no-restart): the UI card disappears after the next app restart."
  else
    restart
  fi
}

function display_help() {
  echo "Usage: $0 {install|update|upgrade|downgrade|restart|stop|start|backup|restore|help|monitor|trigger|change_installation_domain}"
  echo
  echo "Commands:"
  echo "  install                  Install Broadcast onto a fresh Ubuntu server"
  echo "  update                   Update Broadcast scripts"
  echo "  upgrade [version]        Upgrade Broadcast images and restart the system"
  echo "                          Optional version parameter (e.g., upgrade 1.2.3)"
  echo "                          'upgrade edge' installs the unreleased main-branch"
  echo "                          build (dev/throwaway servers only)"
  echo "  downgrade <version>      Downgrade Broadcast to a specific version"
  echo "                          Requires version parameter (e.g., downgrade 1.2.0)"
  echo "  restart                  Reboot Broadcast services"
  echo "  stop                     Stop Broadcast services"
  echo "  start                    Start Broadcast services"
  echo "  backup                   Backup Broadcast database and files to S3"
  echo "  backup_database          Backup Broadcast primary database"
  echo "  restore <file> [--yes]   Restore Broadcast primary database (--yes skips confirmation)"
  echo "  help                     Display this help message"
  echo "  monitor                  Automated feedback of host metrics to the dashboard"
  echo "  diagnose                 Collect a support diagnostic bundle (logs, probes, system state)"
  echo "  fix                      Repair installation drift (dirs, permissions, services, cron, keys)"
  echo "  health                   Report server health to the Broadcast dashboard (runs via cron)"
  echo "  recover                  Restart the stack if Puma has stopped answering (runs via cron)"
  echo "  edge-enable [--no-restart]  Opt this host into the edge channel: accept"
  echo "                          dashboard-triggered 'edge' upgrades AND show the"
  echo "                          developer-builds card (sets BROADCAST_EDGE_ENABLED=1"
  echo "                          in app/.env, restarts the app). Dev servers only"
  echo "  edge-disable [--no-restart]  Reverse both and refuse 'edge' again (default)"
  echo "  monitor-enable           Enable health reporting on this server and check in now"
  echo "  monitor-disable          Stop all health reporting from this server (zero phone-home)"
  echo "  trigger                  Automated check on triggers from Broadcast to the host"
  echo "  validate_license         Validate the license for Broadcast"
  echo "  change_installation_domain Change the primary installation domain"
  echo "  generate_encryption_keys Generate Active Record encryption keys"
  echo
  echo "Full documentation: https://sendbroadcast.net/docs/cli-reference"
}

function set_safe_directory() {
  echo "Setting /opt/broadcast as a safe directory for Git..."
  git config --global --add safe.directory /opt/broadcast
  echo "Safe directory set successfully."
}

function check_and_set_safe_directory() {
  if ! git config --global --get safe.directory | grep -q "/opt/broadcast"; then
    set_safe_directory
  fi
}

function set_docker_image() {
  local version="${1:-latest}"
  local image_file="/opt/broadcast/.image"
  local version_file="/opt/broadcast/.current_version"

  # Architecture detection
  if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast-arm:${version}" > "$image_file"
    echo "TARGETARCH=arm64" >> "$image_file"
  else
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:${version}" > "$image_file"
  fi

  # Track current version deployment state
  echo "${version}" > "$version_file"

  echo "[$(date)] Set Docker image to version: ${version} (architecture: $(uname -m))"
}

main() {
  current_dir=$(getCurrentDir)
  includeDependencies

  if [ $# -eq 0 ] || [ "$1" = "install" ]; then
    display_logo
  fi

  check_root
  check_installation_domain
  check_license

  # Check and set safe directory before processing any command
  check_and_set_safe_directory

  if [ $# -eq 0 ]; then
    echo "Error: No argument provided"
    display_help
    exit
  fi

  case "$1" in
    install)
      # Only set docker image to latest for fresh installs
      # Upgrade/downgrade commands set specific versions
      set_docker_image "latest"
      install
      ;;
    upgrade)
      # Forward every argument: the version plus any --force / --automated
      # flags the preflight understands.
      shift
      upgrade "$@"
      ;;
    preflight)
      upgrade_preflight
      ;;
    downgrade)
      if [ $# -lt 2 ]; then
        echo "Error: Target version is required for downgrade"
        echo "Usage: $0 downgrade <version>"
        exit 1
      fi
      downgrade "$2"
      ;;
    _upgrade_continue)
      # Internal command: called after scripts update to run with new code
      _upgrade_continue "${2:-}"
      ;;
    _downgrade_continue)
      # Internal command: called after scripts update to run with new code
      _downgrade_continue "${2:-}"
      ;;
    update)
      update
      ;;
    restart)
      restart
      ;;
    stop)
      stop
      ;;
    start)
      start
      ;;
    backup)
      backup
      ;;
    backup_database)
      backup_database
      ;;
    restore)
      restore "${2:-}" "${3:-}"
      ;;
    monitor)
      monitor
      ;;
    diagnose)
      diagnose
      ;;
    fix)
      fix
      ;;
    health)
      health
      ;;
    recover)
      recover
      ;;
    edge-enable)
      edge_enable "${2:-}"
      ;;
    edge-disable)
      edge_disable "${2:-}"
      ;;
    monitor-enable)
      monitor_enable
      ;;
    monitor-disable)
      monitor_disable
      ;;
    trigger)
      trigger
      ;;
    validate_license)
      validate_license
      ;;
    change_installation_domain)
      change_installation_domain
      ;;
    generate_encryption_keys)
      generate_encryption_keys
      ;;
    logs)
      if [ $# -lt 2 ]; then
        echo "Usage: $0 logs <app|job|db>"
        exit 1
      fi
      display_logs "$@"
      ;;
    help)
      display_help
      ;;
    *)
      echo "Usage: $0 {install|upgrade|restart|stop|start|backup|backup_database|restore|help|change_installation_domain}"
      exit 1
      ;;
  esac
}

# Call main function with all arguments
main "$@"
