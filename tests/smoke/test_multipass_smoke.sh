#!/bin/bash

# Smoke Test for Broadcast Installation
#
# Spins up disposable Ubuntu VMs (24.04 and 26.04 by default), runs the
# real installer on each, and verifies the system boots successfully.
#
# By default the VM clones the canonical repo from
# https://github.com/send-broadcast/broadcast-script.git, matching what
# real end users do. Use --local to test the current working tree
# (uncommitted changes included).
#
# Usage:
#   ./tests/smoke/test_multipass_smoke.sh                 # Basic smoke test (both versions)
#   ./tests/smoke/test_multipass_smoke.sh --ubuntu 24.04  # Test only 24.04
#   ./tests/smoke/test_multipass_smoke.sh --ubuntu 26.04  # Test only 26.04
#   ./tests/smoke/test_multipass_smoke.sh --local         # Test local working tree instead of cloning remote
#   ./tests/smoke/test_multipass_smoke.sh --no-cleanup    # Keep VM for debugging
#   ./tests/smoke/test_multipass_smoke.sh --test-reboot   # Verify reboot recovery
#   ./tests/smoke/test_multipass_smoke.sh --verbose       # Show all command output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Canonical repo URL — the test clones this by default so it exercises
# what real end users actually install.
BROADCAST_REPO_URL="https://github.com/send-broadcast/broadcast-script.git"

# Ubuntu versions to exercise. Override with --ubuntu VERSION.
DEFAULT_UBUNTU_VERSIONS=("24.04" "26.04")
UBUNTU_VERSIONS=("${DEFAULT_UBUNTU_VERSIONS[@]}")

# Per-iteration state (set inside the version loop)
UBUNTU_VERSION=""
VAGRANT_DIR=""

# CLI flags
FLAG_NO_CLEANUP=false
FLAG_TEST_REBOOT=false
FLAG_TEST_UPGRADE=false
FLAG_TEST_REAL_UPGRADE=false
FLAG_TEST_UPGRADE_FAILSAFE=false
FLAG_VERBOSE=false
FLAG_LOCAL=false
FROM_REF=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters (aggregated across all Ubuntu versions)
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Per-version results — parallel arrays
VERSION_NAMES=()
VERSION_RUN=()
VERSION_PASSED=()
VERSION_FAILED=()

#######################
# Helper Functions
#######################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_test() {
    echo -e "\n${YELLOW}[TEST]${NC} $1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Run a command on the VM as root via vagrant ssh
vm_exec_root() {
    local cmd="$1"
    if [ "$FLAG_VERBOSE" = true ]; then
        cd "$VAGRANT_DIR" && vagrant ssh -c "sudo bash -c '$cmd'" 2>&1
    else
        cd "$VAGRANT_DIR" && vagrant ssh -c "sudo bash -c '$cmd'" 2>/dev/null
    fi
}

# Runs SQL against a database in the postgres container.
#
# The SQL is base64-encoded on the host because vm_exec_root wraps its command
# in single quotes (`sudo bash -c '<cmd>'`), so a single quote anywhere in the
# SQL ends that quoting and corrupts the statement. Every string literal needs
# one, so passing SQL inline silently produced `VALUES (Worker, ...)` — a bare
# identifier — and postgres rejected it. base64 is quote-free by construction.
vm_psql() {
    local database="$1" sql="$2" b64
    b64=$(printf '%s' "$sql" | base64 | tr -d '\n')
    vm_exec_root "echo $b64 | base64 -d > /tmp/smoke_psql.sql && docker exec -i postgres psql -U broadcast -d $database -t -A -v ON_ERROR_STOP=1 < /tmp/smoke_psql.sql"
}

#######################
# Credential Loading
#######################

load_credentials() {
    local env_file="$SCRIPT_DIR/.smoke-test.env"

    # Load from file if it exists (won't overwrite existing env vars)
    if [ -f "$env_file" ]; then
        log_info "Loading credentials from .smoke-test.env"
        set +u
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only set if not already in environment
            if [ -z "${!key:-}" ]; then
                export "$key=$value"
            fi
        done < "$env_file"
        set -u
    fi

    # Only the license key is required — registry creds are fetched from the API
    if [ -z "${BROADCAST_LICENSE_KEY:-}" ]; then
        echo -e "${RED}Error: BROADCAST_LICENSE_KEY is required.${NC}"
        echo ""
        echo "Either set it as an environment variable or create:"
        echo "  $env_file"
        echo ""
        echo "See .smoke-test.env.sample for the template."
        exit 1
    fi

    # If registry credentials weren't provided, fetch them via the license API
    if [ -z "${BROADCAST_REGISTRY_URL:-}" ] || [ -z "${BROADCAST_REGISTRY_LOGIN:-}" ] || [ -z "${BROADCAST_REGISTRY_PASSWORD:-}" ]; then
        log_info "Fetching registry credentials from license API..."
        fetch_registry_credentials
    fi
}

fetch_registry_credentials() {
    local domain="smoke-test.local"
    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${BROADCAST_LICENSE_KEY}\", \"domain\":\"${domain}\"}" \
        https://sendbroadcast.net/license/check)

    if [ "$http_code" != "200" ]; then
        local body
        body=$(cat "$tmpfile")
        rm -f "$tmpfile"
        echo -e "${RED}Error: License validation failed (HTTP $http_code)${NC}"
        [ -n "$body" ] && echo "  Response: $body"
        exit 1
    fi

    local response
    response=$(cat "$tmpfile")
    rm -f "$tmpfile"

    # Parse registry credentials from the response
    BROADCAST_REGISTRY_URL=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['registry_url'])" 2>/dev/null) || true
    BROADCAST_REGISTRY_LOGIN=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['registry_login'])" 2>/dev/null) || true
    BROADCAST_REGISTRY_PASSWORD=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['registry_password'])" 2>/dev/null) || true

    if [ -z "$BROADCAST_REGISTRY_URL" ] || [ -z "$BROADCAST_REGISTRY_LOGIN" ] || [ -z "$BROADCAST_REGISTRY_PASSWORD" ]; then
        echo -e "${RED}Error: Failed to parse registry credentials from license API response.${NC}"
        exit 1
    fi

    export BROADCAST_REGISTRY_URL BROADCAST_REGISTRY_LOGIN BROADCAST_REGISTRY_PASSWORD
    log_info "Registry credentials fetched successfully."
}

#######################
# Cleanup
#######################

cleanup() {
    # No active VM yet (e.g. credential check failed before the loop started)
    if [ -z "$VAGRANT_DIR" ] || [ ! -d "$VAGRANT_DIR" ]; then
        return
    fi

    if [ "$FLAG_NO_CLEANUP" = true ]; then
        log_warn "Skipping cleanup (--no-cleanup). VM is still running in $VAGRANT_DIR"
        log_warn "To clean up manually: cd $VAGRANT_DIR && vagrant destroy -f"
        return
    fi

    log_info "Cleaning up VM (Ubuntu ${UBUNTU_VERSION})..."
    cd "$VAGRANT_DIR" && vagrant destroy -f 2>/dev/null || true
    rm -rf "$VAGRANT_DIR"
}

#######################
# Phase 1: Setup VM
#######################

