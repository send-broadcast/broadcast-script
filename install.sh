#!/usr/bin/env bash
#
# Broadcast one-line installer.
#
#   curl -fsSL https://sendbroadcast.net/install.sh | sudo bash
#
# With no terminal (an agent, or `ssh host 'command'` without -t), give the
# answers to the prompts as environment variables:
#
#   curl -fsSL https://sendbroadcast.net/install.sh | \
#     sudo BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=XXXXX-XXXXX-XXXXX-XX bash
#
# Options go after `bash -s --`, e.g. `... | sudo bash -s -- --no-reboot`:
#   --no-reboot   do not reboot when the install finishes (also BROADCAST_NO_REBOOT=1)
#   --help        show this help
#
# Exit codes:
#   0  installed
#   1  an error (see the message, and /var/log/broadcast-install.log)
#   2  no terminal to ask on, and BROADCAST_DOMAIN / BROADCAST_LICENSE not set
#   3  Broadcast is already installed here; nothing was changed
#
# This script NEVER deletes /opt/broadcast. That directory holds the database
# (db/postgres-data) and the encryption keys (app/.env); the instructions this
# script replaces started with `rm -rf /opt/broadcast`, which destroyed both
# when re-run on a live server. On an existing installation it stops before
# changing anything and points at `update` / `upgrade` instead.
#
# Everything below is function definitions; the only command that runs is the
# call on the last line. A download cut off part-way therefore runs nothing.

set -euo pipefail

BROADCAST_DIR="/opt/broadcast"
BROADCAST_REPO="https://github.com/send-broadcast/broadcast-script.git"
# Rolling release: main is what the nightly `update` cron pulls anyway, so a
# tag pin would be undone within a day. Must be a branch, not a tag — update
# runs `git pull`, which needs a branch to pull into.
BROADCAST_REF="${BROADCAST_REF:-main}"
INSTALL_LOG="/var/log/broadcast-install.log"
SYSTEMD_UNIT="/etc/systemd/system/broadcast.service"
OS_RELEASE_FILE="/etc/os-release"
MEMINFO_FILE="/proc/meminfo"
TTY_DEVICE="/dev/tty"
LICENSE_CHECK_URL="https://sendbroadcast.net/license/check"

SUPPORTED_UBUNTU="24.04 26.04"
MIN_MEMORY_MB=1800      # a "2 GB" server reports a little under 2048 MB
WARN_DISK_FREE_GB=20
MIN_DISK_FREE_GB=5

EXIT_ERROR=1
EXIT_NO_INPUT=2
EXIT_ALREADY_INSTALLED=3

bs_info()  { printf '\033[34m==>\033[0m %s\n' "$*"; }
bs_warn()  { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
bs_error() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; }

bs_indent() {
  local line
  while IFS= read -r line; do printf '  %s\n' "$line"; done <<< "$1"
}

bs_usage() {
  cat <<'USAGE'
Install Broadcast on a fresh Ubuntu 24.04 or 26.04 server:

  curl -fsSL https://sendbroadcast.net/install.sh | sudo bash

Without a terminal, set the answers as environment variables:

  curl -fsSL https://sendbroadcast.net/install.sh | \
    sudo BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=XXXXX-XXXXX-XXXXX-XX bash

Options (after `bash -s --`):
  --no-reboot   do not reboot when the install finishes (or BROADCAST_NO_REBOOT=1)
  --help        show this help
USAGE
}

bs_is_root() {
  [ "$(id -u)" -eq 0 ]
}

# A terminal exists only if /dev/tty can actually be opened. Under
# `ssh host 'cmd'` and under cron the node exists but opening it fails.
bs_has_tty() {
  ( : < "$TTY_DEVICE" ) 2>/dev/null
}

bs_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]
}

# The key is sent inside a hand-built JSON body and written into app/.env, so
# only plain key characters are accepted.
bs_valid_license() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

bs_git() {
  git -c safe.directory="$BROADCAST_DIR" -C "$BROADCAST_DIR" "$@"
}

