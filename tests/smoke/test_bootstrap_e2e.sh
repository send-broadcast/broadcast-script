#!/bin/bash

# End-to-end test of the one-line installer (install.sh at the repo root) on
# fresh Ubuntu VMs (Vagrant + QEMU, same boxes as test_multipass_smoke.sh).
#
# install.sh is fetched from GitHub by raw URL, exactly as customers fetch it,
# so the branch under test must be pushed first. The fetched file is compared
# with the local install.sh so a stale raw-URL cache cannot pass silently.
#
# Scenarios (one fresh VM each):
#   noninteractive  (d) no terminal + no env vars fails fast (exit 2), nothing
#                   written; (b) `ssh -T host 'curl | sudo BROADCAST_DOMAIN=..
#                   BROADCAST_LICENSE=.. bash'` installs, exits 0, schedules
#                   the reboot, and the stack comes back after it; (c) a re-run
#                   on the installed server exits 3 and changes nothing; then a
#                   CLI `broadcast.sh upgrade` and a dashboard-trigger upgrade
#   interactive     (a) `ssh -t host 'curl | sudo bash -s -- --no-reboot'`,
#                   driven through the real prompts by expect over a real TTY,
#                   with one invalid domain and one wrong key typed first
#   legacy-upgrade  a server installed the OLD documented way from main, then
#                   `broadcast.sh upgrade` with the checkout tracking the branch
#                   under test: what every existing server does after the merge
#
# Usage:
#   ./tests/smoke/test_bootstrap_e2e.sh --ubuntu 24.04 --scenario noninteractive [--ref BRANCH] [--no-cleanup]
#
# Needs tests/smoke/.smoke-test.env (BROADCAST_LICENSE_KEY), vagrant with the
# vagrant-qemu plugin, and expect for the interactive scenario.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
REPO_SLUG="send-broadcast/broadcast-script"
DOMAIN="smoke-test.local"

UBUNTU_VERSION="24.04"
SCENARIO=""
REF="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
NO_CLEANUP=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_test()    { echo -e "\n${YELLOW}[TEST]${NC} $*"; TESTS_RUN=$((TESTS_RUN + 1)); }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail()    { echo -e "${RED}[FAIL]${NC} $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

while [ $# -gt 0 ]; do
    case "$1" in
        --ubuntu) UBUNTU_VERSION="$2"; shift ;;
        --scenario) SCENARIO="$2"; shift ;;
        --ref) REF="$2"; shift ;;
        --no-cleanup) NO_CLEANUP=true ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

case "$SCENARIO" in
    noninteractive) PORT_OFFSET=1 ;;
    interactive) PORT_OFFSET=2 ;;
    legacy-upgrade) PORT_OFFSET=3 ;;
    *) echo "--scenario must be noninteractive, interactive or legacy-upgrade"; exit 1 ;;
esac

RAW_URL="https://raw.githubusercontent.com/${REPO_SLUG}/${REF}/install.sh"
VAGRANT_DIR="$SCRIPT_DIR/.vagrant-smoke-e2e-${UBUNTU_VERSION}-${SCENARIO}"
SSH_CFG="$VAGRANT_DIR/ssh.cfg"

