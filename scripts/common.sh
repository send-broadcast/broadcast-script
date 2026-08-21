display_logo() {
  echo -e "\e[90m  ____                      _               _   \e[0m"
  echo -e "\e[90m | __ ) _ __ ___   __ _  __| | ___ __ _ ___| |_ \e[0m"
  echo -e "\e[90m |  _ \| '__/ _ \ / _\` |/ _\` |/ __/ _\` / __| __|\e[0m"
  echo -e "\e[90m | |_) | | | (_) | (_| | (_| | (_| (_| \__ \ |_ \e[0m"
  echo -e "\e[90m |____/|_|  \___/ \__,_|\__,_|\___\__,_|___/\__|\e[0m"
  echo -e "\e[90m                                                \e[0m"
  echo -e "\e[90m (c) Copyright 2024-2026, Furvur, Inc.\e[0m"
  echo -e "\e[90m Go to https://sendbroadcast.net for documentation and support.\e[0m"
  echo
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mThis script must be run as root.\e[0m"
    exit 1
  fi
}

# uid:gid the Broadcast app/job containers run as — fixed by the image's
# Dockerfile (`USER 1000:1000`), independent of any host user.
BROADCAST_CONTAINER_UID="${BROADCAST_CONTAINER_UID:-1000}"
BROADCAST_CONTAINER_GID="${BROADCAST_CONTAINER_GID:-1000}"

# Directories (relative to /opt/broadcast) that the containers WRITE to at
# runtime through docker-compose.yml bind mounts: upload storage, user
# uploads, the upgrade/backup trigger files, and Thruster's TLS material.
#
# app/monitor is deliberately NOT here. It is the one bind mount the traffic
# runs the other way on: the HOST writes it (monitor.sh, as the broadcast
# user via `su`) and the container only reads it (Installation#
# gather_system_info). Handing it to the container uid locks the writer out
# and host metrics silently stop updating every minute. Read access needs
# nothing but the mode 755 these dirs already carry.
broadcast_container_writable_dirs() {
  echo "app/storage app/uploads app/triggers ssl"
}

# Re-asserts container-uid ownership on the container-written directories.
#
# The broad `chown -R broadcast:broadcast /opt/broadcast` passes these dirs
# to the host broadcast user, whose uid is 1000 only by coincidence.
# `useradd broadcast` takes the next free uid, and on hosts where uid 1000
# is already occupied (most cloud images ship a default uid-1000 user like
# ubuntu/admin/ec2-user) broadcast lands on 1001+. The dirs are mode 755
# (owner-only write), so every container write then fails: the dashboard's
# Upgrade button writes no trigger file (silent no-op, customer report
# 2026-08-21), uploads error, and Thruster cannot persist its certificate.
# Call this after ANY broad chown of /opt/broadcast.
chown_container_writable_dirs() {
  local d
  for d in $(broadcast_container_writable_dirs); do
    if [ -d "/opt/broadcast/$d" ]; then
      chown -R "${BROADCAST_CONTAINER_UID}:${BROADCAST_CONTAINER_GID}" "/opt/broadcast/$d" 2>/dev/null || true
    fi
  done
}

check_installation_domain() {
  if [ -f /opt/broadcast/.domain ]; then
    return
  fi

  while true; do
    echo -e "\e[32mPlease enter the domain name for this server (eg. broadcast.example.com): \e[0m"
    read installation_domain
    if [ ! -z "$installation_domain" ]; then
      echo "$installation_domain" > /opt/broadcast/.domain
      break
    else
      echo
      echo -e "\e[31mDomain name cannot be empty. Please try again.\e[0m"
      echo
    fi
  done
}

check_license() {
  if [ ! -f /opt/broadcast/.license ]; then
    ask_license
  fi
}

ask_license() {
  local license_file="/opt/broadcast/.license"
  local domain_file="/opt/broadcast/.domain"
  while true; do
    echo
    echo -e "\e[32mPlease enter your license key: \e[0m"
    read license_key
    if [ -z "$license_key" ]; then
      echo
      echo -e "\e[31mLicense key cannot be empty. Please try again.\e[0m"
      echo
    else
      echo
      echo -e "\e[34mYou entered: $license_key\e[0m"
      echo -e "\e[33mIs this correct? (y/n): \e[0m"
      read confirm
      if [[ $confirm =~ ^[Yy]$ ]]; then
        local domain=$(cat "$domain_file")
        echo
        echo -e "\e[34mConfirm you want to install for the domain [$domain] with license key [$license_key]?\e[0m"
        echo -e "\e[33mProceed with installation? [y/n]\e[0m"
        read install_confirm
        if [[ $install_confirm =~ ^[Yy]$ ]]; then
          echo
          echo "$license_key" > "$license_file"
          if validate_license; then
            echo
            echo -e "\e[33mPlease point your domain to the IP address of this server.\e[0m"
            echo -e "\e[33mThis is crucial for the proper functioning of your Broadcast installation.\e[0m"
            echo -e "\e[33mYou can do this by updating your domain's DNS settings to point to this server's IP address.\e[0m"
            echo
            echo -e "\e[33mIf you need further instructions, please see https://sendbroadcast.net/docs/installation\e[0m"
            echo
            echo -e "\e[1;31m** DO THIS BEFORE PROCEEDING **\e[0m"
            echo
            echo -e "\e[1;31mOnce you've completed this step, press enter to continue...\e[0m"
            read
            break
          else
            rm -f "$license_file"
          fi
        else
          rm -f "$domain_file"
          rm -f "$license_file"
          echo -e "\e[31mInstallation cancelled. Let's start over.\e[0m"
        fi
      else
        echo -e "\e[33mLet's try again.\e[0m"
      fi
    fi
  done
}

validate_license() {
  local license_file="/opt/broadcast/.license"
  local domain_file="/opt/broadcast/.domain"
  local response
  local http_code

  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y jq
  fi

  if [ ! -f "$license_file" ]; then
    echo "License file not found."
    return 1
  fi

  local license_key=$(cat "$license_file")
  local domain=$(cat "$domain_file")

  # Single curl call capturing both HTTP status code and response body
  local tmpfile=$(mktemp)
  http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X POST -H "Content-Type: application/json" -d "{\"key\":\"$license_key\", \"domain\":\"$domain\"}" https://sendbroadcast.net/license/check)
  response=$(cat "$tmpfile")
  rm -f "$tmpfile"

  if [ "$http_code" = "401" ]; then
    echo -e "\e[31mInvalid license key. Aborted.\e[0m"
    return 1
  fi

  if [ "$http_code" != "200" ]; then
    echo -e "\e[31mUnexpected HTTP response ($http_code) during license validation. Aborted.\e[0m"
    return 1
  fi

  # Validate that response is valid JSON before parsing
  if ! echo "$response" | jq empty 2>/dev/null; then
    echo -e "\e[31mInvalid response from license server. Aborted.\e[0m"
    return 1
  fi

  # Parse the JSON response
  local registry_url=$(echo "$response" | jq -r '.registry_url')
  local registry_login=$(echo "$response" | jq -r '.registry_login')
  local registry_password=$(echo "$response" | jq -r '.registry_password')

  # Validate all required fields are present and non-empty
  if [ -z "$registry_url" ] || [ "$registry_url" = "null" ]; then
    echo -e "\e[31mUnexpected error during license validation. Aborted.\e[0m"
    return 1
  fi

  if [ -z "$registry_login" ] || [ "$registry_login" = "null" ]; then
    echo -e "\e[31mMissing registry login in license response. Aborted.\e[0m"
    return 1
  fi

  if [ -z "$registry_password" ] || [ "$registry_password" = "null" ]; then
    echo -e "\e[31mMissing registry password in license response. Aborted.\e[0m"
    return 1
  fi

  echo -e "\e[32mLicense key valid!\e[0m"

  # Replace, never append: validate_license is run casually for its
  # summary, and blind appends would grow .env with duplicate credentials
  if [ -f /opt/broadcast/.env ]; then
    grep -v "^BROADCAST_REGISTRY_" /opt/broadcast/.env > /opt/broadcast/.env.tmp || true
    mv /opt/broadcast/.env.tmp /opt/broadcast/.env
  fi
  echo "BROADCAST_REGISTRY_URL=$registry_url" >> /opt/broadcast/.env
  echo "BROADCAST_REGISTRY_LOGIN=$registry_login" >> /opt/broadcast/.env
  echo "BROADCAST_REGISTRY_PASSWORD=$registry_password" >> /opt/broadcast/.env

  print_license_summary "$response" "$domain"

  return 0
}

# Operator summary from the enriched /license/check response. Every field
# is optional — older server responses simply skip the summary, so this
# degrades cleanly during rollout. Sensitive values arrive pre-masked.
print_license_summary() {
  local response="$1"
  local this_domain="$2"

  local license_name
  license_name=$(echo "$response" | jq -r '.license_name // empty')
  [ -z "$license_name" ] && return 0

  local license_status key_masked buyer_name buyer_email servers_total servers_used
  local monitoring latest_version other_domains installed_version
  license_status=$(echo "$response" | jq -r '.license_status // empty')
  key_masked=$(echo "$response" | jq -r '.license_key_masked // empty')
  buyer_name=$(echo "$response" | jq -r '.buyer_name // empty')
  buyer_email=$(echo "$response" | jq -r '.buyer_email // empty')
  servers_total=$(echo "$response" | jq -r '.servers_total // empty')
  servers_used=$(echo "$response" | jq -r '.servers_used // empty')
  # tostring, not '// empty': a false value must survive (false // empty
  # yields empty in jq, which would silently drop the disabled state)
  monitoring=$(echo "$response" | jq -r '.monitoring_enabled | tostring')
  latest_version=$(echo "$response" | jq -r '.latest_version // empty')
  other_domains=$(echo "$response" | jq -r '.domains[]? // empty' | grep -vx "$this_domain" | paste -sd ', ' -)

  echo
  echo -e "\e[1mLicense details\e[0m"
  echo "  License:     $license_name${license_status:+ ($license_status)}"
  if [ -n "$buyer_name" ]; then
    echo "  Buyer:       $buyer_name${buyer_email:+ <$buyer_email>}"
  fi
  [ -n "$key_masked" ] && echo "  Key:         $key_masked"
  if [ -n "$servers_total" ] && [ -n "$servers_used" ]; then
    echo "  Servers:     $servers_used of $servers_total used"
  fi
  echo "  This server: $this_domain (registered)"
  [ -n "$other_domains" ] && echo "  Also registered: $other_domains"

  if [ -n "$latest_version" ]; then
    installed_version=$(cat /opt/broadcast/.current_version 2>/dev/null || echo "")
    if [ "$installed_version" = "$latest_version" ]; then
      echo "  Version:     $installed_version — up to date"
    elif [ -n "$installed_version" ]; then
      echo -e "  Version:     $installed_version — \e[33mupdate available: $latest_version\e[0m (./broadcast.sh upgrade)"
    else
      echo "  Version:     latest release is $latest_version"
    fi
  fi

  case "$monitoring" in
    true)  echo "  Monitoring:  enabled for this server" ;;
    false) echo "  Monitoring:  disabled — enable it on the Servers page of your sendbroadcast.net dashboard" ;;
  esac
  echo
}