setup_vm() {
    log_info "=== Phase 1: Setup VM (Ubuntu ${UBUNTU_VERSION}) ==="

    # Check vagrant is installed
    if ! command -v vagrant &>/dev/null; then
        echo -e "${RED}Error: Vagrant is not installed.${NC}"
        echo "Install it with: brew install vagrant"
        exit 1
    fi

    # Create Vagrant working directory
    mkdir -p "$VAGRANT_DIR"

    # Detect host arch and pick QEMU machine flags. macOS uses Apple's HVF
    # accelerator on both Apple Silicon (aarch64) and Intel (x86_64).
    local host_arch qemu_arch qemu_machine qemu_ssh_port
    host_arch=$(uname -m)
    if [ "$host_arch" = "arm64" ] || [ "$host_arch" = "aarch64" ]; then
        qemu_arch="aarch64"
        qemu_machine="virt,accel=hvf,highmem=on"
    else
        qemu_arch="x86_64"
        qemu_machine="q35,accel=hvf"
    fi

    # Derive a per-version SSH port so back-to-back runs don't collide on the
    # vagrant-qemu default (50022). Major version offset: 24.04 -> 50024, 26.04 -> 50026.
    qemu_ssh_port=$((50000 + ${UBUNTU_VERSION%%.*}))

    # Generate Vagrantfile — provisioning differs depending on whether we are
    # cloning the canonical remote (default) or copying the local working tree.
    if [ "$FLAG_LOCAL" = true ]; then
        log_info "Repo source: local working tree ($PROJECT_ROOT)"
        cat > "$VAGRANT_DIR/Vagrantfile" <<'VAGRANTEOF'
Vagrant.configure("2") do |config|
  config.vm.box = "cloud-image/ubuntu-UBUNTU_VERSION_PLACEHOLDER"
  config.vm.hostname = "broadcast-smoke-test"

  config.vm.provider "qemu" do |qe|
    qe.arch = "QEMU_ARCH_PLACEHOLDER"
    qe.machine = "QEMU_MACHINE_PLACEHOLDER"
    qe.cpu = "host"
    qe.smp = "cpus=2,sockets=1,cores=2,threads=1"
    qe.memory = "2048M"
    qe.net_device = "virtio-net-pci"
    qe.ssh_port = "QEMU_SSH_PORT_PLACEHOLDER"
  end

  # Disable the default /vagrant share — QEMU does not support virtfs by default
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Share local working tree via rsync (cloud-image boxes have rsync preinstalled)
  config.vm.synced_folder "BROADCAST_REPO_PATH", "/tmp/broadcast-repo", type: "rsync"

  config.vm.provision "shell", inline: <<-SHELL
    rm -rf /opt/broadcast
    mkdir -p /opt/broadcast
    cp -a /tmp/broadcast-repo/. /opt/broadcast/
  SHELL
end
VAGRANTEOF
        sed -i '' "s|BROADCAST_REPO_PATH|${PROJECT_ROOT}|" "$VAGRANT_DIR/Vagrantfile"
    else
        log_info "Repo source: ${BROADCAST_REPO_URL}"
        cat > "$VAGRANT_DIR/Vagrantfile" <<'VAGRANTEOF'
Vagrant.configure("2") do |config|
  config.vm.box = "cloud-image/ubuntu-UBUNTU_VERSION_PLACEHOLDER"
  config.vm.hostname = "broadcast-smoke-test"

  config.vm.provider "qemu" do |qe|
    qe.arch = "QEMU_ARCH_PLACEHOLDER"
    qe.machine = "QEMU_MACHINE_PLACEHOLDER"
    qe.cpu = "host"
    qe.smp = "cpus=2,sockets=1,cores=2,threads=1"
    qe.memory = "2048M"
    qe.net_device = "virtio-net-pci"
    qe.ssh_port = "QEMU_SSH_PORT_PLACEHOLDER"
  end

  # Disable the default /vagrant share — QEMU does not support virtfs by default
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Clone the canonical repo — matches what real end users install
  config.vm.provision "shell", inline: <<-SHELL
    set -e
    if ! command -v git >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq git
    fi
    rm -rf /opt/broadcast
    git clone BROADCAST_REPO_URL_PLACEHOLDER /opt/broadcast
  SHELL
end
VAGRANTEOF
        sed -i '' "s|BROADCAST_REPO_URL_PLACEHOLDER|${BROADCAST_REPO_URL}|" "$VAGRANT_DIR/Vagrantfile"
    fi

    sed -i '' "s|UBUNTU_VERSION_PLACEHOLDER|${UBUNTU_VERSION}|" "$VAGRANT_DIR/Vagrantfile"
    sed -i '' "s|QEMU_ARCH_PLACEHOLDER|${qemu_arch}|" "$VAGRANT_DIR/Vagrantfile"
    sed -i '' "s|QEMU_MACHINE_PLACEHOLDER|${qemu_machine}|" "$VAGRANT_DIR/Vagrantfile"
    sed -i '' "s|QEMU_SSH_PORT_PLACEHOLDER|${qemu_ssh_port}|" "$VAGRANT_DIR/Vagrantfile"

    # Launch VM (QEMU provider)
    log_info "Launching Ubuntu ${UBUNTU_VERSION} VM (qemu/${qemu_arch}, ssh port ${qemu_ssh_port})..."
    cd "$VAGRANT_DIR" && vagrant up --provider=qemu

    log_info "VM is ready."
}

#######################
# Phase 2: Prepare Installation
#######################

prepare_installation() {
    log_info "=== Phase 2: Prepare Installation ==="

    # Optionally roll /opt/broadcast back to an older revision so a later
    # `broadcast.sh upgrade` performs a genuine old->new upgrade (its `git pull`
    # then advances the scripts). Remote mode only — local mode is not a clone.
    if [ -n "$FROM_REF" ] && [ "$FLAG_LOCAL" != true ]; then
        log_info "Resetting /opt/broadcast to base ref ${FROM_REF} for pre-upgrade install..."
        vm_exec_root "git -C /opt/broadcast reset --hard ${FROM_REF}"
    fi

    # Create required directories
    log_info "Creating required directories..."
    vm_exec_root "mkdir -p /opt/broadcast/{app,db,ssl,logs,logs/cron}"

    # Pre-create config files to bypass interactive prompts
    log_info "Pre-creating config files..."

    # .domain — bypasses check_installation_domain()
    vm_exec_root "echo smoke-test.local > /opt/broadcast/.domain"

    # .license — bypasses check_license()
    vm_exec_root "echo ${BROADCAST_LICENSE_KEY} > /opt/broadcast/.license"

    # .env — registry credentials for docker login (bypasses validate_license)
    vm_exec_root "printf \"BROADCAST_REGISTRY_URL=${BROADCAST_REGISTRY_URL}\nBROADCAST_REGISTRY_LOGIN=${BROADCAST_REGISTRY_LOGIN}\nBROADCAST_REGISTRY_PASSWORD=${BROADCAST_REGISTRY_PASSWORD}\n\" > /opt/broadcast/.env"

    # Patch install.sh: replace 'sudo reboot' with a no-op
    log_info "Patching install.sh to skip reboot..."
    vm_exec_root "sed -i s/sudo\\ reboot/echo\\ SMOKE_TEST_SKIP_REBOOT/ /opt/broadcast/scripts/install.sh"

    # Make broadcast.sh executable
    vm_exec_root "chmod +x /opt/broadcast/broadcast.sh"

    # Fix permissions on db/init-scripts so postgres container (uid 70) can read them
    vm_exec_root "chmod -R o+rX /opt/broadcast/db/init-scripts"

    # Local mode: the copied working tree has no usable git upstream, so
    # the `git pull` inside `broadcast.sh update` (and therefore inside
    # upgrade) would fail before reaching anything else. Rebuild the repo
    # fresh on the VM and give it a real local bare-clone upstream, so
    # `git pull` is a clean "Already up to date" no-op — this keeps the
    # upgrade-path phases runnable against uncommitted local code.
    # MUST run LAST, after every tracked-file mutation above (the
    # install.sh reboot patch!) — anything modified after this commit
    # leaves the tree dirty and update's dirty-tree protection refuses to
    # pull, silently degrading the upgrade-path phases.
    if [ "$FLAG_LOCAL" = true ]; then
        log_info "Setting up a local git upstream for the prepared tree..."
        vm_exec_root "command -v git >/dev/null || apt-get install -y -qq git"
        vm_exec_root "cd /opt/broadcast && rm -rf .git && git init -q -b smoke-local && git add -A && git -c user.email=smoke@test.local -c user.name=smoke commit -qm smoke-local-tree && git clone --bare -q . /opt/broadcast-upstream.git && git remote add origin /opt/broadcast-upstream.git && git config branch.smoke-local.remote origin && git config branch.smoke-local.merge refs/heads/smoke-local && git fetch -q origin"
    fi

    log_info "Installation prepared."
}

#######################
# Phase 3: Run Installer
#######################

