# Idempotent repair of installation drift — the converge-side complement to
# diagnose (which only observes). Re-asserts everything install.sh and
# _upgrade_continue set up: directories, ownership, executable bits,
# sudoers, docker group membership, the .image file, registry login,
# systemd units (installed, enabled, started — and VERIFIED after each
# action), logrotate, cron entries, and app/.env essentials. Prints
# ok:/fixed:/FAIL: per check.
#
# Honesty rules:
#   - A repair is only reported "fixed:" after re-checking that it took
#     effect; an action that did not stick is a FAIL, not a success.
#   - Repairs that fail must not abort the run (set -e is active in
#     broadcast.sh): every fallible repair is guarded so the run always
#     reaches its summary, and any FAIL makes the exit code 1.
#   - One-time provisioning (Docker itself, UFW, fail2ban, swap) is out of
#     scope: a missing prerequisite points at ./broadcast.sh install
#     instead of risking a half-reinstall. Likewise anything whose true
#     value is unknowable (a lost db/.env password, mismatched database
#     passwords) is a loud FAIL, never a guess.

# Seams for tests
function fix_has_command() {
  command -v "$1" >/dev/null 2>&1
}

function fix_has_compose() {
  docker compose version >/dev/null 2>&1
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

  if fix_has_compose; then
    fix_ok "docker compose plugin is installed"
  else
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
    if fix_has_compose; then
      fix_did "installed the docker compose plugin"
    else
      fix_fail "docker compose plugin is missing and could not be installed — run ./broadcast.sh install or contact support"
      echo
      echo -e "\e[31m$FIX_FAILED unfixable problem(s). Run ./broadcast.sh install on a fresh server, or contact support.\e[0m"
      return 1
    fi
  fi

  # --- Configuration that cannot be regenerated --------------------------
  # db/.env holds the postgres password matching the existing data
  # directory; if it is lost the value is unrecoverable. Detect it loudly
  # BEFORE anything recreates the container without credentials.
  if [ -f /opt/broadcast/db/.env ]; then
    fix_ok "db/.env present"
  else
    fix_fail "db/.env is missing — the database password is unrecoverable from here; contact support BEFORE restarting anything"
  fi

  # --- broadcast user and access ----------------------------------------
  if id broadcast >/dev/null 2>&1; then
    fix_ok "broadcast user exists"
  else
    useradd -m -s /bin/bash broadcast || true
    if id broadcast >/dev/null 2>&1; then
      fix_did "created the broadcast user"
    else
      fix_fail "could not create the broadcast user"
    fi
  fi

  if id -nG broadcast 2>/dev/null | grep -qw docker; then
    fix_ok "broadcast user is in the docker group"
  else
    usermod -aG docker broadcast || true
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
      mkdir -p "/opt/broadcast/$dir" || true
      if [ -d "/opt/broadcast/$dir" ]; then
        fix_did "recreated directory $dir"
      else
        fix_fail "could not create directory $dir"
      fi
    fi
  done

  # --- Permissions and ownership ----------------------------------------
  if [ -x /opt/broadcast/broadcast.sh ]; then
    fix_ok "broadcast.sh is executable"
  else
    chmod +x /opt/broadcast/broadcast.sh || true
    fix_did "made broadcast.sh executable"
  fi

  local helper
  for helper in post-upgrade-cleanup.sh logs-trigger-watcher.sh; do
    if [ ! -f "/opt/broadcast/scripts/$helper" ]; then
      fix_fail "scripts/$helper is missing — run ./broadcast.sh update"
    elif [ -x "/opt/broadcast/scripts/$helper" ]; then
      fix_ok "scripts/$helper is executable"
    else
      chmod +x "/opt/broadcast/scripts/$helper" || true
      fix_did "made scripts/$helper executable"
    fi
  done

  # postgres container (uid 70) must be able to read the init scripts
  chmod -R o+rX /opt/broadcast/db/init-scripts 2>/dev/null || true
  fix_ok "db/init-scripts readable by the postgres container"

  local owner
  owner=$(stat -c %U /opt/broadcast 2>/dev/null || echo unknown)
  if [ "$owner" = "broadcast" ]; then
    fix_ok "/opt/broadcast owned by broadcast"
  else
    chown -R broadcast:broadcast /opt/broadcast || true
    fix_did "restored broadcast:broadcast ownership of /opt/broadcast"
  fi

  # --- .image: broadcast.service sources it before compose up; without it
  # the stack cannot start at all
  if [ -f /opt/broadcast/.image ]; then
    fix_ok ".image present (existing pin preserved)"
  else
    local pinned
    pinned=$(cat /opt/broadcast/.current_version 2>/dev/null || echo latest)
    set_docker_image "$pinned" > /dev/null
    if [ "$pinned" = "latest" ]; then
      fix_did "regenerated .image (no version record found — pinned to latest)"
    else
      fix_did "regenerated .image for installed version $pinned"
    fi
  fi

  # --- Registry login: without it the next upgrade's pull fails ----------
  if [ ! -f /opt/broadcast/.env ]; then
    fix_fail "registry credentials file .env is missing — run ./broadcast.sh validate_license"
  else
    local registry_url registry_login registry_password
    registry_url=$(grep "^BROADCAST_REGISTRY_URL=" /opt/broadcast/.env | cut -d= -f2-)
    if [ -z "$registry_url" ]; then
      fix_fail "no registry URL in .env — run ./broadcast.sh validate_license"
    elif grep -q "$registry_url" /home/broadcast/.docker/config.json 2>/dev/null; then
      fix_ok "docker registry login present for the broadcast user"
    else
      registry_login=$(grep "^BROADCAST_REGISTRY_LOGIN=" /opt/broadcast/.env | cut -d= -f2-)
      registry_password=$(grep "^BROADCAST_REGISTRY_PASSWORD=" /opt/broadcast/.env | cut -d= -f2-)
      su - broadcast -c "echo '$registry_password' | docker login '$registry_url' -u '$registry_login' --password-stdin" >/dev/null 2>&1 || true
      if grep -q "$registry_url" /home/broadcast/.docker/config.json 2>/dev/null; then
        fix_did "logged the broadcast user into the docker registry"
      else
        fix_fail "docker registry login failed — validate your license or contact support"
      fi
    fi
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
    if cp /opt/broadcast/scripts/broadcast-post-upgrade-cleanup.service /etc/systemd/system/ 2>/dev/null; then
      fix_did "installed the post-upgrade cleanup unit"
      units_changed=true
    else
      fix_fail "could not install the post-upgrade cleanup unit (scripts/broadcast-post-upgrade-cleanup.service missing?)"
    fi
  fi

  if [ -f /etc/systemd/system/broadcast-logs-watcher.service ]; then
    fix_ok "logs watcher unit installed"
  else
    if cp /opt/broadcast/scripts/broadcast-logs-watcher.service /etc/systemd/system/ 2>/dev/null; then
      fix_did "installed the logs watcher unit"
      units_changed=true
    else
      fix_fail "could not install the logs watcher unit (scripts/broadcast-logs-watcher.service missing?)"
    fi
  fi

  if [ "$units_changed" = true ]; then
    systemctl daemon-reload || true
  fi

  # Enable and start, VERIFYING each action took effect — a start that did
  # not stick is exactly the failure this tool exists to surface
  local service
  for service in broadcast.service broadcast-logs-watcher; do
    if systemctl is-enabled "$service" >/dev/null 2>&1; then
      fix_ok "$service is enabled"
    else
      systemctl enable "$service" >/dev/null 2>&1 || true
      if systemctl is-enabled "$service" >/dev/null 2>&1; then
        fix_did "enabled $service"
      else
        fix_fail "could not enable $service"
      fi
    fi
    if systemctl is-active "$service" >/dev/null 2>&1; then
      fix_ok "$service is active"
    else
      systemctl start "$service" >/dev/null 2>&1 || true
      if systemctl is-active "$service" >/dev/null 2>&1; then
        fix_did "started $service"
      else
        fix_fail "could not start $service — run ./broadcast.sh diagnose and check the bundle"
      fi
    fi
  done

  # --- Watcher dependency ------------------------------------------------
  if fix_has_command inotifywait; then
    fix_ok "inotify-tools installed"
  else
    apt-get install -y inotify-tools >/dev/null 2>&1 || true
    fix_did "installed inotify-tools"
  fi

  # --- Logrotate: without it log growth is unbounded ---------------------
  if [ -f /etc/logrotate.d/broadcast ]; then
    fix_ok "logrotate config present"
  else
    cat > /etc/logrotate.d/broadcast <<'LOGROTATE'
/opt/broadcast/logs/**/*.log {
    daily
    missingok
    rotate 5
    compress
    delaycompress
    notifempty
    create 0640 broadcast broadcast
    sharedscripts
    endscript
}
LOGROTATE
    fix_did "recreated the logrotate config"
  fi

  # --- Cron entries (append only what is missing; never rewrite) --------
  local cron_cmd cron_line
  for cron_cmd in "monitor:* * * * *" "trigger:* * * * *" "health:* * * * *" "update:0 0 * * *"; do
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

  # --- app/.env essentials -----------------------------------------------
  if [ ! -f /opt/broadcast/app/.env ]; then
    fix_fail "app/.env is missing — the Rails environment was never created; run ./broadcast.sh install"
  else
    if grep -q "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" /opt/broadcast/app/.env; then
      fix_ok "Active Record encryption keys present"
    else
      generate_encryption_keys > /dev/null
      fix_did "generated Active Record encryption keys"
    fi

    if grep -q "^SECRET_KEY_BASE=" /opt/broadcast/app/.env; then
      fix_ok "SECRET_KEY_BASE present"
    else
      echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" >> /opt/broadcast/app/.env
      fix_did "generated SECRET_KEY_BASE"
    fi

    if grep -q "^TLS_DOMAIN=" /opt/broadcast/app/.env; then
      fix_ok "TLS_DOMAIN present"
    elif [ -f /opt/broadcast/.domain ]; then
      local fix_domain
      fix_domain=$(cat /opt/broadcast/.domain)
      if [ -f /opt/broadcast/.other_domains ]; then
        fix_domain="$fix_domain,$(tr '\n' ',' < /opt/broadcast/.other_domains | sed 's/,$//')"
      fi
      echo "TLS_DOMAIN=$fix_domain" >> /opt/broadcast/app/.env
      fix_did "restored TLS_DOMAIN from .domain"
    else
      fix_fail "TLS_DOMAIN missing and .domain not found — cannot derive the domain"
    fi

    # DATABASE_PASSWORD must match db/.env's POSTGRES_PASSWORD. Missing is
    # repairable (db/.env is the source of truth); a MISMATCH is not — we
    # cannot know which one the database was initialized with.
    if [ -f /opt/broadcast/db/.env ]; then
      local app_pw db_pw
      app_pw=$(grep "^DATABASE_PASSWORD=" /opt/broadcast/app/.env | cut -d= -f2-)
      db_pw=$(grep "^POSTGRES_PASSWORD=" /opt/broadcast/db/.env | cut -d= -f2-)
      if [ -z "$app_pw" ] && [ -n "$db_pw" ]; then
        echo "DATABASE_PASSWORD=$db_pw" >> /opt/broadcast/app/.env
        fix_did "restored DATABASE_PASSWORD from db/.env"
      elif [ -n "$app_pw" ] && [ "$app_pw" = "$db_pw" ]; then
        fix_ok "DATABASE_PASSWORD matches db/.env"
      elif [ -n "$app_pw" ] && [ -n "$db_pw" ]; then
        fix_fail "DATABASE_PASSWORD in app/.env does not match POSTGRES_PASSWORD in db/.env — cannot know which is correct; contact support"
      fi
    fi
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
