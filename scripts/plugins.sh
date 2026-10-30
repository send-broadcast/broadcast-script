#!/bin/bash

# plugins: server commands for Broadcast plugins.
#
# safe-mode turns every plugin off without the web UI, for example when a plugin keeps the app from
# working. The flag is BROADCAST_PLUGINS_SAFE_MODE in /opt/broadcast/.env, which Compose reads to fill
# in docker-compose.yml: the plugins container must never read app/.env (database password, keys).
#
# ensure_plugin_runtime_secret creates the secret that Rails, the plugin runtime and the egress
# proxy share (uid 1000, mode 0400, bind-mounted read-only at /run/secrets). install, upgrade and
# update call it. Until it exists, plugins and egress wait; Broadcast itself starts either way.

PLUGINS_ENV_FILE="/opt/broadcast/.env"
PLUGIN_SECRET_FILE="/opt/broadcast/secrets/plugin_runtime_secret"

plugins_usage() {
  echo "Usage: $0 plugins safe-mode on|off|status"
  echo
  echo "  safe-mode on      Turn every plugin off (Broadcast keeps working)"
  echo "  safe-mode off     Let enabled plugins run again"
  echo "  safe-mode status  Show whether safe mode is on"
}

plugins() {
  local subcommand="${1:-}"
  local value="${2:-}"

  if [ "$subcommand" != "safe-mode" ]; then
    [ -n "$subcommand" ] && echo -e "\e[31mError: unknown subcommand '$subcommand'.\e[0m"
    plugins_usage
    return 1
  fi

  case "$value" in
    on) plugins_set_safe_mode 1 ;;
    off) plugins_set_safe_mode 0 ;;
    status) plugins_safe_mode_status ;;
    *)
      plugins_usage
      return 1
      ;;
  esac
}

plugins_safe_mode_status() {
  if grep -q '^BROADCAST_PLUGINS_SAFE_MODE=1' "$PLUGINS_ENV_FILE" 2>/dev/null; then
    echo "Safe mode is on: no plugin runs."
  else
    echo "Safe mode is off: enabled plugins run."
  fi
}

plugins_set_safe_mode() {
  # Keep every other setting in .env (registry login); replace only this key
  if [ -f "$PLUGINS_ENV_FILE" ]; then
    grep -v '^BROADCAST_PLUGINS_SAFE_MODE=' "$PLUGINS_ENV_FILE" > "$PLUGINS_ENV_FILE.tmp" || true
    mv "$PLUGINS_ENV_FILE.tmp" "$PLUGINS_ENV_FILE"
  fi
  echo "BROADCAST_PLUGINS_SAFE_MODE=$1" >> "$PLUGINS_ENV_FILE"
  (
    cd /opt/broadcast || exit 1
    if [ -f .image ]; then
      set -a
      # shellcheck disable=SC1091
      source .image
      set +a
    fi
    docker compose up -d --force-recreate app job plugins
  ) || {
    echo -e "\e[31mError: could not restart app, job and plugins.\e[0m"
    return 1
  }
  plugins_safe_mode_status
}

ensure_plugin_runtime_secret() {
  [ -s "$PLUGIN_SECRET_FILE" ] && return 0

  mkdir -p "$(dirname "$PLUGIN_SECRET_FILE")"
  (umask 077 && openssl rand -hex 32 > "$PLUGIN_SECRET_FILE")
  chown 1000:1000 "$PLUGIN_SECRET_FILE" 2>/dev/null || sudo chown 1000:1000 "$PLUGIN_SECRET_FILE" 2>/dev/null || true
  chmod 0400 "$PLUGIN_SECRET_FILE"
}