if [ -f "$SCRIPT_DIR/.smoke-test.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.smoke-test.env"
fi
if [ -z "${BROADCAST_LICENSE_KEY:-}" ]; then
    echo "BROADCAST_LICENSE_KEY is not set (tests/smoke/.smoke-test.env)"; exit 1
fi
KEY="$BROADCAST_LICENSE_KEY"

# Hide the license key in everything this harness prints
redact() { sed "s/${KEY}/<LICENSE>/g"; }

# vm_ssh <ssh-flag> '<command>' — plain ssh, so -T (no TTY) really means no TTY
vm_ssh() {
    local flag="$1"; shift
    ssh -F "$SSH_CFG" "$flag" -o ConnectTimeout=10 -o ServerAliveInterval=15 default "$@" < /dev/null
}
# The vagrant user's login shell is sh, which cannot parse bash's $'...'
# quoting, so the command travels base64-encoded and bash runs it as root.
vm_root() { vm_ssh -T "echo $(printf '%s' "$1" | base64 | tr -d '\n') | base64 -d | sudo bash"; }

wait_for() {
    local desc="$1" cmd="$2" tries="${3:-30}" delay="${4:-10}" i
    for ((i = 0; i < tries; i++)); do
        vm_root "$cmd" >/dev/null 2>&1 && return 0
        sleep "$delay"
    done
    log_info "timed out waiting for: $desc"
    return 1
}

cleanup() {
    if [ "$NO_CLEANUP" = true ]; then
        log_info "VM kept: cd $VAGRANT_DIR && vagrant ssh"
        return
    fi
    (cd "$VAGRANT_DIR" 2>/dev/null && vagrant destroy -f >/dev/null 2>&1) || true
    rm -rf "$VAGRANT_DIR"
}

setup_vm() {
    log_info "=== Ubuntu ${UBUNTU_VERSION} / ${SCENARIO}: launching a fresh VM ==="
    rm -rf "$VAGRANT_DIR"; mkdir -p "$VAGRANT_DIR"
    local qemu_arch qemu_machine
    if [ "$(uname -m)" = "arm64" ]; then
        qemu_arch="aarch64"; qemu_machine="virt,accel=hvf,highmem=on"
    else
        qemu_arch="x86_64"; qemu_machine="q35,accel=hvf"
    fi
    local port=$((51000 + ${UBUNTU_VERSION%%.*} * 10 + PORT_OFFSET))
    cat > "$VAGRANT_DIR/Vagrantfile" <<EOF
# Vagrant 2.4's port-collision check does a non-blocking connect with a
# 0.1s timeout; on macOS 27 that reports every localhost port as open, so
# "vagrant up" refuses to start any VM. A plain blocking connect gives the
# right answer (ECONNREFUSED for a free port).
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
  config.vm.box = "cloud-image/ubuntu-${UBUNTU_VERSION}"
  config.vm.hostname = "broadcast-e2e"
  config.vm.provider "qemu" do |qe|
    qe.arch = "${qemu_arch}"
    qe.machine = "${qemu_machine}"
    qe.cpu = "host"
    qe.smp = "cpus=2,sockets=1,cores=2,threads=1"
    qe.memory = "2048M"
    qe.net_device = "virtio-net-pci"
    qe.ssh_port = "${port}"
  end
  config.vm.synced_folder ".", "/vagrant", disabled: true
end
EOF
    (cd "$VAGRANT_DIR" && vagrant up --provider=qemu >"$VAGRANT_DIR/up.log" 2>&1) || {
        log_fail "vagrant up failed (see $VAGRANT_DIR/up.log)"; exit 1; }
    (cd "$VAGRANT_DIR" && vagrant ssh-config) > "$SSH_CFG"
    log_info "VM ready: $(vm_root '. /etc/os-release; echo $PRETTY_NAME; uname -m')"
}

check_raw_url_matches_local() {
    log_test "raw URL serves the local install.sh ($RAW_URL)"
    local remote_sha local_sha
    remote_sha=$(vm_root "curl -fsSL $RAW_URL | sha256sum | cut -d' ' -f1")
    local_sha=$(shasum -a 256 "$PROJECT_ROOT/install.sh" | cut -d' ' -f1)
    if [ -n "$remote_sha" ] && [ "$remote_sha" = "$local_sha" ]; then
        log_success "fetched install.sh matches the local file (sha256 ${local_sha:0:12})"
    else
        log_fail "fetched install.sh differs from the local file (remote ${remote_sha:-none}, local $local_sha) — push, or wait out the 5-minute raw cache"
        exit 1
    fi
}

# Everything an installed server must have, checked after each phase.
health_checks() {
    local label="$1" c name count
    log_info "--- health checks: $label ---"
    for c in app job postgres; do
        log_test "[$label] container $c running"
        if wait_for "$c" "docker inspect -f {{.State.Running}} $c 2>/dev/null | grep -q true" 30 10; then
            log_success "$c running"
        else
            log_fail "$c not running"
        fi
    done
    log_test "[$label] GET http://localhost/up returns 200"
    if wait_for "/up" "curl -sf http://localhost/up" 40 10; then
        log_success "/up returned 200"
    else
        log_fail "/up did not return 200"
    fi
    log_test "[$label] broadcast.service active"
    if vm_root "systemctl is-active --quiet broadcast.service"; then log_success "active"; else log_fail "not active"; fi
    log_test "[$label] each cron job scheduled exactly once"
    local crontab_text bad=""
    crontab_text=$(vm_root "crontab -l")
    for name in monitor trigger health recover update; do
        count=$(echo "$crontab_text" | grep -c "broadcast.sh $name ")
        [ "$count" = "1" ] || bad="$bad $name=$count"
    done
    if [ -z "$bad" ]; then log_success "monitor/trigger/health/recover/update once each"; else log_fail "cron counts wrong:$bad"; fi
    log_test "[$label] .image matches the CPU"
    local arch image
    arch=$(vm_root "dpkg --print-architecture")
    image=$(vm_root "grep DOCKER_IMAGE /opt/broadcast/.image")
    if { [ "$arch" = "arm64" ] && echo "$image" | grep -q broadcast-arm; } || \
       { [ "$arch" = "amd64" ] && ! echo "$image" | grep -q broadcast-arm; }; then
        log_success "$arch -> $image"
    else
        log_fail "$arch got $image"
    fi
}

# Fingerprint of everything the bootstrap could touch on an installed server.
# The database files and logs change on their own while the stack runs, so
# they are left out; secrets, config, scripts, cron, units and the install
# log are all in.
fingerprint() {
    vm_root "cd /opt/broadcast && {
        sha256sum app/.env db/.env .env .domain .license .image
        git rev-parse HEAD; git status --porcelain
        find . -path ./db/postgres-data -prune -o -path ./logs -prune -o -path ./.git -prune -o -path ./app/monitor -prune -o -type f -printf '%p %s %T@\n' | sort
        crontab -l
        sha256sum /etc/systemd/system/broadcast.service
        stat -c '%s %Y' /var/log/broadcast-install.log
        id broadcast
    } 2>&1 | sha256sum"
}

