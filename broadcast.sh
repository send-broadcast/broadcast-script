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
  source "${current_dir}/scripts/upgrade.sh"
  source "${current_dir}/scripts/downgrade.sh"
  source "${current_dir}/scripts/monitor.sh"
  source "${current_dir}/scripts/diagnose.sh"
  source "${current_dir}/scripts/fix.sh"
  source "${current_dir}/scripts/trigger.sh"
  source "${current_dir}/scripts/update.sh"
  source "${current_dir}/scripts/logs.sh"
}

function display_help() {
  echo "Usage: $0 {install|update|upgrade|downgrade|restart|stop|start|backup|restore|help|monitor|trigger|change_installation_domain}"
  echo
  echo "Commands:"
  echo "  install                  Install Broadcast onto a fresh Ubuntu server"
  echo "  update                   Update Broadcast scripts"
  echo "  upgrade [version]        Upgrade Broadcast images and restart the system"
  echo "                          Optional version parameter (e.g., upgrade 1.2.3)"
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
  echo "  trigger                  Automated check on triggers from Broadcast to the host"
  echo "  validate_license         Validate the license for Broadcast"
  echo "  change_installation_domain Change the primary installation domain"
  echo "  generate_encryption_keys Generate Active Record encryption keys"
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
      if [ $# -gt 1 ]; then
        # Pass version parameter if provided
        upgrade "$2"
      else
        # Standard upgrade without version
        upgrade
      fi
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