bs_check_os() {
  if [ ! -r "$OS_RELEASE_FILE" ]; then
    bs_error "cannot read $OS_RELEASE_FILE. Broadcast needs Ubuntu Server ${SUPPORTED_UBUNTU// / or }."
    exit $EXIT_ERROR
  fi
  local id version
  id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' "$OS_RELEASE_FILE")
  version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' "$OS_RELEASE_FILE")
  if [ "$id" != "ubuntu" ] || [[ " $SUPPORTED_UBUNTU " != *" $version "* ]]; then
    bs_error "this server runs ${id:-an unknown OS} ${version}. Broadcast needs Ubuntu Server ${SUPPORTED_UBUNTU// / or }."
    exit $EXIT_ERROR
  fi
}

bs_check_arch() {
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *)
      bs_error "unsupported CPU architecture $(uname -m). Broadcast runs on amd64 (x86_64) or arm64 (aarch64)."
      exit $EXIT_ERROR
      ;;
  esac
}

# Prints what marks this directory as a live installation, or nothing.
bs_installation_marker() {
  if [ -e "$BROADCAST_DIR/app/.env" ]; then echo "$BROADCAST_DIR/app/.env"; return; fi
  if [ -e "$BROADCAST_DIR/db/.env" ]; then echo "$BROADCAST_DIR/db/.env"; return; fi
  if [ -d "$BROADCAST_DIR/db/postgres-data" ] && [ -n "$(ls -A "$BROADCAST_DIR/db/postgres-data" 2>/dev/null)" ]; then
    echo "$BROADCAST_DIR/db/postgres-data"; return
  fi
  if [ -e "$SYSTEMD_UNIT" ]; then echo "$SYSTEMD_UNIT"; return; fi
}

# Decides between a fresh clone and resuming an earlier attempt, or stops.
# Sets BS_MODE to "clone" or "resume". Changes nothing on disk.
#
# Resume covers a checkout left by an earlier run that never reached the point
# of creating secrets or data (no app/.env, db/.env, database or service).
# Such a directory holds only our own scripts and, at most, the .domain and
# .license answers, so continuing in place is safe; deleting it would need
# exactly the `rm -rf` this installer exists to remove.
bs_check_existing() {
  local marker
  marker=$(bs_installation_marker)
  if [ -n "$marker" ]; then
    echo
    bs_error "Broadcast is already installed on this server (found $marker)."
    echo "Nothing was changed. This installer never modifies an existing installation." >&2
    echo >&2
    echo "  Update the management scripts:  sudo $BROADCAST_DIR/broadcast.sh update" >&2
    echo "  Upgrade Broadcast:              sudo $BROADCAST_DIR/broadcast.sh upgrade" >&2
    echo "  Repair a broken installation:   sudo $BROADCAST_DIR/broadcast.sh fix" >&2
    echo "  Finish an install that stopped: sudo $BROADCAST_DIR/broadcast.sh install" >&2
    echo >&2
    exit $EXIT_ALREADY_INSTALLED
  fi

  if [ ! -e "$BROADCAST_DIR" ] || { [ -d "$BROADCAST_DIR" ] && [ -z "$(ls -A "$BROADCAST_DIR" 2>/dev/null)" ]; }; then
    BS_MODE="clone"
    return
  fi

  local origin=""
  if [ -d "$BROADCAST_DIR/.git" ]; then
    origin=$(bs_git remote get-url origin 2>/dev/null || true)
  fi
  case "$origin" in
    *[Bb]roadcast-script*)
      BS_MODE="resume"
      ;;
    *)
      bs_error "$BROADCAST_DIR already exists and is not a Broadcast checkout."
      echo "Nothing was changed. Move it aside, then run the installer again:" >&2
      echo "  sudo mv $BROADCAST_DIR $BROADCAST_DIR.old" >&2
      exit $EXIT_ERROR
      ;;
  esac
}