check_refusal() {
    local label="$1" cmd="$2" flag="$3" before after out rc
    log_test "[$label] re-run on the installed server exits 3 and changes nothing"
    before=$(fingerprint)
    out=$(vm_ssh "$flag" "$cmd" 2>&1); rc=$?
    after=$(fingerprint)
    echo "$out" | redact | sed 's/^/    | /' | tail -12
    if [ "$rc" = "3" ] && [ "$before" = "$after" ] && echo "$out" | grep -q "already installed"; then
        log_success "exit 3, fingerprint unchanged"
    else
        log_fail "rc=$rc, fingerprint $([ "$before" = "$after" ] && echo unchanged || echo CHANGED)"
    fi
}

cli_upgrade() {
    local label="$1" head_before head_after out rc
    head_before=$(vm_root "git -C /opt/broadcast rev-parse --short HEAD")
    log_test "[$label] broadcast.sh upgrade exits 0"
    out=$(vm_root "cd /opt/broadcast && ./broadcast.sh upgrade" 2>&1); rc=$?
    echo "$out" | redact | tail -15 | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "upgrade exited 0"; else log_fail "upgrade exited $rc"; fi
    head_after=$(vm_root "git -C /opt/broadcast rev-parse --short HEAD")
    log_info "scripts: $head_before -> $head_after"
    health_checks "$label"
    log_test "[$label] registry login still valid (pull as broadcast works)"
    if vm_root "su - broadcast -c 'cd /opt/broadcast && set -a && . ./.image && set +a && docker compose pull -q app'"; then
        log_success "authenticated pull OK"
    else
        log_fail "pull as broadcast failed"
    fi
}

trigger_upgrade() {
    local label="$1"
    log_test "[$label] the app container can write the upgrade trigger (dashboard button path)"
    if vm_root "docker exec app sh -c 'echo > /rails/triggers/upgrade.txt'"; then
        log_success "trigger file written from inside the container"
    else
        log_fail "container could not write the trigger file"; return
    fi
    log_test "[$label] the trigger cron consumes it and the upgrade completes"
    if wait_for "trigger consumed" "test ! -f /opt/broadcast/app/triggers/upgrade.txt" 30 10 && \
       wait_for "upgrade completed" "grep -q 'upgrade completed (fallback mode)' /opt/broadcast/logs/cron/trigger.log" 60 10; then
        log_success "trigger cron ran the upgrade"
    else
        log_fail "trigger upgrade did not complete"
        vm_root "tail -30 /opt/broadcast/logs/cron/trigger.log" | redact | sed 's/^/    | /'
    fi
    health_checks "$label"
}

# --- Scenarios ---------------------------------------------------------------