run_installer() {
    log_info "=== Phase 3: Run Installer ==="
    log_info "Running installer..."

    local start_time=$(date +%s)

    if [ "$FLAG_VERBOSE" = true ]; then
        cd "$VAGRANT_DIR" && vagrant ssh -c "sudo bash -c 'cd /opt/broadcast && ./broadcast.sh install'" 2>&1 || {
            local exit_code=$?
            log_fail "Installer exited with code $exit_code"
            return $exit_code
        }
    else
        cd "$VAGRANT_DIR" && vagrant ssh -c "sudo bash -c 'cd /opt/broadcast && ./broadcast.sh install'" >/dev/null 2>&1 || {
            local exit_code=$?
            log_fail "Installer exited with code $exit_code"
            return $exit_code
        }
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Installation completed in ${elapsed}s."

    # Restore the reboot patch now that install has run. It mutates a TRACKED
    # file, and update's dirty-tree protection then refuses to pull for the
    # rest of the run — which made Phase 7c unpassable in the default
    # remote-clone mode (--local sidesteps it by rebuilding the repo after
    # patching). The patch has served its purpose by this point.
    if [ "$FLAG_LOCAL" != true ]; then
        vm_exec_root "cd /opt/broadcast && git checkout -- scripts/install.sh" || true
    fi
}

#######################
# Phase 4: Health Checks
#######################

# Retry a check command with polling
wait_for_check() {
    local description="$1"
    local check_cmd="$2"
    local max_retries="${3:-30}"
    local interval="${4:-10}"

    for i in $(seq 1 "$max_retries"); do
        if vm_exec_root "$check_cmd" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$FLAG_VERBOSE" = true ]; then
            echo -e "  ${BLUE}...${NC} retry $i/$max_retries for: $description"
        fi
        sleep "$interval"
    done
    return 1
}

run_health_checks() {
    local phase_label="${1:-Phase 4}"
    log_info "=== $phase_label: Health Checks ==="

    # Check: Docker containers are running
    log_test "Docker containers are running"
    local required_containers=("app" "job" "postgres")
    for container in "${required_containers[@]}"; do
        if wait_for_check "$container container" \
            "docker inspect -f {{.State.Running}} $container 2>/dev/null | grep -q true" 15 10; then
            log_success "Container '$container' is running"
        else
            log_fail "Container '$container' is not running"
        fi
    done

    # Check: PostgreSQL is ready
    log_test "PostgreSQL is accepting connections"
    if wait_for_check "pg_isready" \
        "docker exec postgres pg_isready -U broadcast" 15 10; then
        log_success "PostgreSQL is ready"
    else
        log_fail "PostgreSQL is not accepting connections"
    fi

    # Check: HTTP /up endpoint
    log_test "HTTP /up returns 200"
    if wait_for_check "HTTP /up" \
        "curl -sf http://localhost/up" 30 10; then
        log_success "GET /up returned 200"
    else
        log_fail "GET /up did not return 200"
    fi

    # Check: HTTP /ping endpoint
    log_test "HTTP /ping returns 200"
    if wait_for_check "HTTP /ping" \
        "curl -sf http://localhost/ping" 10 5; then
        log_success "GET /ping returned 200"
    else
        log_fail "GET /ping did not return 200"
    fi

    # Check: systemd service is active
    log_test "broadcast.service is active"
    if vm_exec_root "systemctl is-active broadcast.service" >/dev/null 2>&1; then
        log_success "broadcast.service is active"
    else
        log_fail "broadcast.service is not active"
    fi

    # Check: broadcast user exists
    log_test "broadcast user exists"
    if vm_exec_root "id broadcast" >/dev/null 2>&1; then
        log_success "broadcast user exists"
    else
        log_fail "broadcast user does not exist"
    fi

    # Check: config files exist
    log_test "Config files exist"
    if vm_exec_root "test -f /opt/broadcast/app/.env"; then
        log_success "app/.env exists"
    else
        log_fail "app/.env does not exist"
    fi

    if vm_exec_root "test -f /opt/broadcast/db/.env"; then
        log_success "db/.env exists"
    else
        log_fail "db/.env does not exist"
    fi

    # Check: crontab entries
    log_test "Cron jobs are configured"
    local crontab_content
    crontab_content=$(vm_exec_root "crontab -l 2>/dev/null" || true)
    if echo "$crontab_content" | grep -q "monitor"; then
        log_success "Monitor cron job exists"
    else
        log_fail "Monitor cron job not found"
    fi

    if echo "$crontab_content" | grep -q "trigger"; then
        log_success "Trigger cron job exists"
    else
        log_fail "Trigger cron job not found"
    fi

    # Check: app redirects to onboarding on fresh install
    log_test "Fresh install shows onboarding screen"
    local redirect_location
    redirect_location=$(vm_exec_root "docker exec app curl -sf -o /dev/null -w \"%{redirect_url}\" http://localhost:3000/" 2>/dev/null || true)
    if echo "$redirect_location" | grep -q "onboarding"; then
        log_success "App redirects to onboarding: $redirect_location"
    else
        log_fail "App did not redirect to onboarding (got: $redirect_location)"
    fi
}

#######################
# Install state checks — verifies the security/system half of install.sh
# that the service health checks don't touch: firewall, fail2ban, swap,
# timezone, unattended upgrades, docker group, sudoers, logrotate, systemd
# units, and architecture-correct image selection.
#######################

run_install_state_checks() {
    log_info "=== Install State Checks (security & system configuration) ==="

    # UFW: enabled, with exactly the promised ports open
    log_test "UFW is enabled with ports 22/80/443 allowed"
    local ufw_status
    ufw_status=$(vm_exec_root "ufw status" 2>/dev/null || true)
    if echo "$ufw_status" | grep -q "Status: active"; then
        log_success "UFW is active"
    else
        log_fail "UFW is not active"
    fi
    local port
    for port in 22 80 443; do
        if echo "$ufw_status" | grep -E "^${port}/tcp" | grep -q "ALLOW"; then
            log_success "UFW allows ${port}/tcp"
        else
            log_fail "UFW does not allow ${port}/tcp"
        fi
    done

    # fail2ban: installed from the pinned upstream deb and running
    log_test "fail2ban is enabled and active"
    if vm_exec_root "systemctl is-enabled --quiet fail2ban && systemctl is-active --quiet fail2ban"; then
        log_success "fail2ban is enabled and active"
    else
        log_fail "fail2ban is not enabled/active"
    fi

    # Swap: active and persistent across reboots
    log_test "Swap file is active and in fstab"
    if vm_exec_root "swapon --show | grep -q /swapfile"; then
        log_success "/swapfile is active"
    else
        log_fail "/swapfile is not active"
    fi
    if vm_exec_root "grep -q /swapfile /etc/fstab"; then
        log_success "/swapfile is in fstab (survives reboot)"
    else
        log_fail "/swapfile missing from fstab"
    fi

    # Timezone and time sync
    log_test "Timezone is UTC with chrony installed"
    if vm_exec_root "timedatectl show -p Timezone --value | grep -qx Etc/UTC || timedatectl show -p Timezone --value | grep -qx UTC"; then
        log_success "timezone is UTC"
    else
        log_fail "timezone is not UTC"
    fi
    if vm_exec_root "systemctl is-active --quiet chrony || systemctl is-active --quiet chronyd"; then
        log_success "chrony is running"
    else
        log_fail "chrony is not running"
    fi

    # Unattended upgrades configured, without automatic reboots.
    # NOTE: vm_exec_root nests the command inside vagrant ssh -c + sudo bash
    # -c '...', so patterns here must avoid quotes entirely — quoted patterns
    # get mangled across the shell layers and fail spuriously.
    log_test "Unattended upgrades are configured"
    if vm_exec_root "grep -q APT::Periodic::Unattended-Upgrade /etc/apt/apt.conf.d/20auto-upgrades"; then
        log_success "unattended upgrades enabled"
    else
        log_fail "unattended upgrades not configured"
    fi
    if vm_exec_root "grep -q Automatic-Reboot.*false /etc/apt/apt.conf.d/20auto-upgrades"; then
        log_success "automatic reboot disabled"
    else
        log_fail "automatic reboot setting missing"
    fi

    # broadcast user: docker group membership and passwordless sudo
    log_test "broadcast user has docker group and sudoers entry"
    if vm_exec_root "id -nG broadcast | grep -qw docker"; then
        log_success "broadcast user is in the docker group"
    else
        log_fail "broadcast user is not in the docker group"
    fi
    if vm_exec_root "test -f /etc/sudoers.d/broadcast && grep -q NOPASSWD /etc/sudoers.d/broadcast"; then
        log_success "sudoers entry present"
    else
        log_fail "sudoers entry missing"
    fi

    # Ownership: the paths install.sh chowns must belong to broadcast. Scoped
    # to key paths rather than the whole tree — runtime files under logs/
    # (cron logs, the watcher lock) are legitimately root-owned because
    # root's cron jobs and the watcher service create them.
    log_test "Key /opt/broadcast paths are owned by broadcast"
    local owned_path ownership_ok=true
    for owned_path in /opt/broadcast /opt/broadcast/app /opt/broadcast/app/.env /opt/broadcast/db/backups /opt/broadcast/broadcast.sh; do
        if ! vm_exec_root "stat -c %U $owned_path | grep -qx broadcast"; then
            ownership_ok=false
            log_fail "$owned_path is not owned by broadcast"
        fi
    done
    if [ "$ownership_ok" = true ]; then
        log_success "key paths owned by broadcast"
    fi

    # Update cron entry (health checks already cover monitor and trigger)
    log_test "Daily update cron job exists"
    if vm_exec_root "crontab -l 2>/dev/null | grep broadcast.sh | grep -q update"; then
        log_success "update cron job exists"
    else
        log_fail "update cron job not found"
    fi

    # Logrotate configuration for Broadcast logs
    log_test "Logrotate is configured for Broadcast logs"
    if vm_exec_root "test -f /etc/logrotate.d/broadcast && grep -q /opt/broadcast/logs /etc/logrotate.d/broadcast"; then
        log_success "logrotate config present"
    else
        log_fail "logrotate config missing"
    fi

    # systemd units: broadcast.service enabled for boot, watcher + cleanup
    # units installed, watcher enabled and running
    log_test "systemd units are installed and enabled"
    if vm_exec_root "systemctl is-enabled --quiet broadcast.service"; then
        log_success "broadcast.service is enabled (starts on boot)"
    else
        log_fail "broadcast.service is not enabled"
    fi
    if vm_exec_root "test -f /etc/systemd/system/broadcast-post-upgrade-cleanup.service"; then
        log_success "post-upgrade cleanup unit installed"
    else
        log_fail "post-upgrade cleanup unit missing"
    fi
    if vm_exec_root "systemctl is-enabled --quiet broadcast-logs-watcher && systemctl is-active --quiet broadcast-logs-watcher"; then
        log_success "logs watcher is enabled and active"
    else
        log_fail "logs watcher is not enabled/active"
    fi

    # .image matches the VM architecture and is readable by the broadcast user
    log_test ".image matches the VM architecture"
    local vm_arch image_line
    vm_arch=$(vm_exec_root "dpkg --print-architecture" 2>/dev/null | tr -d '[:space:]')
    image_line=$(vm_exec_root "grep '^DOCKER_IMAGE=' /opt/broadcast/.image" 2>/dev/null || true)
    if [ "$vm_arch" = "arm64" ]; then
        if echo "$image_line" | grep -q "broadcast-arm"; then
            log_success ".image uses the arm image on arm64"
        else
            log_fail ".image does not use the arm image on arm64 (got: $image_line)"
        fi
    else
        if echo "$image_line" | grep -q "broadcast:" && ! echo "$image_line" | grep -q "broadcast-arm"; then
            log_success ".image uses the amd64 image on $vm_arch"
        else
            log_fail ".image is wrong for $vm_arch (got: $image_line)"
        fi
    fi

    # inotify-tools needed by the logs watcher
    log_test "inotify-tools is installed"
    if vm_exec_root "command -v inotifywait" >/dev/null 2>&1; then
        log_success "inotifywait is available"
    else
        log_fail "inotifywait is missing"
    fi
}