# Works out where the domain and license come from, before anything changes.
# Sets BS_ASK when something must be asked on the terminal.
#
# All questions are asked by THIS shell, before anything changes and before
# the log starts; the installer then runs with stdin from /dev/null. Ubuntu
# 26.04's sudo-rs runs `curl ... | sudo bash` on its own pty, and on it a
# child process that reads the terminal (or a tee writing to it while this
# shell reads) is stopped by job control and the install hangs at the first
# prompt. Only the top-level shell can read the terminal safely there.
bs_resolve_inputs() {
  BS_DOMAIN="${BROADCAST_DOMAIN:-}"
  BS_LICENSE="${BROADCAST_LICENSE:-}"
  BS_LICENSE_FROM_ENV=""
  [ -n "$BS_LICENSE" ] && BS_LICENSE_FROM_ENV=1

  if [ -n "$BS_DOMAIN" ] && ! bs_valid_domain "$BS_DOMAIN"; then
    bs_error "BROADCAST_DOMAIN='$BS_DOMAIN' is not a valid domain name (example: mail.example.com)."
    exit $EXIT_ERROR
  fi
  if [ -n "$BS_LICENSE" ] && ! bs_valid_license "$BS_LICENSE"; then
    bs_error "BROADCAST_LICENSE contains characters a license key never has. Copy it again from https://sendbroadcast.net/dashboard"
    exit $EXIT_ERROR
  fi

  # A resumed attempt may already hold answers from its own prompts
  if [ "$BS_MODE" = "resume" ]; then
    [ -z "$BS_DOMAIN" ] && [ -s "$BROADCAST_DIR/.domain" ] && BS_DOMAIN=$(cat "$BROADCAST_DIR/.domain")
    [ -z "$BS_LICENSE" ] && [ -s "$BROADCAST_DIR/.license" ] && BS_LICENSE=$(cat "$BROADCAST_DIR/.license")
  fi

  BS_ASK=""
  if [ -n "$BS_DOMAIN" ] && [ -n "$BS_LICENSE" ]; then
    return 0
  fi
  if bs_has_tty; then
    BS_ASK=1
    return 0
  fi
  bs_error "there is no terminal to ask for the domain and license key."
  echo "Nothing was changed. Pass both as environment variables instead:" >&2
  echo >&2
  echo "  curl -fsSL https://sendbroadcast.net/install.sh | sudo BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=XXXXX-XXXXX-XXXXX-XX bash" >&2
  echo >&2
  echo "Or connect with a terminal (ssh -t) and run the installer again." >&2
  exit $EXIT_NO_INPUT
}

# Asks the license server whether the key is valid for the domain, before
# anything changes. 0 = accepted, 1 = rejected, 2 = could not tell (no curl,
# network error, unexpected answer); the installer's own validation decides
# in that case.
bs_check_key() {
  command -v curl >/dev/null 2>&1 || return 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$2\", \"domain\":\"$1\"}" "$LICENSE_CHECK_URL" 2>/dev/null) || code="000"
  case "$code" in
    200) return 0 ;;
    401) return 1 ;;
    *) return 2 ;;
  esac
}

# Reads one answer from the terminal (fd 3). A closed terminal ends the run.
bs_ask() {
  printf '\033[32m%s\033[0m ' "$1"
  if ! IFS= read -r -u 3 BS_ANSWER; then
    echo
    bs_error "the terminal closed before the questions were answered. Nothing was changed."
    exit $EXIT_NO_INPUT
  fi
  BS_ANSWER="${BS_ANSWER//[[:space:]]/}"
}

bs_ask_inputs() {
  [ -n "$BS_ASK" ] || return 0
  exec 3< "$TTY_DEVICE"

  while [ -z "$BS_DOMAIN" ]; do
    bs_ask "Please enter the domain name for this server (eg. broadcast.example.com):"
    if bs_valid_domain "$BS_ANSWER"; then
      BS_DOMAIN="$BS_ANSWER"
    else
      echo -e "\033[31m'$BS_ANSWER' is not a valid domain name. Please try again.\033[0m"
    fi
  done

  local status
  while true; do
    while [ -z "$BS_LICENSE" ]; do
      bs_ask "Please enter your license key:"
      if [ -n "$BS_ANSWER" ] && bs_valid_license "$BS_ANSWER"; then
        BS_LICENSE="$BS_ANSWER"
      else
        echo -e "\033[31mThat does not look like a license key. Copy it from https://sendbroadcast.net/dashboard\033[0m"
      fi
    done
    status=0
    bs_check_key "$BS_DOMAIN" "$BS_LICENSE" || status=$?
    if [ "$status" -ne 1 ]; then
      break
    fi
    echo -e "\033[31mThe license server did not accept this key for $BS_DOMAIN. Please check the key and try again.\033[0m"
    if [ -n "$BS_LICENSE_FROM_ENV" ]; then
      exec 3<&-
      bs_error "BROADCAST_LICENSE was rejected. Nothing was changed."
      exit $EXIT_ERROR
    fi
    BS_LICENSE=""
  done
  BS_KEY_CHECKED=1

  echo
  bs_ask "Install Broadcast for [$BS_DOMAIN] with license key [$BS_LICENSE]? [y/n]"
  case "$BS_ANSWER" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
      exec 3<&-
      echo "Installation cancelled. Nothing was changed."
      exit $EXIT_ERROR
      ;;
  esac

  echo
  echo -e "\033[33mPoint the DNS A record of $BS_DOMAIN to this server's IP address before you continue.\033[0m"
  echo -e "\033[33mBroadcast requests its TLS certificate for that name as soon as it starts.\033[0m"
  echo -e "\033[33mInstructions: https://sendbroadcast.net/docs/installation\033[0m"
  bs_ask "Press Enter to continue..."
  exec 3<&-
}