scenario_noninteractive() {
    check_raw_url_matches_local

    # (d) no TTY, no env vars
    local out rc start elapsed
    log_test "(d) no terminal and no env vars: fails fast with exit 2, writes nothing"
    start=$(date +%s)
    out=$(vm_ssh -T "curl -fsSL $RAW_URL | sudo bash" 2>&1); rc=$?
    elapsed=$(( $(date +%s) - start ))
    echo "$out" | sed 's/^/    | /'
    if [ "$rc" = "2" ] && [ "$elapsed" -lt 60 ] && vm_root "test ! -e /opt/broadcast && test ! -e /var/log/broadcast-install.log"; then
        log_success "exit 2 in ${elapsed}s; /opt/broadcast and the log do not exist"
    else
        log_fail "rc=$rc after ${elapsed}s, or something was written"
    fi
    log_test "(d) only BROADCAST_DOMAIN given: still exit 2"
    out=$(vm_ssh -T "curl -fsSL $RAW_URL | sudo BROADCAST_DOMAIN=$DOMAIN bash" 2>&1); rc=$?
    if [ "$rc" = "2" ] && vm_root "test ! -e /opt/broadcast"; then log_success "exit 2"; else log_fail "rc=$rc"; fi

    # (b) non-interactive install with env vars
    local boot_before
    boot_before=$(vm_root "cat /proc/sys/kernel/random/boot_id")
    log_test "(b) ssh -T 'curl | sudo BROADCAST_DOMAIN=.. BROADCAST_LICENSE=.. bash' exits 0"
    start=$(date +%s)
    # The scheduled reboot creates /run/nologin, which refuses new non-root
    # logins until the reboot, so the reboot check runs in this same session.
    out=$(vm_ssh -T "curl -fsSL $RAW_URL | sudo BROADCAST_REF=$REF BROADCAST_DOMAIN=$DOMAIN BROADCAST_LICENSE=$KEY bash; rc=\$?; test -f /run/systemd/shutdown/scheduled && echo E2E_REBOOT_SCHEDULED; exit \$rc" 2>&1); rc=$?
    elapsed=$(( $(date +%s) - start ))
    echo "$out" > "$VAGRANT_DIR/install-output.log"
    echo "$out" | redact | tail -25 | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "exit 0 after ${elapsed}s"; else log_fail "exit $rc after ${elapsed}s"; fi

    log_test "(b) the reboot is scheduled, not immediate"
    if echo "$out" | grep -q E2E_REBOOT_SCHEDULED; then
        log_success "reboot scheduled ($(echo "$out" | grep -o 'Reboot scheduled for [^,]*'))"
    else
        log_fail "no scheduled reboot found"
    fi

    log_test "(b) the server reboots and the stack comes back"
    local i boot_after=""
    for ((i = 0; i < 60; i++)); do
        sleep 10
        boot_after=$(vm_root "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
        [ -n "$boot_after" ] && [ "$boot_after" != "$boot_before" ] && break
    done
    if [ -n "$boot_after" ] && [ "$boot_after" != "$boot_before" ]; then
        log_success "rebooted (boot id changed)"
    else
        log_fail "no reboot observed within 10 minutes"
    fi
    health_checks "after install + reboot"
    log_test "(b) install log exists, mode 600, holds the run"
    if vm_root "test \"\$(stat -c %a /var/log/broadcast-install.log)\" = 600 && grep -q 'Running the Broadcast installer' /var/log/broadcast-install.log"; then
        log_success "/var/log/broadcast-install.log ok"
    else
        log_fail "install log missing or wrong mode"
    fi

    # (c) re-run on the installed server
    check_refusal "(c) env vars, no TTY" \
        "curl -fsSL $RAW_URL | sudo BROADCAST_DOMAIN=$DOMAIN BROADCAST_LICENSE=$KEY bash" -T
    check_refusal "(c) interactive TTY" "curl -fsSL $RAW_URL | sudo bash" -tt

    # Upgrades on the freshly installed server
    cli_upgrade "CLI upgrade"
    trigger_upgrade "dashboard-trigger upgrade"
}

scenario_interactive() {
    check_raw_url_matches_local
    command -v expect >/dev/null || { log_fail "expect is not installed"; exit 1; }

    log_test "(a) interactive install over a real TTY: ssh -t 'curl | sudo bash -s -- --no-reboot'"
    local transcript="$VAGRANT_DIR/interactive-transcript.log" rc
    E2E_SSH_CFG="$SSH_CFG" E2E_URL="$RAW_URL" E2E_REF="$REF" E2E_DOMAIN="$DOMAIN" E2E_KEY="$KEY" E2E_LOG="$transcript" \
    expect <<'EXPECT'
set timeout 2400
log_file -noappend $env(E2E_LOG)
spawn ssh -F $env(E2E_SSH_CFG) -tt default "curl -fsSL $env(E2E_URL) | sudo BROADCAST_REF=$env(E2E_REF) bash -s -- --no-reboot"
expect {
  "enter the domain name" { send "not a domain\r" }
  timeout { exit 90 }
}
expect {
  "not a valid domain" {}
  timeout { exit 91 }
}
expect "enter the domain name"
send "$env(E2E_DOMAIN)\r"
expect {
  "enter your license key" { send "WRONG-0000-KEY\r" }
  timeout { exit 92 }
}
expect {
  "did not accept this key" {}
  timeout { exit 96 }
}
expect {
  "enter your license key" { send "$env(E2E_KEY)\r" }
  timeout { exit 97 }
}
expect {
  "Install Broadcast for" { send "y\r" }
  "did not accept this key" { exit 93 }
  timeout { exit 98 }
}
expect {
  "Press Enter to continue" { send "\r" }
  timeout { exit 94 }
}
expect {
  "Reboot skipped" {}
  timeout { exit 95 }
}
expect eof
set status [wait]
exit [lindex $status 3]
EXPECT
    rc=$?
    redact < "$transcript" | tr -d '\r' | grep -v '^\s*$' | tail -30 | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "interactive install exited 0"; else log_fail "interactive install failed (expect rc $rc)"; fi

    log_test "(a) the invalid domain and the wrong key were both asked again"
    if grep -q "not a valid domain" "$transcript" && grep -q "did not accept this key" "$transcript" && vm_root "grep -qx $DOMAIN /opt/broadcast/.domain"; then
        log_success ".domain = $DOMAIN after one rejected domain and one rejected key"
    else
        log_fail "domain prompt did not behave"
    fi
    log_test "(a) --no-reboot: no reboot scheduled"
    if vm_root "test ! -f /run/systemd/shutdown/scheduled"; then log_success "none scheduled"; else log_fail "a reboot was scheduled"; fi
    health_checks "after interactive install"
    check_refusal "(c) interactive re-run" "curl -fsSL $RAW_URL | sudo bash" -tt
}

scenario_legacy_upgrade() {
    log_info "Installing the OLD way from main (the documented clone + broadcast.sh install)"
    local out rc
    out=$(vm_root "set -e
        git clone -q https://github.com/${REPO_SLUG}.git /opt/broadcast
        cd /opt/broadcast
        echo $DOMAIN > .domain
        echo $KEY > .license
        ./broadcast.sh validate_license >/dev/null
        sed -i 's/sudo reboot/echo LEGACY_SKIP_REBOOT/' scripts/install.sh
        ./broadcast.sh install
        git checkout -- scripts/install.sh" 2>&1); rc=$?
    echo "$out" | redact | tail -8 | sed 's/^/    | /'
    log_test "legacy install from main exits 0"
    if [ "$rc" = "0" ]; then log_success "installed from $(vm_root 'git -C /opt/broadcast rev-parse --short HEAD')"; else log_fail "legacy install failed ($rc)"; exit 1; fi
    health_checks "legacy install (main)"

    log_info "Pointing the checkout at origin/$REF without moving it (what the merge does)"
    vm_root "cd /opt/broadcast && git fetch -q origin $REF && git checkout -q -b $REF && git branch -q -u origin/$REF"

    cli_upgrade "legacy -> $REF upgrade"
    log_test "the upgrade's git pull advanced the scripts to the branch"
    if vm_root "cd /opt/broadcast && test \"\$(git rev-parse HEAD)\" = \"\$(git rev-parse origin/$REF)\" && test -f install.sh"; then
        log_success "scripts at origin/$REF"
    else
        log_fail "scripts not at origin/$REF"
    fi
    log_test "fix reports nothing to repair after the upgrade"
    out=$(vm_root "cd /opt/broadcast && ./broadcast.sh fix" 2>&1); rc=$?
    echo "$out" | grep -E "FAIL|fixed|Summary|summary" | head -10 | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "fix exited 0"; else log_fail "fix exited $rc"; fi
    trigger_upgrade "legacy dashboard-trigger upgrade"

    check_raw_url_matches_local
    check_refusal "one-liner on a legacy-installed server" \
        "curl -fsSL $RAW_URL | sudo BROADCAST_DOMAIN=$DOMAIN BROADCAST_LICENSE=$KEY bash" -T
}

trap cleanup EXIT
setup_vm
case "$SCENARIO" in
    noninteractive) scenario_noninteractive ;;
    interactive) scenario_interactive ;;
    legacy-upgrade) scenario_legacy_upgrade ;;
esac

echo
echo "=========================================="
echo " Ubuntu ${UBUNTU_VERSION} / ${SCENARIO}: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
echo "=========================================="
[ "$TESTS_FAILED" -eq 0 ]
