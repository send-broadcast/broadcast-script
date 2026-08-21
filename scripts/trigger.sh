function trigger() {
  # Ensure BROADCAST_MANAGED is set in app/.env for managed installations
  local app_env="/opt/broadcast/app/.env"
  if [ -f "$app_env" ] && ! grep -q "^BROADCAST_MANAGED=" "$app_env"; then
    echo "BROADCAST_MANAGED=true" >> "$app_env"
    echo "[$(date)] Added BROADCAST_MANAGED=true to app/.env"
  fi

  # Retry an upgrade the preflight deferred. The trigger file is consumed
  # below before the upgrade runs, and it must be: the app treats its presence
  # as "system unavailable", so leaving it in place through a deferral that
  # may last hours would show a maintenance state the whole time. The deferral
  # record carries the request instead (line 1 count, line 2 target version).
  if [ ! -f "/opt/broadcast/app/triggers/upgrade.txt" ] && [ -f "/opt/broadcast/.upgrade_deferred" ]; then
    deferred_version=$(sed -n '2p' "/opt/broadcast/.upgrade_deferred" 2>/dev/null || echo "")
    echo "[$(date)] retrying previously deferred upgrade${deferred_version:+ to $deferred_version}"
    /opt/broadcast/broadcast.sh upgrade --automated ${deferred_version:+$deferred_version}
  fi

  # Check if the upgrade.txt file exists in the triggers directory
  if [ -f "/opt/broadcast/app/triggers/upgrade.txt" ]; then
    # Read the content of the upgrade.txt file
    trigger_content=$(cat "/opt/broadcast/app/triggers/upgrade.txt" 2>/dev/null || echo "")
    
    # Validate the content: a semantic version, or the literal 'edge' (the
    # unreleased main-branch build the dashboard's developer card requests —
    # it must NOT hit the fallback below, which would silently install the
    # latest release instead; upgrade.sh itself still refuses edge unless
    # this host opted in via .edge_enabled)
    if [ "$trigger_content" = "edge" ] || echo "$trigger_content" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\.-]+)?(\+[a-zA-Z0-9\.-]+)?$'; then
      target_version="$trigger_content"
      echo "[$(date)] upgrade triggered with target version: $target_version"
      
      # Remove the upgrade.txt file
      rm "/opt/broadcast/app/triggers/upgrade.txt"
      
      # Run upgrade with version parameter
      /opt/broadcast/broadcast.sh upgrade --automated "$target_version"
      
      echo "[$(date)] upgrade to version $target_version completed"
    else
      # Fallback to standard upgrade for invalid/empty version content
      echo "[$(date)] upgrade triggered (fallback mode - invalid or empty version content: '$trigger_content')"
      
      # Remove the upgrade.txt file
      rm "/opt/broadcast/app/triggers/upgrade.txt"
      
      # Run standard upgrade without version
      /opt/broadcast/broadcast.sh upgrade --automated
      
      echo "[$(date)] upgrade completed (fallback mode)"
    fi
  fi

  if [ -f "/opt/broadcast/app/triggers/domains.txt" ]; then
    echo "[$(date)] domains change triggered, updating domains"
    # Copy domains.txt to /opt/broadcast/.other_domains
    cp "/opt/broadcast/app/triggers/domains.txt" "/opt/broadcast/.other_domains"

    domain=$(cat /opt/broadcast/.domain)
    if [ -f /opt/broadcast/.other_domains ]; then
      other_domains=$(cat /opt/broadcast/.other_domains | tr '\n' ',' | sed 's/,$//')
      echo "TLS_DOMAIN=$domain,$other_domains" >> /opt/broadcast/app/.env
    else
      echo "TLS_DOMAIN=$domain" >> /opt/broadcast/app/.env
    fi

    # Remove the domains.txt file
    rm "/opt/broadcast/app/triggers/domains.txt"

    # Ensure /opt/broadcast and all its contents belong to broadcast:broadcast
    chown -R broadcast:broadcast /opt/broadcast
    # Re-assert container-writable dirs after the broad chown (see common.sh)
    chown_container_writable_dirs

    echo "[$(date)] domains updated, restarting services"

    /opt/broadcast/broadcast.sh restart
  fi

  if [ -f "/opt/broadcast/app/triggers/backup-db.txt" ]; then
    echo "[$(date)] backup triggered, backing up database"
    rm "/opt/broadcast/app/triggers/backup-db.txt"
    /opt/broadcast/broadcast.sh backup_database
  fi

  if [ -f "/opt/broadcast/app/triggers/restart-jobs.txt" ]; then
    echo "[$(date)] restart-jobs triggered, restarting job container"
    rm "/opt/broadcast/app/triggers/restart-jobs.txt"
    cd /opt/broadcast
    docker compose restart job
    echo "[$(date)] job container restarted"
  fi
}