# Non-interactive runs get the same early answer: a rejected key stops here,
# before anything is downloaded or changed.
bs_precheck_key() {
  [ -z "${BS_KEY_CHECKED:-}" ] || return 0
  local status=0
  bs_check_key "$BS_DOMAIN" "$BS_LICENSE" || status=$?
  if [ "$status" -eq 1 ]; then
    bs_error "the license server did not accept this license key for $BS_DOMAIN. Nothing was changed."
    echo "Check the key and the domain on https://sendbroadcast.net/dashboard, then run the installer again." >&2
    exit $EXIT_ERROR
  fi
  if [ "$status" -eq 0 ]; then
    echo
    echo "Point the DNS A record of $BS_DOMAIN to this server's IP address; Broadcast requests its TLS certificate for that name as soon as it starts."
  fi
}

bs_check_resources() {
  local mem_kb mem_mb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null || echo 0)
  mem_mb=$(( ${mem_kb:-0} / 1024 ))
  if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt "$MIN_MEMORY_MB" ]; then
    bs_warn "this server has ${mem_mb} MB of memory. Broadcast needs 2 GB (4 GB or more for production)."
  fi

  local parent free_kb free_gb
  parent=$(dirname "$BROADCAST_DIR")
  free_kb=$(df -Pk "$parent" 2>/dev/null | awk 'NR==2 {print $4}')
  free_gb=$(( ${free_kb:-0} / 1024 / 1024 ))
  if [ -n "$free_kb" ] && [ "$free_gb" -lt "$MIN_DISK_FREE_GB" ]; then
    bs_error "only ${free_gb} GB of disk space is free on $parent. Broadcast needs at least ${MIN_DISK_FREE_GB} GB free to install (40 GB disk recommended)."
    exit $EXIT_ERROR
  elif [ -n "$free_kb" ] && [ "$free_gb" -lt "$WARN_DISK_FREE_GB" ]; then
    bs_warn "only ${free_gb} GB of disk space is free on $parent. A 40 GB disk is recommended."
  fi

  # Broadcast serves HTTP and HTTPS itself. Another web server on these ports
  # lets the install finish while the app can never start.
  if command -v ss >/dev/null 2>&1; then
    local listeners
    listeners=$(ss -Hltnp '( sport = :80 or sport = :443 )' 2>/dev/null || true)
    if [ -n "$listeners" ]; then
      bs_error "ports 80 and 443 must be free for Broadcast, but something is listening:"
      bs_indent "$listeners" >&2
      echo "Stop that service (for example: sudo systemctl disable --now nginx apache2), then run the installer again." >&2
      exit $EXIT_ERROR
    fi
  fi
}

# Everything from here on is copied to the install log, so support can see
# exactly what happened. Root-only: the prompts echo the license key.
bs_start_log() {
  ( umask 077 && touch "$INSTALL_LOG" ) 2>/dev/null || return 0
  chmod 600 "$INSTALL_LOG" 2>/dev/null || true
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  trap 'bs_on_exit $?' EXIT
  echo
  echo "=== Broadcast install $(date -u '+%Y-%m-%dT%H:%M:%SZ') ref=$BROADCAST_REF mode=$BS_MODE ==="
}

# An unexpected failure (a network error during git clone, say) exits through
# set -e with only the failing command's own message; point at the log too.
bs_on_exit() {
  if [ "$1" -ne 0 ] && [ -z "${BS_HINTED:-}" ]; then
    echo "The install did not finish (exit $1). The full log is in $INSTALL_LOG." >&2
  fi
}