#######################
# Backup/restore cycle — the only place restore_apply's real systemctl/
# docker phase runs end to end (unit tests stub it; the Docker integration
# test re-implements the pg mechanics). This is the regression guard for
# drift like the broadcast-postgres container-name bug.
#######################

test_backup_restore_cycle() {
    log_info "=== Backup/Restore Cycle ==="

    log_test "backup_database produces a tarball with checksum sidecar"
    vm_exec_root "cd /opt/broadcast && ./broadcast.sh backup_database" >/dev/null 2>&1 || true
    local tarball
    tarball=$(vm_exec_root "ls -t /opt/broadcast/db/backups/broadcast-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null | tr -d '\r' | tail -1)
    if [ -n "$tarball" ]; then
        log_success "backup created: $(basename "$tarball")"
    else
        log_fail "no backup tarball produced"
        return
    fi
    if vm_exec_root "test -f ${tarball}.sha256" >/dev/null 2>&1; then
        log_success "checksum sidecar present"
    else
        log_fail "checksum sidecar missing"
    fi

    log_test "restore --yes replaces the database and the system comes back"

    # Marker row inserted AFTER the backup was taken; a genuine restore drops
    # and recreates schema_migrations from the dump, so the marker must vanish.
    # (::text casts avoid quote characters, which vm_exec_root cannot carry.)
    vm_exec_root "docker exec postgres psql -U broadcast -d broadcast_primary_production -t -c \"INSERT INTO schema_migrations (version) VALUES (12345678901234::text)\"" >/dev/null 2>&1

    if vm_exec_root "cd /opt/broadcast && BROADCAST_ASSUME_YES=1 ./broadcast.sh restore $(basename "$tarball") > /tmp/restore-cycle.log 2>&1"; then
        log_success "restore exited 0"
    else
        log_fail "restore exited non-zero — output follows"
        vm_exec_root "tail -40 /tmp/restore-cycle.log" 2>/dev/null | sed 's/^/    | /'
        return
    fi

    local marker_count
    marker_count=$(vm_exec_root "docker exec postgres psql -U broadcast -d broadcast_primary_production -t -c \"SELECT COUNT(*) FROM schema_migrations WHERE version = 12345678901234::text\"" 2>/dev/null | tr -dc '0-9')
    if [ "$marker_count" = "0" ]; then
        log_success "post-backup marker gone — data genuinely replaced from the dump"
    else
        log_fail "post-backup marker survived (count=${marker_count:-unreadable}) — restore did not replace data"
    fi

    # The restore restarts the whole stack; give it time to come back
    local recovered=false
    for _ in $(seq 1 24); do
        if vm_exec_root "systemctl is-active broadcast.service" >/dev/null 2>&1 &&
           vm_exec_root "docker exec app curl -sf -o /dev/null http://localhost:3000/up" >/dev/null 2>&1; then
            recovered=true
            break
        fi
        sleep 5
    done
    if [ "$recovered" = true ]; then
        log_success "service active and HTTP /up healthy after restore"
    else
        log_fail "system did not recover within 120s of restore"
    fi
}

#######################
# Inspection: Display key artifacts
#######################

display_inspection() {
    log_info "=== Inspection: System Artifacts ==="
    echo ""

    echo -e "${YELLOW}--- Broadcast Version ---${NC}"
    vm_exec_root "cat /opt/broadcast/.current_version 2>/dev/null || echo 'unknown'" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- Docker Image (.image) ---${NC}"
    vm_exec_root "cat /opt/broadcast/.image" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- Docker Containers ---${NC}"
    vm_exec_root "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- /opt/broadcast/.env (registry credentials) ---${NC}"
    vm_exec_root "cat /opt/broadcast/.env" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- /opt/broadcast/app/.env (Rails environment) ---${NC}"
    vm_exec_root "cat /opt/broadcast/app/.env" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- /opt/broadcast/db/.env (Postgres environment) ---${NC}"
    vm_exec_root "cat /opt/broadcast/db/.env" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- Crontab ---${NC}"
    vm_exec_root "crontab -l 2>/dev/null" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- systemctl status broadcast.service ---${NC}"
    vm_exec_root "systemctl status broadcast.service --no-pager -l 2>/dev/null | head -15" 2>/dev/null
    echo ""

    echo -e "${YELLOW}--- Onboarding Redirect ---${NC}"
    vm_exec_root "docker exec app curl -sf -o /dev/null -w \"HTTP %{http_code} -> %{redirect_url}\" http://localhost:3000/ && echo" 2>/dev/null
    echo ""
}

#######################
# Phase 4c: Log persistence across restart (journald)
#######################

# Postmortem friction 9a: `broadcast.sh restart` goes through the systemd
# unit's ExecStop=`docker compose down`, which removes the containers and —
# under the old json-file driver — destroyed their logs, erasing incident
# evidence. With the journald driver the history must survive. We write a
# marker into the app container's stdout (via /proc/1/fd/1 — docker exec
# output itself never reaches the container log), restart the stack, and
# require the marker in journald while the FRESH container's `docker logs`
# does not have it (proving survival came from the journal, not a
# surviving container).
test_log_persistence_across_restart() {
    log_info "=== Phase 4c: Log persistence across restart ==="

    local marker="SMOKE-LOG-PERSIST-$(date +%s)"

    log_test "marker lands in journald before the restart"
    vm_exec_root "docker exec app sh -c \"echo $marker > /proc/1/fd/1\""
    if wait_for_check "marker in journal" \
        "journalctl CONTAINER_NAME=app --no-pager | grep -q $marker" 6 5; then
        log_success "marker visible in journald"
    else
        log_fail "marker never reached journald (is the journald logging driver active?)"
    fi

    log_info "Restarting the stack (compose down destroys the containers)..."
    vm_exec_root "cd /opt/broadcast && ./broadcast.sh restart"

    log_test "stack is healthy again after restart"
    if wait_for_check "app container running" \
        "docker inspect -f {{.State.Status}} app | grep -q running" 24 5; then
        log_success "app container running after restart"
    else
        log_fail "app container did not come back after restart"
    fi

    log_test "pre-restart log line survives the compose down"
    if vm_exec_root "journalctl CONTAINER_NAME=app --no-pager | grep -q $marker"; then
        log_success "journald kept the pre-restart history"
    else
        log_fail "pre-restart logs were destroyed by the restart"
    fi

    log_test "fresh container has no pre-restart history in docker logs"
    if vm_exec_root "docker logs app 2>&1 | grep -q $marker"; then
        log_fail "docker logs still shows the marker — the container survived, test proves nothing"
    else
        log_success "marker absent from the fresh container (survival came from journald)"
    fi
}

#######################
# Phase 5: Reboot Recovery
#######################

test_reboot_recovery() {
    log_info "=== Phase 5: Reboot Recovery ==="

    log_info "Restarting VM..."
    cd "$VAGRANT_DIR" && vagrant reload

    log_info "VM is back. Re-running health checks..."
    run_health_checks "Phase 5 (post-reboot)"
}

# Phase 5b: the 2026-08-03 incident, reproduced for real — reboot while the
# image registry is unreachable. Before the fix, `pull_policy: always` made
# compose exit 18 at boot, systemd burned its start rate limit in seconds,
# and broadcast.service sat in 'failed' until a human intervened. With the
# fix, boot must come up from cached images and never rate-limit-lock.
# The registry is blackholed via /etc/hosts (both hostnames resolve to
# 127.0.0.1 -> connection refused, exactly what the incident logged).
test_boot_registry_outage() {
    log_info "=== Phase 5b: Reboot with the registry unreachable ==="

    local registry_host="gitea.hostedapp.org"

    log_info "Blackholing ${registry_host} in /etc/hosts..."
    vm_exec_root "cp /etc/hosts /etc/hosts.smoke-backup && printf \"127.0.0.1 ${registry_host}\n\" >> /etc/hosts"

    log_info "Rebooting VM with the registry unreachable..."
    cd "$VAGRANT_DIR" && vagrant reload

    log_test "broadcast.service becomes active from cached images (no registry)"
    if wait_for_check "broadcast.service active" \
        "systemctl is-active --quiet broadcast.service" 24 5; then
        log_success "service came up without registry access"
    else
        log_fail "service did not come up while the registry was unreachable"
    fi

    log_test "no systemd start-rate-limit lockout during boot"
    # Quote-free remote grep pattern: vm_exec_root's nested quoting mangles
    # single-quoted arguments (see the 2026-08-01 smoke-test note).
    if vm_exec_root "journalctl -b -u broadcast --no-pager | grep -q too.quickly"; then
        log_fail "journal shows the rate-limit lockout (Start request repeated too quickly)"
    else
        log_success "no rate-limit lockout in the boot journal"
    fi

    log_test "app container is running despite the unreachable registry"
    if wait_for_check "app container running" \
        "docker inspect -f {{.State.Status}} app | grep -q running" 12 5; then
        log_success "app container running from the local image cache"
    else
        log_fail "app container not running"
    fi

    log_info "Restoring /etc/hosts..."
    vm_exec_root "mv /etc/hosts.smoke-backup /etc/hosts"

    # The stack must still be fully healthy once the registry is back.
    run_health_checks "Phase 5b (post-outage)"
}

#######################
# Phase 6: Upgrade-path — watcher restart + log streaming survival
#######################

# Exercises the two host-side behaviours that plain install/health checks do not:
#   1. `systemctl restart broadcast-logs-watcher` (what upgrade.sh now runs so a
#      long-running watcher picks up updated scripts) leaves the watcher healthy.
#   2. Log streaming survives container recreation — the actual bug fix. We start
#      streaming via the trigger file, recreate BOTH app and job (so no surviving
#      `docker logs -f` can mask a broken reattach), and assert application.log
#      keeps growing. With the old code the streamer's `wait` returned and the
#      file froze; the supervised reattach loop keeps it live.
#
# This is the fast behavioural check (no real upgrade). For the genuine
# `broadcast.sh upgrade` end-to-end path, see test_real_upgrade / --test-upgrade
# combined with --from-ref.
test_upgrade_and_streaming() {
    log_info "=== Phase 6: Upgrade-path (watcher restart + streaming survival) ==="

    # 1. Watcher restart (the upgrade.sh delivery step) keeps it active + new PID.
    log_test "broadcast-logs-watcher restarts cleanly and stays active"
    local pid_before pid_after
    pid_before=$(vm_exec_root "systemctl show -p MainPID --value broadcast-logs-watcher" | tr -d "[:space:]")
    vm_exec_root "systemctl restart broadcast-logs-watcher || true"
    sleep 3
    pid_after=$(vm_exec_root "systemctl show -p MainPID --value broadcast-logs-watcher" | tr -d "[:space:]")
    if vm_exec_root "systemctl is-active --quiet broadcast-logs-watcher" && [ "$pid_before" != "$pid_after" ]; then
        log_success "watcher restarted (PID ${pid_before} -> ${pid_after}) and is active"
    else
        log_fail "watcher did not restart cleanly (PID ${pid_before} -> ${pid_after})"
    fi

    _test_streaming_lifecycle
}

# Phase 7: genuine end-to-end `broadcast.sh upgrade`. The VM was installed at an
# older ref (--from-ref), so the real upgrade's `git pull` advances the scripts,
# exercising the production path: update -> _upgrade_continue -> watcher restart
# -> container restart. Then we re-verify streaming works on the upgraded host.
test_real_upgrade() {
    log_info "=== Phase 7: Genuine broadcast.sh upgrade ==="

    local head_before head_after
    head_before=$(vm_exec_root "git -C /opt/broadcast rev-parse --short HEAD" | tr -d '[:space:]')
    log_info "Installed (pre-upgrade) script revision: ${head_before}"

    log_test "old watcher is running before upgrade"
    if vm_exec_root "systemctl is-active --quiet broadcast-logs-watcher"; then
        log_success "watcher active pre-upgrade"
    else
        log_fail "watcher not active pre-upgrade"
    fi

    log_test "broadcast.sh upgrade completes (exit 0)"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh upgrade"; then
        log_success "broadcast.sh upgrade exited 0"
    else
        log_fail "broadcast.sh upgrade failed"
    fi

    head_after=$(vm_exec_root "git -C /opt/broadcast rev-parse --short HEAD" | tr -d '[:space:]')
    log_test "scripts advanced via the upgrade's git pull"
    if [ -n "$head_after" ] && [ "$head_before" != "$head_after" ]; then
        log_success "scripts upgraded (${head_before} -> ${head_after})"
    else
        log_fail "scripts did not advance (${head_before} -> ${head_after})"
    fi

    log_test "watcher is active after upgrade"
    if wait_for_check "watcher active" "systemctl is-active --quiet broadcast-logs-watcher" 12 5; then
        log_success "watcher active post-upgrade"
    else
        log_fail "watcher not active post-upgrade"
    fi

    # Containers must be healthy again after the upgrade restarted the stack.
    run_health_checks "Phase 7 (post-upgrade)"

    # The fix itself must work end to end on the freshly-upgraded host.
    _test_streaming_lifecycle
}

# Phase 7b: the 2026-08-04 customer report, reproduced for real — an upgrade
# that fails mid-window. broadcast.sh runs under `set -e`, and everything
# between `systemctl stop broadcast` and the final `systemctl start` in
# _upgrade_continue is a window where any failure aborts the script with the
# service still stopped: the site stays DOWN until a human runs restart,
# which is exactly what the customer reported. The registry is blackholed
# (same /etc/hosts technique as Phase 5b) so the upgrade's explicit
# `docker compose pull` fails inside that window.
#
# The assertions encode the REQUIRED behaviour — a failed upgrade must
# report failure AND leave the previously-installed version serving — so
# this phase runs RED against current code until the fail-safe ships.
# A plain (latest-tag) upgrade is used deliberately: the old image is still
# in the local cache under the same tag, so a fail-safe `systemctl start`
# can succeed without registry access (pull_policy: missing). Rolling back
# .image for failed VERSION-SPECIFIC upgrades is a further requirement
# tracked in SPRINT.md item 3, not asserted here.
test_upgrade_failure_failsafe() {
    log_info "=== Phase 7b: Upgrade failure mid-window (fail-safe) ==="

    local registry_host="gitea.hostedapp.org"

    log_test "stack is healthy before the failed-upgrade attempt"
    if vm_exec_root "systemctl is-active --quiet broadcast.service"; then
        log_success "broadcast.service active pre-upgrade"
    else
        log_fail "broadcast.service not active before the phase even starts"
    fi

    log_info "Blackholing ${registry_host} in /etc/hosts..."
    vm_exec_root "cp /etc/hosts /etc/hosts.smoke-backup && printf \"127.0.0.1 ${registry_host}\n\" >> /etc/hosts"

    log_test "broadcast.sh upgrade reports failure when the image pull fails"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh upgrade"; then
        log_fail "upgrade exited 0 despite the registry being unreachable"
    else
        log_success "upgrade exited nonzero"
    fi

    log_test "failed upgrade leaves broadcast.service running (fail-safe)"
    if wait_for_check "broadcast.service active" \
        "systemctl is-active --quiet broadcast.service" 12 5; then
        log_success "service still serving after the failed upgrade"
    else
        log_fail "service left STOPPED by the failed upgrade — the customer-reported outage"
    fi

    log_test "failed upgrade leaves the app container running (old version)"
    if wait_for_check "app container running" \
        "docker inspect -f {{.State.Status}} app | grep -q running" 12 5; then
        log_success "app container running from the cached image"
    else
        log_fail "app container not running after the failed upgrade"
    fi

    log_info "Restoring /etc/hosts..."
    vm_exec_root "mv /etc/hosts.smoke-backup /etc/hosts"

    # Recover the VM for the phases that follow — the same manual step the
    # customer had to run.
    log_info "Recovering with a manual broadcast.sh restart..."
    vm_exec_root "cd /opt/broadcast && ./broadcast.sh restart" || true
    run_health_checks "Phase 7b (post-recovery)"
}

# Phase 7c: the 2026-08-04 firstborngroup incident, end to end — a
# hand-edited docker-compose.yml. The dirty tree must abort the upgrade
# BEFORE the service is stopped (update-before-stop reorder), with a
# message pointing at docker-compose.override.yml; the documented
# remediation (discard the edit, move it into the override file) must then
# actually work, including the override being honored by the systemd unit
# (which previously pinned the compose file with -f, silently ignoring
# overrides). The override file deliberately stays in place afterwards, so
# every later phase doubles as coverage that a customized install stays
# healthy.
test_upgrade_dirty_tree_protection() {
    log_info "=== Phase 7c: Dirty-tree upgrade protection + override support ==="

    log_info "Hand-editing docker-compose.yml (simulating the customer)..."
    vm_exec_root "echo \"# smoke customer edit\" >> /opt/broadcast/docker-compose.yml"

    local out rc=0
    out=$(vm_exec_root "cd /opt/broadcast && ./broadcast.sh upgrade" 2>&1) || rc=$?

    log_test "upgrade refuses a dirty tree (nonzero exit)"
    if [ "$rc" -ne 0 ]; then
        log_success "upgrade exited nonzero on the dirty tree"
    else
        log_fail "upgrade exited 0 despite local modifications"
    fi

    log_test "refusal names the file and points at the override path"
    if echo "$out" | grep -q "docker-compose.override.yml" \
        && echo "$out" | grep -q "docker-compose.yml"; then
        log_success "clear guidance printed (override file named)"
    else
        log_fail "guidance missing from the refusal output: $out"
    fi

    log_test "the dirty-tree failure never touched the running service"
    if vm_exec_root "systemctl is-active --quiet broadcast.service" \
        && vm_exec_root "docker inspect -f {{.State.Status}} app | grep -q running"; then
        log_success "service and app container stayed up throughout"
    else
        log_fail "service went down on a failure that happens before the stop"
    fi

    log_info "Applying the documented remediation (override file + discard edit)..."
    # The override is exactly what the docs tell the firstborngroup customer
    # to write: replace the postgres port binding via the !override tag
    # (Compose v2.24+; without it lists merge additively and BOTH bindings
    # would exist). The app env var rides along to cover plain merging too.
    vm_exec_root "printf \"services:\\n  app:\\n    environment:\\n      SMOKE_OVERRIDE: applied\\n  postgres:\\n    ports: !override\\n      - 127.0.0.1:15432:5432\\n\" > /opt/broadcast/docker-compose.override.yml"
    vm_exec_root "cd /opt/broadcast && git checkout -- docker-compose.yml"

    log_test "update succeeds again once the tree is clean"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh update"; then
        log_success "script update flows again after remediation"
    else
        log_fail "update still failing after the documented remediation"
    fi

    log_info "Restarting to apply the override..."
    vm_exec_root "cd /opt/broadcast && ./broadcast.sh restart" || true

    log_test "docker-compose.override.yml is honored by the systemd unit"
    if wait_for_check "override env var present in app container" \
        "docker exec app printenv SMOKE_OVERRIDE | grep -q applied" 12 5; then
        log_success "override merged into the running app container"
    else
        log_fail "override file ignored — the unit is still pinning the compose file"
    fi

    log_test "!override replaces the postgres port binding (the documented customer method)"
    if wait_for_check "postgres bound to the override port" \
        "docker port postgres | grep -q 127.0.0.1:15432" 12 5; then
        log_success "postgres serving on the override binding 127.0.0.1:15432"
    else
        log_fail "override port binding not applied to postgres"
    fi

    log_test "the stock 5432 binding is gone (list REPLACED, not additively merged)"
    local binding_count
    binding_count=$(vm_exec_root "docker port postgres" | /usr/bin/grep -c "127.0.0.1" || true)
    if [ "$binding_count" = "1" ]; then
        log_success "exactly one host binding — !override replaced the stock entry"
    else
        log_fail "expected 1 host binding, found ${binding_count} — lists merged additively (missing/broken !override handling)"
    fi

    run_health_checks "Phase 7c (customized install)"
}

# Phase 7d: the upgrade preflight and the shutdown session sweep, end to end.
# Covers the two halves of the firstborngroup "upgrade hangs" report:
#   1. we must not stop the stack while a job is mid-execution
#   2. a remote client holding a session must not be able to stall the
#      postgres shutdown into a SIGKILL (which causes WAL crash recovery on
#      the next boot, an unhealthy healthcheck, and an app container that
#      sits waiting on depends_on)
# The remote client is simulated with a real psql session held open from
# inside the VM, connected over the published port exactly as their BI tool
# would be.
test_upgrade_preflight_and_session_sweep() {
    log_info "=== Phase 7d: Upgrade preflight + database session sweep ==="

    log_test "preflight reports a clean system as safe"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh preflight" | grep -q "safe to upgrade"; then
        log_success "preflight passes on an idle install"
    else
        log_fail "preflight did not report an idle system as safe"
    fi

    # Simulate a job a worker has already claimed. This is the state that must
    # block: killing it cuts a send off partway through a batch.
    log_info "Claiming a job to simulate a send in progress..."
    # Insert a worker process, a job, and the claim row that marks it
    # mid-execution. Failures here must not abort the whole run, so the
    # assertion below judges the outcome instead of set -e doing it.
    vm_psql broadcast_queue_production "INSERT INTO solid_queue_processes (kind, name, pid, last_heartbeat_at, created_at) VALUES ('Worker', 'smoke', 999, NOW(), NOW());" || true
    vm_psql broadcast_queue_production "INSERT INTO solid_queue_jobs (queue_name, class_name, priority, created_at, updated_at) VALUES ('default', 'BroadcastSendJob', 0, NOW(), NOW());" || true
    vm_psql broadcast_queue_production "INSERT INTO solid_queue_claimed_executions (job_id, process_id, created_at) SELECT j.id, p.id, NOW() FROM solid_queue_jobs j, solid_queue_processes p WHERE j.class_name = 'BroadcastSendJob' AND p.name = 'smoke' LIMIT 1;" || true

    log_test "the claimed job actually exists (guards the rest of this phase)"
    local claimed
    claimed=$(vm_psql broadcast_queue_production "SELECT COUNT(*) FROM solid_queue_claimed_executions;" | tr -dc '0-9')
    if [ "${claimed:-0}" -ge 1 ]; then
        log_success "claimed execution present in the queue database"
    else
        log_fail "could not create a claimed execution — the assertions below would pass vacuously"
    fi

    local out rc=0
    out=$(vm_exec_root "cd /opt/broadcast && ./broadcast.sh upgrade" 2>&1) || rc=$?

    log_test "upgrade refuses while a job is mid-execution"
    if [ "$rc" -ne 0 ] && echo "$out" | grep -q "mid-execution"; then
        log_success "preflight blocked the upgrade and named the running job"
    else
        log_fail "upgrade proceeded (or gave no reason) with a claimed job present: $out"
    fi

    log_test "the blocked upgrade never stopped the service"
    if vm_exec_root "systemctl is-active --quiet broadcast.service" \
        && vm_exec_root "docker inspect -f {{.State.Status}} app | grep -q running"; then
        log_success "service and app container stayed up"
    else
        log_fail "the service went down on a check that runs before the stop"
    fi

    log_test "preflight alone also reports the blockage"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh preflight" >/dev/null 2>&1; then
        log_fail "standalone preflight reported safe while a job was claimed"
    else
        log_success "standalone preflight agrees the system is not safe to upgrade"
    fi

    log_info "Clearing the simulated in-flight work..."
    vm_psql broadcast_queue_production "DELETE FROM solid_queue_claimed_executions; DELETE FROM solid_queue_jobs WHERE class_name = 'BroadcastSendJob'; DELETE FROM solid_queue_processes WHERE name = 'smoke';" || true

    log_test "preflight clears once the work is done"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh preflight" | grep -q "safe to upgrade"; then
        log_success "preflight passes again"
    else
        log_fail "preflight still blocking after the work was cleared"
    fi

    # --- the session sweep -------------------------------------------------
    log_info "Opening a long-lived database session (simulating their remote client)..."
    # `idle in transaction` is the dangerous state: it holds locks. Held open
    # in the background via a FIFO so the session stays alive across commands.
    # `docker exec -d` detaches inside the container, so the session survives
    # the ssh command returning (a backgrounded ssh child would not).
    vm_exec_root "docker exec -d postgres psql -U broadcast -d broadcast_primary_production -c \"BEGIN; SELECT pg_sleep(600);\"" || true
    sleep 3

    log_test "the held session is actually open (guards the sweep assertion)"
    local held
    held=$(vm_psql broadcast_primary_production "SELECT COUNT(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();" | tr -dc '0-9')
    if [ "${held:-0}" -ge 1 ]; then
        log_success "client session present before the sweep"
    else
        log_fail "no client session to sweep — the assertion below would pass vacuously"
    fi

    log_test "the sweep sees and closes the lingering session"
    out=$(vm_exec_root "cd /opt/broadcast && ./broadcast.sh restart" 2>&1) || true
    if echo "$out" | grep -q "Closing database sessions before shutdown"; then
        log_success "sweep ran and named the sessions it closed"
    else
        log_fail "restart did not report closing database sessions: $out"
    fi

    log_test "postgres shut down cleanly (no WAL crash recovery on the next boot)"
    if vm_exec_root "journalctl CONTAINER_NAME=postgres --since '2 minutes ago' --no-pager" \
        | grep -q "database system was not properly shut down"; then
        log_fail "postgres was SIGKILLed and recovered from WAL — the shutdown is still stalling"
    else
        log_success "clean shutdown, no crash recovery"
    fi

    log_test "idle_in_transaction_session_timeout is active on the server"
    # Via vm_psql: an inline `-c 'SHOW ...'` loses its quotes to vm_exec_root
    # and psql never runs, which reads as "disabled" rather than as a broken
    # assertion.
    local iit
    iit=$(vm_psql broadcast_primary_production "SHOW idle_in_transaction_session_timeout;" | tr -d '[:space:]')
    if [ -n "$iit" ] && [ "$iit" != "0" ]; then
        log_success "abandoned transactions are reaped by the server (timeout: $iit)"
    else
        log_fail "idle_in_transaction_session_timeout is still disabled (got: ${iit:-<no output>})"
    fi

    run_health_checks "Phase 7d (post-preflight)"
}

# Shared streaming lifecycle assertions: start via trigger, survive container
# recreation (reattach), and stop on trigger removal. Used by both the
# behavioural (--test-upgrade) and genuine-upgrade (--test-real-upgrade) phases.
_test_streaming_lifecycle() {
    # Start streaming the way Rails does — by creating the trigger file.
    log_test "creating the trigger starts streaming (application.log populated)"
    vm_exec_root "date -u +%Y-%m-%dT%H:%M:%SZ > /opt/broadcast/app/triggers/logs-stream.txt"
    if wait_for_check "application.log populated" \
        "test -s /opt/broadcast/logs/application.log" 20 3; then
        log_success "application.log is being written"
    else
        log_fail "application.log never populated after trigger created"
    fi

    # The core fix: recreate BOTH containers, streaming must keep flowing (no
    # surviving `docker logs -f` can mask a broken reattach).
    log_test "streaming survives container recreation (docker restart app job)"
    local lines_before
    lines_before=$(vm_exec_root "wc -l < /opt/broadcast/logs/application.log 2>/dev/null" | tr -d "[:space:]")
    vm_exec_root "docker restart app job >/dev/null 2>&1"
    if wait_for_check "application.log grew after restart" \
        "test \$(wc -l < /opt/broadcast/logs/application.log 2>/dev/null) -gt ${lines_before:-0}" 30 5; then
        log_success "application.log kept growing after both containers recreated (reattach works)"
    else
        log_fail "application.log froze after container recreation (reattach failed)"
    fi

    # Removing the trigger stops streaming. First let the app container become
    # exec-ready again after the recreation, otherwise check_log_streaming_trigger's
    # volume guard (docker exec app ...) returns early and defers the stop.
    wait_for_check "app container exec-ready" "docker exec app test -d /rails/logs" 30 5 || true
    log_test "removing the trigger stops streaming"
    vm_exec_root "rm -f /opt/broadcast/app/triggers/logs-stream.txt"
    if wait_for_check "streaming stopped" \
        "! test -f /opt/broadcast/logs/.streaming.pid" 20 3; then
        log_success "streaming stopped after trigger removed"
    else
        log_fail "streaming did not stop after trigger removed"
        log_info "--- diagnostics: watcher log (tail) ---"
        vm_exec_root "tail -n 25 /opt/broadcast/logs/logs-watcher.log 2>/dev/null"
        log_info "--- diagnostics: trigger / pid / streamer state ---"
        vm_exec_root "ls -la /opt/broadcast/app/triggers/ /opt/broadcast/logs/.streaming.pid 2>&1; echo ---; docker ps --format '{{.Names}} {{.Status}}'; echo ---; ps -eo pid,pgid,args | grep -E 'setsid|docker logs' | grep -v grep"
    fi
}

#######################
# Domain change — exercises the interactive change_installation_domain
# command by feeding its prompts from a file. Runs LAST (it changes the
# domain and restarts the stack; nothing after it depends on the old
# domain). Commands stay quote-free: vm_exec_root's nested vagrant-ssh/sudo
# quoting mangles quoted patterns.
#######################

test_domain_change() {
    log_info "=== Domain Change (change_installation_domain) ==="

    local old_domain="smoke-test.local"
    local new_domain="smoke-renamed.local"

    # 1. An invalid domain (no TLD) is rejected and changes nothing
    log_test "invalid domain is rejected"
    vm_exec_root "echo invalid-no-tld > /tmp/domain-input.txt"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh change_installation_domain < /tmp/domain-input.txt"; then
        log_fail "invalid domain was accepted (exit 0)"
    else
        log_success "invalid domain rejected (non-zero exit)"
    fi
    if vm_exec_root "grep -qx $old_domain /opt/broadcast/.domain"; then
        log_success ".domain unchanged after rejection"
    else
        log_fail ".domain was modified by a rejected change"
    fi

    # 2. Answering no at the confirmation cancels cleanly
    log_test "declining the confirmation cancels the change"
    vm_exec_root "echo $new_domain > /tmp/domain-input.txt; echo n >> /tmp/domain-input.txt"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh change_installation_domain < /tmp/domain-input.txt"; then
        log_success "cancelled change exits 0"
    else
        log_fail "cancelled change exited non-zero"
    fi
    if vm_exec_root "grep -qx $old_domain /opt/broadcast/.domain"; then
        log_success ".domain unchanged after cancellation"
    else
        log_fail ".domain was modified by a cancelled change"
    fi

    # 3. A confirmed change updates every domain artifact and the system
    # comes back up
    log_test "confirmed domain change updates config and restarts cleanly"
    vm_exec_root "echo $new_domain > /tmp/domain-input.txt; echo y >> /tmp/domain-input.txt"
    if vm_exec_root "cd /opt/broadcast && ./broadcast.sh change_installation_domain < /tmp/domain-input.txt > /tmp/domain-change.log 2>&1"; then
        log_success "change_installation_domain exited 0"
    else
        log_fail "change_installation_domain failed — output follows"
        vm_exec_root "tail -20 /tmp/domain-change.log" 2>/dev/null | sed 's/^/    | /'
        return
    fi

    if vm_exec_root "grep -qx $new_domain /opt/broadcast/.domain"; then
        log_success ".domain holds the new domain"
    else
        log_fail ".domain was not updated"
    fi

    if vm_exec_root "grep -q TLS_DOMAIN=$new_domain /opt/broadcast/app/.env"; then
        log_success "TLS_DOMAIN updated in app/.env"
    else
        log_fail "TLS_DOMAIN was not updated in app/.env"
    fi

    if vm_exec_root "grep domain_change /opt/broadcast/.domain_history | grep -q $new_domain"; then
        log_success "domain change recorded in .domain_history"
    else
        log_fail ".domain_history entry missing"
    fi

    log_test "system recovers after the domain-change restart"
    local recovered=false
    for _ in $(seq 1 24); do
        if vm_exec_root "systemctl is-active broadcast.service" >/dev/null 2>&1 &&
           vm_exec_root "docker exec app curl -sf -o /dev/null http://localhost:3000/up" >/dev/null 2>&1; then
            recovered=true
            break
        fi
        sleep 5
    done
    if [ "$recovered" = true ]; then
        log_success "service active and HTTP /up healthy on the new domain"
    else
        log_fail "system did not recover within 120s of the domain change"
    fi
}

#######################
# Parse CLI Arguments
#######################

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-cleanup)
                FLAG_NO_CLEANUP=true
                ;;
            --test-reboot)
                FLAG_TEST_REBOOT=true
                ;;
            --test-upgrade)
                FLAG_TEST_UPGRADE=true
                ;;
            --test-real-upgrade)
                FLAG_TEST_REAL_UPGRADE=true
                ;;
            --test-upgrade-failsafe)
                FLAG_TEST_UPGRADE_FAILSAFE=true
                ;;
            --from-ref)
                shift
                if [ $# -eq 0 ]; then
                    echo "Error: --from-ref requires a git ref to install before upgrading"
                    exit 1
                fi
                FROM_REF="$1"
                ;;
            --verbose)
                FLAG_VERBOSE=true
                ;;
            --local)
                FLAG_LOCAL=true
                ;;
            --ubuntu)
                shift
                if [ $# -eq 0 ]; then
                    echo "Error: --ubuntu requires a version (e.g. 24.04, 26.04, or 'all')"
                    exit 1
                fi
                if [ "$1" = "all" ]; then
                    UBUNTU_VERSIONS=("${DEFAULT_UBUNTU_VERSIONS[@]}")
                else
                    UBUNTU_VERSIONS=("$1")
                fi
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --ubuntu VERSION  Ubuntu version to test: 24.04, 26.04, or all (default: all)"
                echo "  --local           Test the local working tree instead of cloning the canonical remote"
                echo "  --no-cleanup      Keep VM after test for debugging"
                echo "  --test-reboot     Also verify services survive a reboot (incl. a reboot with the registry unreachable)"
                echo "  --test-upgrade    Also verify the log-streaming watcher restart + streaming survives container recreation"
                echo "  --test-real-upgrade  Run a genuine 'broadcast.sh upgrade' (use with --from-ref to install an older rev first)"
                echo "  --test-upgrade-failsafe  Upgrade-hardening phases: failed-upgrade fail-safe (7b), dirty-tree protection + compose override support (7c), and upgrade preflight + database session sweep (7d)"
                echo "  --from-ref REF    Reset /opt/broadcast to REF before install (remote mode), so an upgrade is genuine old->new"
                echo "  --verbose         Show all command output"
                echo "  --help            Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done
}