load_registry_info() {
  if [ -f /opt/broadcast/.env ]; then
    export $(grep -v '^#' /opt/broadcast/.env | xargs)
  else
    echo -e "\e[31mEnvironment file not found. Please validate your license first.\e[0m"
    return 1
  fi
}

# Version validation helpers for semantic version format checking
validate_semantic_version() {
  local version="$1"
  if [ -z "$version" ]; then
    return 1
  fi
  
  # Check semantic version format: x.y.z with optional pre-release and build metadata
  if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\.-]+)?(\+[a-zA-Z0-9\.-]+)?$'; then
    return 0
  else
    return 1
  fi
}

get_current_version() {
  if [ -f "/opt/broadcast/.current_version" ]; then
    cat /opt/broadcast/.current_version
  else
    echo "unknown"
  fi
}

# NOTE: compare_versions lives in restore.sh (return-code API: 0 equal,
# 1 first-greater, 2 first-less). A second string-API definition ("equal"/
# "less"/"greater") used to sit here with ZERO callers — restore.sh is
# sourced after common.sh, so its definition silently won anyway. Removed
# to prevent anyone coding against the shadowed API.

# Version history tracking for upgrade/downgrade audit trail
log_version_change() {
  local operation="$1"    # "upgrade" or "downgrade"
  local from_version="$2"
  local to_version="$3"
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local history_file="/opt/broadcast/.version_history"
  
  # Create history file if it doesn't exist
  if [ ! -f "$history_file" ]; then
    echo "# Broadcast Version History" > "$history_file"
    echo "# Format: TIMESTAMP | OPERATION | FROM_VERSION | TO_VERSION" >> "$history_file"
  fi
  
  # Append version change to history
  echo "$timestamp | $operation | $from_version | $to_version" >> "$history_file"
  
  # Keep only the last 100 entries to prevent file from growing too large
  tail -102 "$history_file" > "${history_file}.tmp" && mv "${history_file}.tmp" "$history_file"
}

