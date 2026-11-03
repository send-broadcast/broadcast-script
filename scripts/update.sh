function update() {
  echo -e "\e[33mUpgrading Broadcast scripts...\e[0m"
  # Upgrade the Broadcast scripts
  cd /opt/broadcast

  local current_url
  current_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "$current_url" == *"Furvur/broadcast-script"* ]] || [[ "$current_url" == *"furvur/broadcast-script"* ]]; then
    echo -e "\e[33mMigrating remote origin to send-broadcast namespace...\e[0m"
    git remote set-url origin https://github.com/send-broadcast/broadcast-script.git
  fi

  # Refuse to pull over local modifications. A hand-edited tracked file
  # (customer incident 2026-08-04: an edited docker-compose.yml) makes
  # `git pull` fail, which silently kills the nightly update and aborts
  # upgrades — better to fail loudly here with instructions than let git's
  # merge error speak for itself.
  local dirty
  dirty=$(git status --porcelain --untracked-files=no 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo -e "\e[31mError: local modifications in /opt/broadcast are blocking script updates:\e[0m"
    echo "$dirty"
    echo -e "\e[33mBroadcast's own files must stay unmodified so updates can be delivered.\e[0m"
    echo -e "\e[33mTo customize the Docker services, put your changes in /opt/broadcast/docker-compose.override.yml instead — it is applied on top of the stock docker-compose.yml automatically and survives updates.\e[0m"
    echo -e "\e[33mOnce your changes are moved into the override file, discard the local edits with: git -C /opt/broadcast checkout -- .\e[0m"
    return 1
  fi

  git pull

  # broadcast.sh loaded this function before the pull. Run the steps after the pull with the
  # scripts just pulled, so a fix in them takes effect tonight, not one night later.
  # BROADCAST_UPDATE_REEXEC stops a second start: _update_continue never starts broadcast.sh again.
  if [ -z "${BROADCAST_UPDATE_REEXEC:-}" ] && [ -x /opt/broadcast/broadcast.sh ]; then
    BROADCAST_UPDATE_REEXEC=1 exec /opt/broadcast/broadcast.sh _update_continue
  fi
  _update_continue
}

# The steps after `git pull`. broadcast.sh runs them with the pulled scripts (see update).
function _update_continue() {
  # Plugins: the new docker-compose.yml may add the plugins and egress services, which wait for
  # this secret (Broadcast itself starts without it)
  if [ -f /opt/broadcast/scripts/plugins.sh ]; then
    # shellcheck disable=SC1091
    source /opt/broadcast/scripts/plugins.sh
    ensure_plugin_runtime_secret || true
    # The new compose file keeps the optional runtime service off unless the image contains it
    sync_plugin_runtime_profile || true
  fi

  echo -e "\e[32mBroadcast scripts upgraded successfully!\e[0m"
}
