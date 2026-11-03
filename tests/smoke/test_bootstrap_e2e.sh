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
#   legacy-upgrade  a server installed at an older commit (--from, default
#                   a1df6f0) the way customers installed it then, upgraded to
#                   the branch under test (--ref). Two paths, a fresh VM each:
#                   `broadcast.sh upgrade`, and the nightly `update` cron run
#                   twice (night 1 pulls the new scripts with the old ones
#                   loaded; night 2 runs the new ones). After each step: health,
#                   owner and mode of the env files, broadcast.service, and a
#                   restart that works.
#
# Usage:
#   ./tests/smoke/test_bootstrap_e2e.sh --ubuntu 24.04 --scenario noninteractive [--ref BRANCH] [--no-cleanup]
#   ./tests/smoke/test_bootstrap_e2e.sh --scenario legacy-upgrade [--from REF] [--path upgrade|nightly|both]
#
# Needs tests/smoke/.smoke-test.env (BROADCAST_LICENSE_KEY), vagrant with the
# vagrant-qemu plugin, and expect for the interactive scenario. The Vagrantfile,
# the ssh helpers and the redaction come from lib/smoke_vm.sh: everything this
# script prints or saves has the license key and the VM's secrets masked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=lib/smoke_vm.sh
source "$SCRIPT_DIR/lib/smoke_vm.sh"
REPO_SLUG="send-broadcast/broadcast-script"
REPO_URL="https://github.com/${REPO_SLUG}.git"
DOMAIN="smoke-test.local"

UBUNTU_VERSION="24.04"
SCENARIO=""
REF="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
# legacy-upgrade starts here: the last commit before the env-file changes (b17bfb0)
FROM_REF="a1df6f0"
LEGACY_PATH="both"
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
        --from) FROM_REF="$2"; shift ;;
        --path) LEGACY_PATH="$2"; shift ;;
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
case "$LEGACY_PATH" in
    upgrade|nightly|both) ;;
    *) echo "--path must be upgrade, nightly or both"; exit 1 ;;
esac

RAW_URL="https://raw.githubusercontent.com/${REPO_SLUG}/${REF}/install.sh"
VAGRANT_DIR="$SCRIPT_DIR/.vagrant-smoke-e2e-${UBUNTU_VERSION}-${SCENARIO}"