get_version_history() {
  local history_file="/opt/broadcast/.version_history"
  if [ -f "$history_file" ]; then
    cat "$history_file"
  else
    echo "No version history available"
  fi
}

generate_encryption_keys() {
  local app_env_file="/opt/broadcast/app/.env"

  if [ ! -f "$app_env_file" ]; then
    echo -e "\e[31mError: app/.env not found. Is Broadcast installed?\e[0m"
    return 1
  fi

  if grep -q "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" "$app_env_file" 2>/dev/null; then
    echo -e "\e[32mActive Record encryption keys already exist in app/.env.\e[0m"
    echo -e "\e[33mTo regenerate, remove the existing keys from app/.env first.\e[0m"
    return 0
  fi

  echo -e "\e[33mGenerating Active Record encryption keys...\e[0m"
  echo "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)" >> "$app_env_file"
  echo "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)" >> "$app_env_file"
  echo "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)" >> "$app_env_file"

  chown broadcast:broadcast "$app_env_file"

  echo -e "\e[32mEncryption keys generated and added to app/.env.\e[0m"
  echo -e "\e[33mRestart Broadcast for changes to take effect: ./broadcast.sh restart\e[0m"
}

change_installation_domain() {
  local current_domain_file="/opt/broadcast/.domain"
  local current_domain=""
  
  if [ -f "$current_domain_file" ]; then
    current_domain=$(cat "$current_domain_file")
    echo -e "\e[34mCurrent installation domain: $current_domain\e[0m"
  else
    echo -e "\e[33mNo current domain found.\e[0m"
  fi
  
  echo
  echo -e "\e[32mEnter the new installation domain (e.g., broadcast.newdomain.com): \e[0m"
  read -r new_domain
  
  # Validate domain input
  if [ -z "$new_domain" ]; then
    echo -e "\e[31mError: Domain cannot be empty.\e[0m"
    return 1
  fi
  
  # Basic domain format validation
  if ! echo "$new_domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
    echo -e "\e[31mError: Invalid domain format.\e[0m"
    return 1
  fi
  
  # Confirm the change
  echo
  echo -e "\e[33mYou are about to change the installation domain from:\e[0m"
  echo -e "\e[31m  FROM: $current_domain\e[0m"
  echo -e "\e[32m  TO:   $new_domain\e[0m"
  echo
  echo -e "\e[31mWARNING: This will restart all Broadcast services and update SSL certificates.\e[0m"
  echo -e "\e[33mAre you sure you want to proceed? (y/N): \e[0m"
  read -r confirm
  
  if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo -e "\e[33mOperation cancelled.\e[0m"
    return 0
  fi
  
  echo -e "\e[33mProcessing domain change...\e[0m"
  
  # Update domain files first (while services are running)
  echo "$new_domain" > "$current_domain_file"
  echo -e "\e[32mUpdated primary domain file (.domain).\e[0m"
  
  # Update .other_domains if it exists (remove the old primary domain if present)
  local other_domains_file="/opt/broadcast/.other_domains"
  if [ -f "$other_domains_file" ]; then
    # Remove the old domain from .other_domains if it exists there
    grep -v "^$current_domain$" "$other_domains_file" > "$other_domains_file.tmp" && mv "$other_domains_file.tmp" "$other_domains_file"
    echo -e "\e[32mUpdated other domains file (.other_domains).\e[0m"
  fi
  
  # Update TLS_DOMAIN in app/.env
  local app_env_file="/opt/broadcast/app/.env"
  if [ -f "$app_env_file" ]; then
    # Check if there are additional domains
    if [ -f "$other_domains_file" ] && [ -s "$other_domains_file" ]; then
      local other_domains=$(cat "$other_domains_file" | tr '\n' ',' | sed 's/,$//')
      # Update TLS_DOMAIN with new primary domain plus other domains
      sed -i "s/^TLS_DOMAIN=.*/TLS_DOMAIN=$new_domain,$other_domains/" "$app_env_file"
      echo -e "\e[32mUpdated TLS_DOMAIN with primary + additional domains.\e[0m"
    else
      # Update TLS_DOMAIN with just the new domain
      sed -i "s/^TLS_DOMAIN=.*/TLS_DOMAIN=$new_domain/" "$app_env_file"
      echo -e "\e[32mUpdated TLS_DOMAIN with primary domain only.\e[0m"
    fi
  else
    echo -e "\e[31mWarning: Could not find app/.env file.\e[0m"
  fi
  
  # Update Rails database directly (while services are still running)
  echo -e "\e[33mUpdating database record...\e[0m"
  su - broadcast -c "cd /opt/broadcast && docker compose exec app bin/rails runner \"Installation.first&.update!(hosted_domain: '$new_domain')\""
  echo -e "\e[32mDatabase record updated.\e[0m"
  
  # Ensure proper ownership
  chown -R broadcast:broadcast /opt/broadcast
  # Re-assert container-writable dirs after the broad chown (see above)
  chown_container_writable_dirs
  
  # Restart services to pick up new SSL certificates and configuration
  echo -e "\e[33mRestarting Broadcast services to apply changes...\e[0m"
  systemctl restart broadcast
  
  # Log the change
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$timestamp | domain_change | $current_domain | $new_domain" >> /opt/broadcast/.domain_history
  
  echo
  echo -e "\e[32mInstallation domain successfully changed to: $new_domain\e[0m"
  echo -e "\e[33mServices are restarting. New SSL certificates will be generated automatically.\e[0m"
  echo -e "\e[33mPlease ensure your DNS points to this server before accessing the new domain.\e[0m"
  
  return 0
}
