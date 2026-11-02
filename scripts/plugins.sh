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
    # Name the runtime service only when its profile is on: naming a service turns its profile on
    local services=(app job)
    plugin_runtime_profile_enabled && services+=(plugins)
    docker compose up -d --force-recreate "${services[@]}"
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

# The optional runtime service and its proxy (egress) are in the Compose profile `runtime`, off by default:
# released images do not contain bin/plugin-runtime, and a service that runs it restart-loops with
# exit 127. sync_plugin_runtime_profile turns the profile on in /opt/broadcast/.env (COMPOSE_PROFILES,
# read by Compose and by the systemd unit's `docker compose up`) only when the selected image
# contains the binary. install, upgrade and update call it after the image is pulled.
PLUGIN_RUNTIME_PROFILE="runtime"
PLUGIN_RUNTIME_BINARY="/rails/bin/plugin-runtime"

plugin_runtime_profile_enabled() {
  local profiles
  profiles=$(grep '^COMPOSE_PROFILES=' "$PLUGINS_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"' ")
  [[ ",$profiles," == *",$PLUGIN_RUNTIME_PROFILE,"* ]]
}

# Rewrite COMPOSE_PROFILES with the runtime profile added (on) or removed (off). Other profiles
# and every other line of .env stay. .env holds the registry password: it is rewritten in place,
# so its owner and mode do not change.
set_plugin_runtime_profile() {
  local state="$1" profiles="" kept="" p tmp
  tmp=$(umask 077 && mktemp)
  if [ -f "$PLUGINS_ENV_FILE" ]; then
    profiles=$(grep '^COMPOSE_PROFILES=' "$PLUGINS_ENV_FILE" | tail -1 | cut -d= -f2- | tr -d "\"' ")
    grep -v '^COMPOSE_PROFILES=' "$PLUGINS_ENV_FILE" > "$tmp" || true
  fi
  local IFS=','
  for p in $profiles; do
    [ -n "$p" ] && [ "$p" != "$PLUGIN_RUNTIME_PROFILE" ] && kept="${kept:+$kept,}$p"
  done
  [ "$state" = "on" ] && kept="${kept:+$kept,}$PLUGIN_RUNTIME_PROFILE"
  [ -n "$kept" ] && echo "COMPOSE_PROFILES=$kept" >> "$tmp"
  cat "$tmp" > "$PLUGINS_ENV_FILE"
  rm -f "$tmp"
  return 0
}

# 0 = the image contains the binary, 1 = it does not, 2 = docker could not answer
image_has_plugin_runtime() {
  local image="$1" rc=0
  [ -n "$image" ] || return 2
  docker run --rm --pull never --entrypoint test "$image" -x "$PLUGIN_RUNTIME_BINARY" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

sync_plugin_runtime_profile() {
  local image rc=0
  image=$(grep '^DOCKER_IMAGE=' /opt/broadcast/.image 2>/dev/null | tail -1 | cut -d= -f2-)
  image_has_plugin_runtime "$image" || rc=$?

  case "$rc" in
    0)
      set_plugin_runtime_profile on
      echo -e "\e[32mThe optional runtime service is on (the image contains it).\e[0m"
      ;;
    1)
      set_plugin_runtime_profile off
      # A container from an earlier start would keep restarting; Compose no longer manages it
      docker rm -f plugins egress >/dev/null 2>&1 || true
      echo "The optional runtime service stays off (this image does not contain it)."
      ;;
    *)
      echo -e "\e[33mWarning: could not check the image for the optional runtime service; its setting is unchanged.\e[0m"
      ;;
  esac
  return 0
}