bs_ensure_packages() {
  local missing="" cmd
  for cmd in git curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  [ -z "$missing" ] && return 0
  bs_info "Installing${missing}..."
  # A fresh cloud server often runs unattended-upgrades at first boot; wait
  # for its apt lock instead of failing on it.
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -qq
  # shellcheck disable=SC2086 # word-splitting the package list is intended
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq $missing
}

bs_fetch_scripts() {
  if [ "$BS_MODE" = "clone" ]; then
    bs_info "Downloading Broadcast ($BROADCAST_REF) into $BROADCAST_DIR..."
    git clone --quiet --branch "$BROADCAST_REF" "$BROADCAST_REPO" "$BROADCAST_DIR"
    return
  fi

  bs_info "Resuming the unfinished install in $BROADCAST_DIR..."
  local dirty
  dirty=$(bs_git status --porcelain --untracked-files=no 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    BS_HINTED=1
    bs_error "$BROADCAST_DIR has local changes to Broadcast's own files:"
    bs_indent "$dirty" >&2
    echo "Nothing was changed. Undo them with: sudo git -C $BROADCAST_DIR checkout -- ." >&2
    exit $EXIT_ERROR
  fi
  bs_git remote set-url origin "$BROADCAST_REPO"
  bs_git fetch --quiet origin "+refs/heads/$BROADCAST_REF:refs/remotes/origin/$BROADCAST_REF"
  bs_git checkout --quiet -B "$BROADCAST_REF" "origin/$BROADCAST_REF"
}

bs_write_answers() {
  if [ -n "$BS_DOMAIN" ]; then
    echo "$BS_DOMAIN" > "$BROADCAST_DIR/.domain"
  fi
  if [ -n "$BS_LICENSE" ]; then
    ( umask 077 && echo "$BS_LICENSE" > "$BROADCAST_DIR/.license" )
  fi
}

# The installer's own validation, which also stores the registry credentials.
# Runs before any apt or Docker work.
bs_validate_license() {
  [ -s "$BROADCAST_DIR/.license" ] || return 0
  bs_info "Checking the license key..."
  if ! (cd "$BROADCAST_DIR" && ./broadcast.sh validate_license < /dev/null); then
    rm -f "$BROADCAST_DIR/.license"
    BS_HINTED=1
    bs_error "the license key was not accepted for $(cat "$BROADCAST_DIR/.domain" 2>/dev/null). Nothing was installed."
    echo "Check the key and the domain on https://sendbroadcast.net/dashboard, then run the installer again." >&2
    exit $EXIT_ERROR
  fi
}

bs_run_installer() {
  bs_info "Running the Broadcast installer..."
  local rc=0
  (cd "$BROADCAST_DIR" && BROADCAST_NO_REBOOT="$BS_NO_REBOOT" ./broadcast.sh install < /dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    BS_HINTED=1
    echo
    bs_error "the installer stopped (exit $rc). The full log is in $INSTALL_LOG."
    echo "Fix the cause shown above, then finish the install with: sudo $BROADCAST_DIR/broadcast.sh install" >&2
    echo "Need help? Send $INSTALL_LOG to support via https://sendbroadcast.net/dashboard" >&2
    exit $EXIT_ERROR
  fi
}

broadcast_bootstrap() {
  BS_NO_REBOOT="${BROADCAST_NO_REBOOT:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-reboot) BS_NO_REBOOT=1 ;;
      -h|--help) bs_usage; return 0 ;;
      *) bs_error "unknown option: $1"; bs_usage; exit $EXIT_ERROR ;;
    esac
    shift
  done

  if ! bs_is_root; then
    bs_error "the installer must run as root. Use: curl -fsSL https://sendbroadcast.net/install.sh | sudo bash"
    exit $EXIT_ERROR
  fi

  # Every check that can refuse runs before anything is written.
  BS_MODE=""
  bs_check_existing
  bs_check_os
  bs_check_arch
  bs_resolve_inputs
  bs_check_resources
  bs_ask_inputs
  bs_precheck_key

  bs_start_log
  bs_ensure_packages
  bs_fetch_scripts
  bs_write_answers
  bs_validate_license
  bs_run_installer
}

broadcast_bootstrap "$@"
