# Broadcast Installer

## Introduction

This script installs the Broadcast script on a Linux server. It sets up the necessary user and group, configures sudo for passwordless access, and ensures the script is executable.

## System Requirements

- Ubuntu Server 24.04 (fresh install)
- Minimum 2GB RAM
- Minimum 40GB disk space

## Usage

Run the following commands as root:

```bash
rm -rf /opt/broadcast && git clone https://github.com/send-broadcast/broadcast-script.git /opt/broadcast && cd /opt/broadcast && chmod +x broadcast.sh && ./broadcast.sh install
```

## Troubleshooting

If your installation is misbehaving (site down, errors, slow responses), run:

```bash
cd /opt/broadcast && ./broadcast.sh diagnose
```

This collects container logs, system state, and health probes into a single
tarball under `/opt/broadcast/logs/` and prints a summary of what it found.
Attach the tarball to your support email. Run it **before** restarting
anything — restarting destroys the container logs that explain what happened.

## License

This script is intended for customers of Broadcast. Please refer to the license that came with your Broadcast product for the terms of use.