if [ -f "$SCRIPT_DIR/.smoke-test.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.smoke-test.env"
fi
if [ -z "${BROADCAST_LICENSE_KEY:-}" ]; then
    echo "BROADCAST_LICENSE_KEY is not set (tests/smoke/.smoke-test.env)"; exit 1
fi
KEY="$BROADCAST_LICENSE_KEY"

# From here on everything this script prints, the VM's output included, goes
# through the redaction filter: the license key now, the secrets in the VM's
# env files once an install wrote them (smoke_redact_vm_secrets).
smoke_redact_add "$KEY"
smoke_redact_output
redact() { smoke_redact; }

vm_ssh() { smoke_ssh "$@"; }
vm_root() { smoke_root "$1"; }

wait_for() {
    local desc="$1" cmd="$2" tries="${3:-30}" delay="${4:-10}" i
    for ((i = 0; i < tries; i++)); do
        vm_root "$cmd" >/dev/null 2>&1 && return 0
        sleep "$delay"
    done
    log_info "timed out waiting for: $desc"
    return 1
}

destroy_vm() {
    (cd "$VAGRANT_DIR" 2>/dev/null && vagrant destroy -f >/dev/null 2>&1) || true
    rm -rf "$VAGRANT_DIR"
}

cleanup() {
    if [ "$NO_CLEANUP" = true ]; then
        smoke_redact_file "$VAGRANT_DIR"/*.log
        log_info "VM kept: cd $VAGRANT_DIR && vagrant ssh"
    else
        destroy_vm
    fi
    smoke_redact_cleanup
}

setup_vm() {
    log_info "=== Ubuntu ${UBUNTU_VERSION} / ${SCENARIO}: launching a fresh VM ==="
    rm -rf "$VAGRANT_DIR"
    local port=$((51000 + ${UBUNTU_VERSION%%.*} * 10 + PORT_OFFSET))
    smoke_write_vagrantfile "$VAGRANT_DIR" "$UBUNTU_VERSION" "$port" broadcast-e2e
    smoke_vagrant_up "$VAGRANT_DIR" "$VAGRANT_DIR/up.log" || {
        log_fail "vagrant up failed (see $VAGRANT_DIR/up.log)"; exit 1; }
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

# The running stack: containers, /up, broadcast.service.
stack_checks() {
    local label="$1" c
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
}

# Everything an installed server must have, checked after each phase.
health_checks() {
    local label="$1" name count
    log_info "--- health checks: $label ---"
    stack_checks "$label"
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
    echo "$out" | redact > "$VAGRANT_DIR/install-output.log"
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
    smoke_redact_vm_secrets
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
    # log_user 0: expect does not copy the session to stdout; log_file -a
    # still records it (without -a it records nothing). The TTY echoes
    # the typed key and the confirmation prompt repeats it; the transcript
    # file is masked right after the session (smoke_redact_file), and only
    # its masked tail is printed.
    E2E_SSH_CFG="$SMOKE_SSH_CFG" E2E_URL="$RAW_URL" E2E_REF="$REF" E2E_DOMAIN="$DOMAIN" E2E_KEY="$KEY" E2E_LOG="$transcript" \
    expect <<'EXPECT'
set timeout 2400
log_user 0
log_file -a -noappend $env(E2E_LOG)
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
    smoke_redact_vm_secrets
    smoke_redact_file "$transcript"
    log_info "license key prompts as recorded (masked):"
    tr -d '\r' < "$transcript" | grep -i -E 'license key|Install Broadcast for' | sed 's/^/    | /'
    tr -d '\r' < "$transcript" | grep -v '^\s*$' | tail -30 | sed 's/^/    | /'
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

# --- legacy-upgrade ------------------------------------------------------------

ENV_STATES=()

# Installs --from the way customers installed it then. When that commit has the
# one-line installer, it is fetched by raw URL at that commit and run; its clone
# of main is served by a local mirror whose main is the --from commit (git's
# url.insteadOf), so the checkout ends exactly like a customer's: branch main,
# tracking the real origin. Older commits get the clone + broadcast.sh install
# of their README. No reboot at the end (BROADCAST_NO_REBOOT, or the patch for
# installers that predate it).
legacy_install() {
    local out rc mirror=/root/e2e-from.git head want origin branch start
    log_info "Installing $FROM_REF the way customers installed it then"
    start=$(date +%s)
    out=$(vm_root "set -e
        git clone -q --bare $REPO_URL $mirror
        sha=\$(git -C $mirror rev-parse --verify '${FROM_REF}^{commit}')
        git -C $mirror update-ref refs/heads/main \$sha
        echo \$sha > /root/e2e-from.sha
        git config --global url.$mirror.insteadOf $REPO_URL
        if git -C $mirror cat-file -e \$sha:install.sh 2>/dev/null; then
            echo E2E_ROUTE=one-line-installer
            curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/\$sha/install.sh | BROADCAST_DOMAIN=$DOMAIN BROADCAST_LICENSE=$KEY BROADCAST_NO_REBOOT=1 bash
        else
            echo E2E_ROUTE=clone
            git clone -q $REPO_URL /opt/broadcast
            cd /opt/broadcast
            echo $DOMAIN > .domain
            echo $KEY > .license
            ./broadcast.sh validate_license >/dev/null
            sed -i 's/sudo reboot/echo LEGACY_SKIP_REBOOT/' scripts/install.sh
            BROADCAST_NO_REBOOT=1 ./broadcast.sh install
            git checkout -- scripts/install.sh
        fi
        git config --global --unset url.$mirror.insteadOf
        rm -rf $mirror" 2>&1); rc=$?
    echo "$out" | grep -E '^E2E_ROUTE=' | sed 's/^/    | /'
    echo "$out" | redact | tail -8 | sed 's/^/    | /'
    head=$(vm_root "git -C /opt/broadcast rev-parse HEAD" 2>/dev/null)
    want=$(vm_root "cat /root/e2e-from.sha" 2>/dev/null)
    origin=$(vm_root "git -C /opt/broadcast remote get-url origin" 2>/dev/null)
    branch=$(vm_root "git -C /opt/broadcast rev-parse --abbrev-ref HEAD" 2>/dev/null)
    log_test "install at $FROM_REF exits 0 and leaves a customer checkout"
    if [ "$rc" = "0" ] && [ -n "$want" ] && [ "$head" = "$want" ] && [ "$origin" = "$REPO_URL" ] && [ "$branch" = "main" ]; then
        log_success "installed ${head:0:7} on main, origin $origin, in $(( $(date +%s) - start ))s"
    else
        log_fail "install at $FROM_REF: rc=$rc head=${head:0:7} want=${want:0:7} branch=$branch origin=$origin"
        return 1
    fi
    smoke_redact_vm_secrets
}

# The checkout tracks origin/$REF, as it does once $REF is merged into main
legacy_track_ref() {
    vm_root "cd /opt/broadcast && git fetch -q origin $REF && if [ \"\$(git rev-parse --abbrev-ref HEAD)\" != $REF ]; then git checkout -q -b $REF; fi && git branch -q -u origin/$REF"
}

check_scripts_at_ref() {
    local label="$1"
    log_test "[$label] scripts advanced to origin/$REF"
    if vm_root "cd /opt/broadcast && test \"\$(git rev-parse HEAD)\" = \"\$(git rev-parse origin/$REF)\""; then
        log_success "scripts at origin/$REF ($(vm_root 'git -C /opt/broadcast rev-parse --short HEAD'))"
    else
        log_fail "scripts not at origin/$REF ($(vm_root 'git -C /opt/broadcast rev-parse --short HEAD'))"
    fi
}

# After each step: health, the env files' owner and mode (before the restart,
# which secures them itself), broadcast.service, and a restart that works.
# legacy_step_checks LABEL private|record
legacy_step_checks() {
    local label="$1" expect="$2" state line bad="" active out rc
    stack_checks "$label"
    state=$(vm_root "stat -c '%U:%G %a %n' /opt/broadcast/.env /opt/broadcast/app/.env /opt/broadcast/db/.env" 2>&1)
    log_info "[$label] env files:"
    echo "$state" | sed 's/^/    | /'
    while IFS= read -r line; do
        ENV_STATES+=("$label | $line")
        case "$line" in
            "broadcast:broadcast 600 "*) ;;
            *) bad="$bad ${line##* }" ;;
        esac
    done <<< "$state"
    if [ "$expect" = "private" ]; then
        log_test "[$label] .env, app/.env and db/.env are broadcast:broadcast 600"
        if [ -z "$bad" ]; then log_success "all three broadcast:broadcast 600"; else log_fail "not broadcast:broadcast 600:$bad"; fi
    fi
    active=$(vm_root "systemctl is-active broadcast" 2>&1)
    log_test "[$label] systemctl is-active broadcast"
    if [ "$active" = "active" ]; then log_success "$active"; else log_fail "$active"; fi
    log_test "[$label] broadcast.sh restart works"
    out=$(vm_root "cd /opt/broadcast && ./broadcast.sh restart" 2>&1); rc=$?
    echo "$out" | tail -4 | sed 's/^/    | /'
    if [ "$rc" = "0" ] && wait_for "service active" "systemctl is-active --quiet broadcast" 12 5 && \
       wait_for "/up after restart" "curl -sf http://localhost/up" 40 10; then
        log_success "restart exited 0; service active and /up 200 again"
    else
        log_fail "restart: rc=$rc, or the stack did not come back"
    fi
}

# Runs the nightly update exactly as cron does: the command from root's
# crontab, under sh, with cron's environment.
nightly_update() {
    local label="$1" out rc
    log_test "[$label] the nightly update cron command exits 0"
    out=$(vm_root "cmd=\$(crontab -l | grep 'broadcast.sh update ' | head -1 | cut -d' ' -f6-)
        echo \"cron: \$cmd\"
        cd /root && env -i HOME=/root LOGNAME=root USER=root SHELL=/bin/sh PATH=/usr/bin:/bin sh -c \"\$cmd\"; rc=\$?
        tail -n 6 /opt/broadcast/logs/cron/update.log
        exit \$rc" 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "update exited 0"; else log_fail "update exited $rc"; fi
}

legacy_path_upgrade() {
    log_info "=== legacy-upgrade, path 1: $FROM_REF -> $REF by broadcast.sh upgrade ==="
    legacy_install || return 1
    legacy_step_checks "installed at $FROM_REF" record
    legacy_track_ref
    cli_upgrade "upgrade $FROM_REF -> $REF"
    check_scripts_at_ref "after broadcast.sh upgrade"
    legacy_step_checks "after broadcast.sh upgrade" private
    log_test "fix reports nothing to repair after the upgrade"
    local out rc
    out=$(vm_root "cd /opt/broadcast && ./broadcast.sh fix" 2>&1); rc=$?
    echo "$out" | grep -E "FAIL|fixed|Summary|summary" | head -10 | sed 's/^/    | /'
    if [ "$rc" = "0" ]; then log_success "fix exited 0"; else log_fail "fix exited $rc"; fi
    trigger_upgrade "legacy dashboard-trigger upgrade"

    check_raw_url_matches_local
    check_refusal "one-liner on a legacy-installed server" \
        "curl -fsSL $RAW_URL | sudo BROADCAST_DOMAIN=$DOMAIN BROADCAST_LICENSE=$KEY bash" -T
}

legacy_path_nightly() {
    log_info "=== legacy-upgrade, path 2: $FROM_REF -> $REF by the nightly update ==="
    legacy_install || return 1
    legacy_step_checks "installed at $FROM_REF" record
    legacy_track_ref
    nightly_update "night 1"
    check_scripts_at_ref "after night 1"
    legacy_step_checks "after night 1" record
    nightly_update "night 2"
    legacy_step_checks "after night 2" private
    health_checks "after night 2"
}

scenario_legacy_upgrade() {
    case "$LEGACY_PATH" in
        upgrade) legacy_path_upgrade ;;
        nightly) legacy_path_nightly ;;
        both)
            legacy_path_upgrade
            log_info "Fresh VM for the nightly path"
            destroy_vm
            setup_vm
            legacy_path_nightly
            ;;
    esac
    echo
    log_info "Env files (owner:group mode) after each step:"
    local s
    for s in "${ENV_STATES[@]}"; do echo "    $s"; done
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