#######################
# Main
#######################

run_for_version() {
    local version="$1"

    UBUNTU_VERSION="$version"
    VAGRANT_DIR="$SCRIPT_DIR/.vagrant-smoke-${version}"

    local prev_run=$TESTS_RUN
    local prev_passed=$TESTS_PASSED
    local prev_failed=$TESTS_FAILED

    echo ""
    echo "=========================================="
    echo "  Ubuntu ${version}"
    echo "=========================================="
    echo ""

    setup_vm
    prepare_installation
    run_installer
    run_health_checks "Phase 4 (Ubuntu ${version})"
    run_install_state_checks
    test_backup_restore_cycle
    display_inspection
    test_log_persistence_across_restart

    if [ "$FLAG_TEST_REBOOT" = true ]; then
        test_reboot_recovery
        test_boot_registry_outage
    fi

    if [ "$FLAG_TEST_UPGRADE" = true ]; then
        test_upgrade_and_streaming
    fi

    if [ "$FLAG_TEST_REAL_UPGRADE" = true ]; then
        test_real_upgrade
    fi

    if [ "$FLAG_TEST_UPGRADE_FAILSAFE" = true ]; then
        test_upgrade_failure_failsafe
        test_upgrade_dirty_tree_protection
        test_upgrade_preflight_and_session_sweep
    fi

    # Always last: changes the installation domain and restarts the stack
    test_domain_change

    # Tear down this version's VM before moving on so disk/VMware resources free up
    cleanup
    VAGRANT_DIR=""

    VERSION_NAMES+=("$version")
    VERSION_RUN+=("$((TESTS_RUN - prev_run))")
    VERSION_PASSED+=("$((TESTS_PASSED - prev_passed))")
    VERSION_FAILED+=("$((TESTS_FAILED - prev_failed))")
}

