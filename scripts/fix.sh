# Idempotent repair of installation drift — the converge-side complement to
# diagnose (which only observes). Re-asserts everything install.sh and
# _upgrade_continue set up: directories, ownership, executable bits,
# sudoers, docker group membership, systemd units (installed, enabled,
# started), cron entries, and encryption keys. Prints ok:/fixed: per check.
#
# Deliberately does NOT re-run one-time provisioning (Docker itself, UFW,
# fail2ban, swap): a missing prerequisite means a broken or absent install,
# and a half-reinstall from here would make things worse. Those are
# reported as unfixable with exit 1, pointing at ./broadcast.sh install.

# Seam for tests; true when the command exists on this host
function fix_has_command() {
  command -v "$1" >/dev/null 2>&1
}

function fix_ok() {
  echo -e "ok: $1"
}

function fix_did() {
  echo -e "\e[33mfixed: $1\e[0m"
  FIX_REPAIRED=$((FIX_REPAIRED + 1))
}

function fix_fail() {
  echo -e "\e[31mFAIL: $1\e[0m"
  FIX_FAILED=$((FIX_FAILED + 1))
}

function fix() {
  FIX_REPAIRED=0
  FIX_FAILED=0

  echo -e "\e[33mChecking and repairing the Broadcast installation...\e[0m"
  echo

  # --- Unfixable prerequisites: converge cannot replace install ---------
  if fix_has_command docker; then
    fix_ok "docker is installed"
  else
    fix_fail "docker is not installed — this needs a full ./broadcast.sh install"
    echo
    echo -e "\e[31m$FIX_FAILED unfixable problem(s). Run ./broadcast.sh install on a fresh server, or contact support.\e[0m"
    return 1
  fi

  # --- broadcast user and access ----------------------------------------
  if id broadcast >/dev/null 2>&1; then
    fix_ok "broadcast user exists"
  else
    useradd -m -s /bin/bash broadcast
    fix_did "created the broadcast user"
  fi

  if id -nG broadcast 2>/dev/null | grep -qw docker; then
    fix_ok "broadcast user is in the docker group"
  else
    usermod -aG docker broadcast
    fix_did "added broadcast user to the docker group"
  fi

  if [ -f /etc/sudoers.d/broadcast ]; then
    fix_ok "sudoers entry present"
  else
    echo "broadcast ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/broadcast
    chmod 0440 /etc/sudoers.d/broadcast 2>/dev/null || true
    fix_did "recreated /etc/sudoers.d/broadcast"
  fi

  # --- Directory skeleton ------------------------------------------------
  local dir
  for dir in app/storage app/uploads app/triggers app/monitor db/backups db/init-scripts logs/cron ssl; do
    if [ -d "/opt/broadcast/$dir" ]; then
      fix_ok "directory $dir exists"
    else
      mkdir -p "/opt/broadcast/$dir"
      fix_did "recreated directory $dir"
    fi
  done

  # --- Permissions and ownership ----------------------------------------
  if [ -x /opt/broadcast/broadcast.sh ]; then
    fix_ok "broadcast.sh is executable"
  else
    chmod +x /opt/broadcast/broadcast.sh
    fix_did "made broadcast.sh executable"
  fi

  # postgres container (uid 70) must be able to read the init scripts
  chmod -R o+rX /opt/broadcast/db/init-scripts 2>/dev/null || true
  fix_ok "db/init-scripts readable by the postgres container"

  local owner
  owner=$(stat -c %U /opt/broadcast 2>/dev/null || echo unknown)
  if [ "$owner" = "broadcast" ]; then
    fix_ok "/opt/broadcast owned by broadcast"
  else
    chown -R broadcast:broadcast /opt/broadcast
    fix_did "restored broadcast:broadcast ownership of /opt/broadcast"
  fi

  # --- systemd units: installed, enabled, running ------------------------
  local units_changed=false

  if [ -f /etc/systemd/system/broadcast.service ]; then
    fix_ok "broadcast.service unit installed"
  else
    source /opt/broadcast/scripts/init-services.sh
    create_broadcast_service > /dev/null
    fix_did "created broadcast.service"
    units_changed=true
  fi

  if [ -f /etc/systemd/system/broadcast-post-upgrade-cleanup.service ]; then
    fix_ok "post-upgrade cleanup unit installed"
  else
    cp /opt/broadcast/scripts/broadcast-post-upgrade-cleanup.service /etc/systemd/system/
    chmod +x /opt/broadcast/scripts/post-upgrade-cleanup.sh
    fix_did "installed the post-upgrade cleanup unit"
    units_changed=true
  fi

  if [ -f /etc/systemd/system/broadcast-logs-watcher.service ]; then
    fix_ok "logs watcher unit installed"
  else
    cp /opt/broadcast/scripts/broadcast-logs-watcher.service /etc/systemd/system/
    fix_did "installed the logs watcher unit"
    units_changed=true
  fi

  if [ "$units_changed" = true ]; then
    systemctl daemon-reload
  fi

  local service
  for service in broadcast.service broadcast-logs-watcher; do
    if systemctl is-enabled "$service" >/dev/null 2>&1; then
      fix_ok "$service is enabled"
    else
      systemctl enable "$service" >/dev/null 2>&1 || true
      fix_did "enabled $service"
    fi
    if systemctl is-active "$service" >/dev/null 2>&1; then
      fix_ok "$service is active"
    else
      systemctl start "$service" >/dev/null 2>&1 || true
      fix_did "started $service"
    fi
  done

  # --- Watcher dependency ------------------------------------------------
  if fix_has_command inotifywait; then
    fix_ok "inotify-tools installed"
  else
    apt-get install -y inotify-tools >/dev/null 2>&1 || true
    fix_did "installed inotify-tools"
  fi

  # --- Cron entries (append only what is missing; never rewrite) --------
  local cron_cmd cron_line
  for cron_cmd in "monitor:* * * * *" "trigger:* * * * *" "update:0 0 * * *"; do
    local name="${cron_cmd%%:*}"
    local schedule="${cron_cmd#*:}"
    if crontab -l 2>/dev/null | grep -q "broadcast.sh $name"; then
      fix_ok "cron entry for $name present"
    else
      cron_line="$schedule /opt/broadcast/broadcast.sh $name >> /opt/broadcast/logs/cron/$name.log 2>&1"
      (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
      fix_did "added cron entry for $name"
    fi
  done

  # --- Encryption keys ---------------------------------------------------
  if [ ! -f /opt/broadcast/app/.env ]; then
    fix_fail "app/.env is missing — the Rails environment was never created; run ./broadcast.sh install"
  elif grep -q "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" /opt/broadcast/app/.env; then
    fix_ok "Active Record encryption keys present"
  else
    generate_encryption_keys > /dev/null
    fix_did "generated Active Record encryption keys"
  fi

  # --- Summary -----------------------------------------------------------
  echo
  if [ "$FIX_FAILED" -gt 0 ]; then
    echo -e "\e[31mDone: $FIX_REPAIRED repaired, $FIX_FAILED unfixable — see FAIL lines above.\e[0m"
    return 1
  elif [ "$FIX_REPAIRED" -gt 0 ]; then
    echo -e "\e[32mDone: $FIX_REPAIRED problem(s) repaired.\e[0m"
    echo -e "\e[33mIf services were just started, give them a minute, then run ./broadcast.sh diagnose to confirm health.\e[0m"
  else
    echo -e "\e[32mDone: everything already in order — nothing to fix.\e[0m"
  fi
  return 0
}
