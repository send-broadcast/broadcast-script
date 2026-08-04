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

  echo -e "\e[32mBroadcast scripts upgraded successfully!\e[0m"
}