main() {
    parse_args "$@"

    local repo_source
    if [ "$FLAG_LOCAL" = true ]; then
        repo_source="local working tree"
    else
        repo_source="$BROADCAST_REPO_URL"
    fi

    echo ""
    echo "=========================================="
    echo "  Broadcast Smoke Test (Vagrant)"
    echo "  Ubuntu versions: ${UBUNTU_VERSIONS[*]}"
    echo "  Repo source:     ${repo_source}"
    echo "=========================================="
    echo ""

    trap cleanup EXIT

    load_credentials

    for version in "${UBUNTU_VERSIONS[@]}"; do
        run_for_version "$version"
    done

    # Summary
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo ""
    for i in "${!VERSION_NAMES[@]}"; do
        local name="${VERSION_NAMES[$i]}"
        local run="${VERSION_RUN[$i]}"
        local passed="${VERSION_PASSED[$i]}"
        local failed="${VERSION_FAILED[$i]}"
        # log_test counts test sections; log_success/log_fail count individual
        # checks within them — different units, so label them distinctly
        # instead of printing nonsense like "13/9 passed".
        if [ "$failed" -eq 0 ]; then
            echo -e "  Ubuntu ${name}: ${GREEN}${run} tests, ${passed} checks passed${NC}"
        else
            echo -e "  Ubuntu ${name}: ${RED}${failed} checks failed${NC} (${run} tests, ${passed} checks passed)"
        fi
    done
    echo ""
    echo "Tests run:     $TESTS_RUN"
    echo -e "Checks passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Checks failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
