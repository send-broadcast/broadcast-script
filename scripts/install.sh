function install() {
  echo "Installing Broadcast"
  # Check if broadcast user exists, create if not
  if ! id "broadcast" &>/dev/null; then
    echo "Creating broadcast user..."
    sudo useradd -m -s /bin/bash broadcast
    echo "broadcast ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/broadcast
  else
    echo "Broadcast user already exists."
  fi

  # Update packages
  apt_get update
  apt_get upgrade -y

  # Ensure /opt/broadcast exists and has correct ownership
  sudo chown -R broadcast:broadcast /opt/broadcast

  # Setup Uncomplicated Firewall
  apt_get install ufw -y
  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  # Install and configure fail2ban
  echo "Installing and configuring fail2ban..."

  # Unfortunately, fail2ban <=> Ubuntu 24.04 LTS is not compatible due to Python syntax issues
  # The package comes straight from GitHub, outside apt's signature checks,
  # so it is pinned to the sha256 of the 1.1.0 release asset and refused if
  # it differs.
  local fail2ban_url="https://github.com/fail2ban/fail2ban/releases/download/1.1.0/fail2ban_1.1.0-1.upstream1_all.deb"
  local fail2ban_sha256="4ef39bbda961aa4c4e97a099e962cf9863d66edf2808caab668ddcd4ed2ebda2"
  local fail2ban_deb
  fail2ban_deb=$(mktemp)
  curl -fsSL --retry 3 -o "$fail2ban_deb" "$fail2ban_url"
  if ! echo "$fail2ban_sha256  $fail2ban_deb" | sha256sum -c --status -; then
    rm -f "$fail2ban_deb"
    echo -e "\e[31mError: the fail2ban package from GitHub does not match its expected checksum. Install stopped.\e[0m"
    exit 1
  fi
  sudo dpkg -i "$fail2ban_deb"
  sudo systemctl enable fail2ban
  sudo systemctl start fail2ban
  rm -f "$fail2ban_deb" # Cleanup

  # Allow ports 22, 443, and 80
  sudo ufw allow 22/tcp
  sudo ufw allow 443/tcp
  sudo ufw allow 80/tcp

  # Enable UFW
  sudo ufw --force enable

  # Check if swap already exists
  if ! grep -q "/swapfile" /etc/fstab; then
    echo "Creating swap file..."
    total_memory=$(free -b | awk '/^Mem:/{print $2}')
    swap_size=$((total_memory / 1024 / 1024))  # Convert to MB
    sudo fallocate -l ${swap_size}M /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  else
    echo "Swap file already exists. Skipping creation."
  fi

  # Setup the timezone for the server to UTC
  sudo timedatectl set-timezone UTC

  # Install network time protocol
  apt_get install chrony -y

  # Set up unattended upgrades without user interaction
  apt_get install unattended-upgrades -y
  echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades

  # Install Docker
  echo "Installing Docker..."

  # Add Docker's official GPG key
  apt_get update
  apt_get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt_get update

  # Read domain from configuration file
  if [ ! -f /opt/broadcast/.domain ]; then
    echo
    echo -e "\e[31mError: Domain configuration file not found.\e[0m"
    echo
    echo "The file /opt/broadcast/.domain is required but does not exist."
    echo "This can happen if the installation was interrupted or run non-interactively."
    echo
    echo "To fix this, create the file manually with your domain:"
    echo
    echo -e "  \e[33mecho 'your-domain.example.com' > /opt/broadcast/.domain\e[0m"
    echo
    echo "Then run the install command again:"
    echo
    echo -e "  \e[33m./broadcast.sh install\e[0m"
    echo
    exit 1
  fi
  domain=$(cat /opt/broadcast/.domain)

  # Check if app/.env exists, create if not
  if [ -f /opt/broadcast/app/.env ]; then
    echo "app/.env already exists. Skipping creation."
  else
    echo "Creating app/.env..."

    # Set some app environment variables
    local postgres_user="broadcast"
    local postgres_password=$(openssl rand -hex 16)

    echo "RAILS_ENV=production" >> /opt/broadcast/app/.env
    echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" >> /opt/broadcast/app/.env
    echo "DATABASE_HOST=postgres" >> /opt/broadcast/app/.env
    echo "DATABASE_USERNAME=$postgres_user" >> /opt/broadcast/app/.env
    echo "DATABASE_PASSWORD=$postgres_password" >> /opt/broadcast/app/.env
    echo "STORAGE_PATH=/rails/ssl" >> /opt/broadcast/app/.env

    # Set the TLS domain
    if [ -f /opt/broadcast/.other_domains ]; then
      other_domains=$(cat /opt/broadcast/.other_domains | tr '\n' ',' | sed 's/,$//')
      echo "TLS_DOMAIN=$domain,$other_domains" >> /opt/broadcast/app/.env
    else
      echo "TLS_DOMAIN=$domain" >> /opt/broadcast/app/.env
    fi

    license=$(cat /opt/broadcast/.license)
    echo "LICENSE_KEY=$license" >> /opt/broadcast/app/.env
    echo "BROADCAST_MANAGED=true" >> /opt/broadcast/app/.env
    echo "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env
    echo "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env
    echo "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 16)" >> /opt/broadcast/app/.env

    # Set some db environment variables
    echo "POSTGRES_USER=$postgres_user" >> /opt/broadcast/db/.env
    echo "POSTGRES_PASSWORD=$postgres_password" >> /opt/broadcast/db/.env
    echo "POSTGRES_MULTIPLE_DATABASES=broadcast_primary_production,broadcast_queue_production,broadcast_cable_production" >> /opt/broadcast/db/.env
  fi

  # Install Docker packages
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Add broadcast user to the docker group
  sudo usermod -aG docker broadcast

  # Change ownership of /opt/broadcast and all its contents to the broadcast user
  sudo chown -R broadcast:broadcast /opt/broadcast
  # ...except the dirs the containers write (uid 1000 inside the image) —
  # must happen BEFORE the service starts below, see common.sh. A failure is
  # printed there; the install carries on so the operator sees it in context.
  chown_container_writable_dirs || true

  load_registry_info
  registry_login "$BROADCAST_REGISTRY_URL" "$BROADCAST_REGISTRY_LOGIN" "$BROADCAST_REGISTRY_PASSWORD"

  echo -e "\e[33mDocker installation completed!\e[0m"

  source /opt/broadcast/scripts/init-services.sh
  create_broadcast_service

  # Pull docker images and start the service as the broadcast user
  sudo -u broadcast bash << EOF
    cd /opt/broadcast
    set -a && source .image && set +a && docker compose pull
    sudo systemctl start broadcast.service
EOF

  echo -e "\e[33mBroadcast Docker Compose service created and started!\e[0m"

  echo -e "\e[33mSetting up cron jobs...\e[0m"
  mkdir -p /opt/broadcast/logs/cron
  ensure_cron_entry "* * * * *" monitor
  ensure_cron_entry "* * * * *" trigger
  ensure_cron_entry "* * * * *" health
  ensure_cron_entry "* * * * *" recover
  ensure_cron_entry "0 0 * * *" update

  echo -e "\e[33mSetting permissions (double checking)...\e[0m"
  sudo chown -R broadcast:broadcast /opt/broadcast
  # Re-assert container-writable dirs after the broad chown (see common.sh)
  chown_container_writable_dirs || true
  # Ensure db/init-scripts is readable by the postgres container (runs as uid 70)
  sudo chmod -R o+rX /opt/broadcast/db/init-scripts

  # Install inotify-tools for log streaming trigger watcher
  echo -e "\e[33mInstalling inotify-tools for log streaming...\e[0m"
  apt_get install -y inotify-tools

  # Set up the log streaming trigger watcher service
  echo -e "\e[33mSetting up log streaming trigger watcher service...\e[0m"
  sudo cp /opt/broadcast/scripts/broadcast-logs-watcher.service /etc/systemd/system/
  sudo cp /opt/broadcast/scripts/broadcast-post-upgrade-cleanup.service /etc/systemd/system/
  sudo chmod +x /opt/broadcast/scripts/post-upgrade-cleanup.sh
  sudo systemctl daemon-reload
  sudo systemctl enable broadcast-logs-watcher
  sudo systemctl start broadcast-logs-watcher

  # Install logrotate
  apt_get install -y logrotate

  # Set up logrotate for Broadcast logs
  echo "Setting up logrotate for Broadcast logs..."
  sudo tee /etc/logrotate.d/broadcast <<EOF
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
EOF

  echo -e "\e[90m  ____                      _               _   \e[0m"
  echo -e "\e[90m | __ ) _ __ ___   __ _  __| | ___ __ _ ___| |_ \e[0m"
  echo -e "\e[90m |  _ \| '__/ _ \ / _\` |/ _\` |/ __/ _\` / __| __|\e[0m"
  echo -e "\e[90m | |_) | | | (_) | (_| | (_| | (_| (_| \__ \ |_ \e[0m"
  echo -e "\e[90m |____/|_|  \___/ \__,_|\__,_|\___\__,_|___/\__|\e[0m"
  echo -e "\e[90m                                                \e[0m"
  echo -e "\e[90m (c) Copyright 2024-2026, Furvur, Inc.\e[0m"
  echo

  echo -e "Some links to get you started:"
  echo -e "  - Web interface: https://$domain"
  echo -e "  - Customer dashboard & support: https://sendbroadcast.net/dashboard"
  echo -e "  - Documentation: https://sendbroadcast.net/docs"
  echo
  echo -e "Thank you for choosing Broadcast!"
  echo
  if [ "${BROADCAST_NO_REBOOT:-0}" = "1" ]; then
    echo -e "\e[33mReboot skipped (--no-reboot). Broadcast is running; reboot when convenient to finish applying system updates: sudo reboot\e[0m"
    echo
    echo -e "\e[93mOpen https://$domain to set up your admin account.\e[0m"
  else
    echo -e "\e[31mThis server will reboot in 1 minute to finish applying system updates (cancel with: sudo shutdown -c).\e[0m"
    echo
    echo -e "\e[93mWhen your system is rebooted, you can access the web interface at https://$domain to set up your admin account.\e[0m"
  fi

  # .image (the architecture-specific image) is written by set_docker_image
  # in broadcast.sh before install() runs, so the pull above already used
  # the right image for this CPU.

  if [ -f /opt/broadcast/.install_complete ]; then
    install_url=$(cat /opt/broadcast/.install_complete)
    if [ ! -z "$install_url" ]; then
      curl -s -S -L --retry 3 "$install_url" || echo "Failed to notify installation completion"
    fi
  fi

  # Scheduled rather than immediate, so the installer exits cleanly with
  # status 0 and a remote session (an agent over SSH) sees the result
  # before the connection drops.
  if [ "${BROADCAST_NO_REBOOT:-0}" != "1" ]; then
    sudo shutdown -r +1 "Broadcast installation complete; rebooting." || true
  fi
}
