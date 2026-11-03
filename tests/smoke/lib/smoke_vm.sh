#!/bin/bash

# Shared plumbing for the VM smoke tests (test_multipass_smoke.sh and test_bootstrap_e2e.sh):
# the Vagrantfile, starting a VM, running commands in it, and masking secrets in everything the
# harness prints or saves. Sourcing this file only defines functions.
#
# tests/unit/test_smoke_harness.sh checks, without a VM, that every smoke script sources this
# file and writes no Vagrantfile of its own, and that the redaction masks every form of a secret.

SMOKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set by smoke_vagrant_up: the ssh config of the running VM
SMOKE_SSH_CFG=""

# Secrets to mask, one per line, in a file only this user can read (smoke_redact_add). A file,
# not a variable: the filter started by smoke_redact_output picks up secrets added after it began.
if [ -z "${SMOKE_REDACT_DIR:-}" ] || [ ! -d "$SMOKE_REDACT_DIR" ]; then
    SMOKE_REDACT_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/smoke-redact.XXXXXX")"
    export SMOKE_REDACT_SECRETS_FILE="$SMOKE_REDACT_DIR/secrets"
    (umask 077 && : > "$SMOKE_REDACT_SECRETS_FILE")
fi

# QEMU flags for the host CPU. macOS uses Apple's HVF accelerator on both Apple Silicon (aarch64)
# and Intel (x86_64).
smoke_qemu_flags() {
    if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
        SMOKE_QEMU_ARCH="aarch64"; SMOKE_QEMU_MACHINE="virt,accel=hvf,highmem=on"
    else
        SMOKE_QEMU_ARCH="x86_64"; SMOKE_QEMU_MACHINE="q35,accel=hvf"
    fi
}

# smoke_write_vagrantfile DIR UBUNTU_VERSION SSH_PORT HOSTNAME [EXTRA_CONFIG]
# Writes DIR/Vagrantfile: a cloud-image box on QEMU, 2 CPUs, 2 GB, no /vagrant share. EXTRA_CONFIG
# (Ruby, inside the configure block) adds synced folders or provisioning.
smoke_write_vagrantfile() {
    local dir="$1" version="$2" port="$3" hostname="$4" extra="${5:-}"
    smoke_qemu_flags
    mkdir -p "$dir"
    cat > "$dir/Vagrantfile" <<EOF
# Vagrant 2.4's port-collision check does a non-blocking connect with a
# 0.1s timeout; on macOS 27 that reports every localhost port as open, so
# "vagrant up" refuses to start any VM ("The forwarded port to ... is already
# in use"). A plain blocking connect gives the right answer (ECONNREFUSED for
# a free port).
require "socket"
module Vagrant
  module Util
    module IsPortOpen
      def is_port_open?(host, port)
        TCPSocket.new(host, port).close
        true
      rescue SystemCallError
        false
      end
    end
  end
end

Vagrant.configure("2") do |config|
  config.vm.box = "cloud-image/ubuntu-${version}"
  config.vm.hostname = "${hostname}"
  config.vm.provider "qemu" do |qe|
    qe.arch = "${SMOKE_QEMU_ARCH}"
    qe.machine = "${SMOKE_QEMU_MACHINE}"
    qe.cpu = "host"
    qe.smp = "cpus=2,sockets=1,cores=2,threads=1"
    qe.memory = "2048M"
    qe.net_device = "virtio-net-pci"
    qe.ssh_port = "${port}"
  end
  # QEMU has no virtfs share by default
  config.vm.synced_folder ".", "/vagrant", disabled: true
${extra}
end
EOF
}

# smoke_vagrant_up DIR [LOG]: starts the VM (output to LOG when given) and writes DIR/ssh.cfg
smoke_vagrant_up() {
    local dir="$1" log="${2:-}" rc=0
    if [ -n "$log" ]; then
        (cd "$dir" && vagrant up --provider=qemu) > "$log" 2>&1 || rc=$?
    else
        (cd "$dir" && vagrant up --provider=qemu) || rc=$?
    fi
    [ "$rc" = "0" ] || return "$rc"
    smoke_ssh_config "$dir"
}

# smoke_ssh_config DIR: (re)writes DIR/ssh.cfg, also after a "vagrant reload"
smoke_ssh_config() {
    local dir="$1"
    (cd "$dir" && vagrant ssh-config) > "$dir/ssh.cfg" || return 1
    SMOKE_SSH_CFG="$dir/ssh.cfg"
}

# smoke_ssh <ssh-flag> '<command>': plain ssh, so -T (no TTY) really means no TTY
smoke_ssh() {
    local flag="$1"; shift
    ssh -F "$SMOKE_SSH_CFG" "$flag" -o ConnectTimeout=10 -o ServerAliveInterval=15 default "$@" < /dev/null
}

# smoke_root '<command>': runs the command as root under bash. The vagrant user's login shell is
# sh, which cannot parse bash's $'...' quoting, and nested quoting mangles quotes in the command,
# so it travels base64-encoded.
smoke_root() {
    smoke_ssh -T "echo $(printf '%s' "$1" | base64 | tr -d '\n') | base64 -d | sudo bash"
}

# --- Redaction -----------------------------------------------------------------------------------

smoke_redact_reset() {
    : > "$SMOKE_REDACT_SECRETS_FILE"
}

# smoke_redact_add SECRET...: masks these values from now on (empty values are ignored)
smoke_redact_add() {
    local s
    for s in "$@"; do
        [ -n "$s" ] && printf '%s\n' "$s" >> "$SMOKE_REDACT_SECRETS_FILE"
    done
    return 0
}

# smoke_redact_vm_secrets: also masks the secret values in the VM's env files (registry login and
# password, database password, Rails keys) once the install wrote them
smoke_redact_vm_secrets() {
    local values v
    values=$(smoke_root "cat /opt/broadcast/.env /opt/broadcast/app/.env /opt/broadcast/db/.env 2>/dev/null | sed -n -E 's/^[A-Z0-9_]*(PASSWORD|SECRET|LICENSE|TOKEN|_KEY|_LOGIN)[A-Z0-9_]*=//p'" 2>/dev/null) || return 0
    while IFS= read -r v; do
        v="${v%\"}"; v="${v#\"}"
        smoke_redact_add "$v"
    done <<< "$values"
}

# Filter: stdin to stdout with every registered secret masked (see redact.pl for every form it
# catches). It prints as the output arrives, holding back only the last few hundred characters
# until the output is quiet.
smoke_redact() {
    perl "$SMOKE_LIB_DIR/redact.pl"
}

# smoke_redact_output: from here on, everything the script prints (stdout and stderr) goes
# through smoke_redact
smoke_redact_output() {
    exec > >(smoke_redact) 2>&1
}

# smoke_redact_file FILE...: masks the secrets in saved files, in place
smoke_redact_file() {
    [ "$#" -gt 0 ] || return 0
    perl "$SMOKE_LIB_DIR/redact.pl" --in-place "$@"
}

# smoke_redact_cleanup: removes the secrets file (call it from the script's EXIT trap)
smoke_redact_cleanup() {
    rm -rf "$SMOKE_REDACT_DIR"
}
