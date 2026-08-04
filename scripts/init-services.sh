#!/bin/bash

# The single source of truth for the broadcast.service unit. Boot-resilience
# settings exist because of a real incident (2026-08-03): a reboot where the
# network came up after docker made `docker compose up` fail instantly;
# systemd retried at its default 100ms pace, burned the default
# 5-starts-in-10s limit in seconds, and parked the service in 'failed'
# ("Start request repeated too quickly") until a human started it.
#   - Wants/After network-online.target: don't race the network at boot
#   - StartLimitIntervalSec=0: never give up retrying
#   - RestartSec=5: space retries out instead of the 100ms default
broadcast_service_unit() {
  cat <<EOT
[Unit]
Description=Broadcast
Requires=docker.service
Wants=network-online.target
After=docker.service network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
# No explicit -f: compose discovers docker-compose.yml via WorkingDirectory
# and auto-merges docker-compose.override.yml — the supported path for
# customer customizations (an explicit -f would silently ignore it).
ExecStart=/bin/bash -c "set -a && . /opt/broadcast/.image && set +a && docker compose up"
ExecStop=/bin/bash -c "set -a && . /opt/broadcast/.image && set +a && docker compose down"
Restart=always
RestartSec=5
User=broadcast
WorkingDirectory=/opt/broadcast

[Install]
WantedBy=multi-user.target
EOT
}

create_broadcast_service() {
  echo -e "\e[33mCreating systemd service for Broadcast...\e[0m"

  # Disable the service if it exists
  if systemctl is-active --quiet broadcast.service; then
    sudo systemctl disable broadcast.service
  fi

  # Create systemd service file for Broadcast
  broadcast_service_unit | sudo tee /etc/systemd/system/broadcast.service > /dev/null

  # Reload systemd to recognize the new service
  sudo systemctl daemon-reload

  # Enable the service to start on boot
  sudo systemctl enable broadcast.service
}

# Rewrite the installed unit when it differs from the current template.
# The unit is otherwise written only at install time, so template fixes
# would never reach existing servers — upgrade and fix call this to
# deliver them. Returns 0 if the unit was (re)written, 1 if already
# current, so callers can report accurately; call it inside an `if` so
# the no-change return does not trip `set -e`.
refresh_broadcast_service() {
  if broadcast_service_unit | cmp -s - /etc/systemd/system/broadcast.service 2>/dev/null; then
    return 1
  fi

  broadcast_service_unit | sudo tee /etc/systemd/system/broadcast.service > /dev/null
  sudo systemctl daemon-reload
  return 0
}
