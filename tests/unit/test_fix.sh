#!/bin/bash

# Unit tests for the fix() convergence command (scripts/fix.sh), written
# TDD-first. fix repairs installation DRIFT idempotently — directories,
# ownership, executable bits, sudoers, docker group, systemd units, cron
# entries, encryption keys — and reports ok:/fixed: per check. It does NOT
# re-run one-time provisioning: a missing prerequisite like docker itself
# is reported as unfixable (exit 1) and points at ./broadcast.sh install.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    touch "$SANDBOX_ROOT/broadcast.sh"
    chmod +x "$SANDBOX_ROOT/broadcast.sh"

    # Healthy config baseline; individual tests delete pieces to create drift
    cat > "$SANDBOX_ROOT/app/.env" <<'ENV'
SECRET_KEY_BASE=abc123
DATABASE_PASSWORD=pass123
TLS_DOMAIN=test.example.com
ENV
    echo "POSTGRES_PASSWORD=pass123" > "$SANDBOX_ROOT/db/.env"
    cat > "$SANDBOX_ROOT/.env" <<'ENV'
BROADCAST_REGISTRY_URL=gitea.hostedapp.org
BROADCAST_REGISTRY_LOGIN=broadcast-user
BROADCAST_REGISTRY_PASSWORD=s3cret
ENV
    mkdir -p "$SANDBOX_ROOT/home/broadcast/.docker"
    echo '{"auths":{"gitea.hostedapp.org":{}}}' > "$SANDBOX_ROOT/home/broadcast/.docker/config.json"
    echo "2.23.0" > "$SANDBOX_ROOT/.current_version"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.23.0" > "$SANDBOX_ROOT/.image"
    echo "/opt/broadcast/logs config" > "$SANDBOX_ROOT/etc/logrotate.d/broadcast"
    chmod +x "$SANDBOX_ROOT/scripts/post-upgrade-cleanup.sh" \
             "$SANDBOX_ROOT/scripts/logs-trigger-watcher.sh" 2>/dev/null || true

    # systemctl: STATEFUL — enable/start leave markers that is-enabled/
    # is-active then honor, so fix's verify-after-repair sees the effect.
    # Env RCs give the pre-repair state.
    harness_mock systemctl 'case "${1:-}" in
  is-enabled) [ -f "$BROADCAST_ROOT/.enabled-${2:-}" ] && exit 0; exit "${SYSTEMCTL_IS_ENABLED_RC:-0}" ;;
  is-active) [ -f "$BROADCAST_ROOT/.active-${2:-}" ] && exit 0; exit "${SYSTEMCTL_IS_ACTIVE_RC:-0}" ;;
  enable) touch "$BROADCAST_ROOT/.enabled-${2:-}" ;;
  start) touch "$BROADCAST_ROOT/.active-${2:-}" ;;
esac
exit 0'
    # su: fix's registry-login repair runs docker login as broadcast; the
    # mock simulates a successful login by writing the docker config
    harness_mock su 'mkdir -p "$BROADCAST_ROOT/home/broadcast/.docker"
echo "{\"auths\":{\"gitea.hostedapp.org\":{}}}" > "$BROADCAST_ROOT/home/broadcast/.docker/config.json"
exit 0'
    # id: user exists; group list controllable
    harness_mock id 'if [ "${1:-}" = "-nG" ]; then echo "${ID_MOCK_GROUPS:-broadcast docker}"; fi
exit "${ID_MOCK_RC:-0}"'
    harness_mock usermod 'exit 0'
    harness_mock useradd 'exit 0'
    # crontab: -l prints the stored crontab, - installs from stdin.
    # The install path buffers to a temp file and mv's it into place:
    # real crontab has no shared file, but this mock does, and truncating
    # it directly would race the `crontab -l` running in the same pipeline.
    harness_mock crontab 'case "${1:-}" in
  -l) cat "${CRONTAB_MOCK_FILE:?}" 2>/dev/null || exit 1 ;;
  -) cat > "$CRONTAB_MOCK_FILE.tmp" && mv "$CRONTAB_MOCK_FILE.tmp" "$CRONTAB_MOCK_FILE" ;;
esac
exit 0'
    export CRONTAB_MOCK_FILE="$SANDBOX_ROOT/crontab.txt"
    # Present on a correct install; without this shim macOS (no inotifywait)
    # would take the install-inotify-tools repair path in every test
    harness_mock inotifywait 'exit 0'
}

teardown_sandbox() {
    unset CRONTAB_MOCK_FILE
    harness_destroy_sandbox
}

# Environment line passed to every sandbox_run so the crontab mock knows
# where its state lives inside the sandboxed shell.
FIX_ENV='export CRONTAB_MOCK_FILE="$BROADCAST_ROOT/crontab.txt"'

test_fix_recreates_missing_directories() {
    rm -rf "$SANDBOX_ROOT/app/triggers" "$SANDBOX_ROOT/logs/cron"

    local rc=0
    sandbox_run "fix" "$FIX_ENV" >/dev/null || rc=$?
    assert_equals "0" "$rc" "fix should succeed"

    if [ ! -d "$SANDBOX_ROOT/app/triggers" ]; then
        assert_equals "recreated" "missing" "app/triggers must be recreated"
    fi
    if [ ! -d "$SANDBOX_ROOT/logs/cron" ]; then
        assert_equals "recreated" "missing" "logs/cron must be recreated"
    fi
}

test_fix_restores_broadcast_sh_executable_bit() {
    chmod -x "$SANDBOX_ROOT/broadcast.sh"

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    if [ ! -x "$SANDBOX_ROOT/broadcast.sh" ]; then
        assert_equals "executable" "not executable" "broadcast.sh must be made executable"
    fi
    assert_contains "$output" "fixed:" "the repair must be reported"
}

test_fix_repairs_ownership_drift() {
    # Sandbox files are owned by the test user, not broadcast — fix must
    # chown (mocked and logged) and report it.
    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    harness_assert_called "chown -R broadcast:broadcast" "ownership drift must be repaired"
}

test_fix_leaves_correct_ownership_alone() {
    harness_mock stat 'echo broadcast'

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    harness_assert_not_called "chown -R broadcast:broadcast" \
        "correct ownership must not be touched"
}

test_fix_recreates_missing_sudoers_entry() {
    rm -f "$SANDBOX_ROOT/etc/sudoers.d/broadcast"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_file_exists "$SANDBOX_ROOT/etc/sudoers.d/broadcast" "sudoers entry must be recreated"
    assert_contains "$(cat "$SANDBOX_ROOT/etc/sudoers.d/broadcast")" "NOPASSWD" \
        "the recreated entry must grant passwordless sudo"
}

test_fix_restores_docker_group_membership() {
    sandbox_run "fix" "$FIX_ENV" 'export ID_MOCK_GROUPS="broadcast"' >/dev/null 2>&1 || true
    local output
    output=$(sandbox_run "fix" "
$FIX_ENV
export ID_MOCK_GROUPS=broadcast")

    harness_assert_called "usermod -aG docker broadcast" \
        "missing docker group membership must be repaired"
}

test_fix_installs_missing_systemd_units() {
    # Sandbox systemd dir starts empty: broadcast.service, the cleanup
    # unit, and the watcher unit must all be installed
    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast.service" \
        "broadcast.service must be created"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service" \
        "the cleanup unit must be installed"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service" \
        "the watcher unit must be installed"
    harness_assert_called "systemctl daemon-reload" "systemd must reload after unit installs"
}

test_fix_refreshes_stale_broadcast_unit() {
    # Incident (2026-08-03): production units still carried the install-time
    # template with no RestartSec / StartLimitIntervalSec — a reboot race
    # locked the service into 'failed'. fix must treat a stale unit as
    # drift and rewrite it, not report ok because the file merely exists.
    cat > "$SANDBOX_ROOT/etc/systemd/system/broadcast.service" <<'STALE'
[Unit]
Description=Broadcast
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=/bin/bash -c "docker compose up"
Restart=always
User=broadcast

[Install]
WantedBy=multi-user.target
STALE

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    assert_contains "$(cat "$SANDBOX_ROOT/etc/systemd/system/broadcast.service")" \
        "StartLimitIntervalSec=0" "a stale unit must be rewritten to the current template"
    assert_contains "$output" "fixed:" "the unit refresh must be reported as a repair"
    harness_assert_called "systemctl daemon-reload" "systemd must reload after the rewrite"
}

test_fix_enables_and_starts_inactive_services() {
    # Units present but disabled/stopped
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"

    sandbox_run "fix" "
$FIX_ENV
export SYSTEMCTL_IS_ENABLED_RC=1
export SYSTEMCTL_IS_ACTIVE_RC=1" >/dev/null

    harness_assert_called "systemctl enable broadcast.service" "disabled service must be enabled"
    harness_assert_called "systemctl start broadcast.service" "stopped service must be started"
    harness_assert_called "systemctl enable broadcast-logs-watcher" "watcher must be enabled"
    harness_assert_called "systemctl start broadcast-logs-watcher" "watcher must be started"
}

test_fix_adds_missing_cron_entries_once() {
    sandbox_run "fix" "$FIX_ENV" >/dev/null
    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_file_exists "$SANDBOX_ROOT/crontab.txt" "crontab must be installed"
    local cmd count
    for cmd in monitor trigger health update; do
        count=$(/usr/bin/grep -c "broadcast.sh $cmd" "$SANDBOX_ROOT/crontab.txt")
        assert_equals "1" "$count" "cron entry for '$cmd' must exist exactly once after two runs"
    done
}

test_fix_preserves_existing_cron_entries() {
    echo "0 3 * * * /usr/local/bin/custom-backup.sh" > "$SANDBOX_ROOT/crontab.txt"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/crontab.txt")" "custom-backup.sh" \
        "unrelated cron entries must survive"
}

test_fix_generates_missing_encryption_keys() {
    sandbox_run "fix" "$FIX_ENV" >/dev/null

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "missing encryption keys must be generated"
}

test_fix_fails_on_missing_docker_prerequisite() {
    local output rc=0
    output=$(sandbox_run '
fix_has_command() { [ "$1" != "docker" ]; }
fix' "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "a missing prerequisite must make fix exit 1"
    assert_contains "$output" "install" "the fix for a missing prerequisite is a reinstall"
}

test_fix_installs_inotify_tools_when_missing() {
    sandbox_run '
fix_has_command() { [ "$1" != "inotifywait" ]; }
fix' "$FIX_ENV" >/dev/null

    harness_assert_called "apt-get install -y inotify-tools" \
        "missing inotify-tools must be installed"
}

test_fix_regenerates_missing_image_file() {
    rm -f "$SANDBOX_ROOT/.image"

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    assert_file_exists "$SANDBOX_ROOT/.image" ".image must be regenerated"
    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":2.23.0" \
        ".image must be pinned to the installed version, not silently un-pinned to latest"
    assert_contains "$output" "fixed:" "the repair must be reported"
}

test_fix_image_defaults_to_latest_without_version_file() {
    rm -f "$SANDBOX_ROOT/.image" "$SANDBOX_ROOT/.current_version"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":latest" \
        "with no version record, latest is the only option"
}

test_fix_preserves_existing_image_file() {
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast-arm:2.20.0" > "$SANDBOX_ROOT/.image"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":2.20.0" \
        "an existing .image (a deliberate pin) must never be rewritten"
}

test_fix_fails_when_db_env_missing() {
    rm -f "$SANDBOX_ROOT/db/.env"

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "a lost db/.env is unfixable and must exit 1"
    assert_contains "$output" "db/.env" "the missing file must be named"
}

test_fix_installs_missing_compose_plugin() {
    # apt-get "installs" the plugin by touching a marker the seam checks
    harness_mock apt-get 'touch "$BROADCAST_ROOT/.compose-installed"
exit 0'
    local output rc=0
    output=$(sandbox_run '
fix_has_compose() { [ -f "$BROADCAST_ROOT/.compose-installed" ]; }
fix' "$FIX_ENV") || rc=$?

    assert_equals "0" "$rc" "a repairable compose plugin should not fail the run"
    harness_assert_called "apt-get install -y docker-compose-plugin" \
        "the missing plugin must be installed"
    assert_contains "$output" "fixed:" "the repair must be reported"
}

test_fix_fails_when_compose_cannot_be_installed() {
    local output rc=0
    output=$(sandbox_run '
fix_has_compose() { return 1; }
fix' "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "an uninstallable compose plugin must exit 1"
    assert_contains "$output" "FAIL" "the failure must be visible"
}

test_fix_restores_registry_login() {
    rm -f "$SANDBOX_ROOT/home/broadcast/.docker/config.json"

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    harness_assert_called "su - broadcast" "the login must run as the broadcast user"
    assert_contains "$output" "fixed:" "the repair must be reported"
    assert_file_exists "$SANDBOX_ROOT/home/broadcast/.docker/config.json" \
        "the login must be verified to have taken effect"
}

test_fix_reports_failed_service_start_honestly() {
    # Units present, service inactive, and starting does NOT help (the
    # non-stateful mock never flips to active). fix must not claim a
    # repair it cannot verify.
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"
    harness_mock systemctl 'case "${1:-}" in
  is-enabled) exit 0 ;;
  is-active) exit 1 ;;
esac
exit 0'

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "an unverifiable start must fail the run"
    assert_contains "$output" "FAIL" "the failed start must be reported as FAIL"
    if [[ "$output" == *"fixed: started broadcast.service"* ]]; then
        assert_equals "honest failure" "false success" \
            "fix must never claim it started a service that is still inactive"
    fi
}

test_fix_recreates_logrotate_config() {
    rm -f "$SANDBOX_ROOT/etc/logrotate.d/broadcast"

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    assert_file_exists "$SANDBOX_ROOT/etc/logrotate.d/broadcast" \
        "logrotate config must be recreated (unbounded log growth otherwise)"
    assert_contains "$(cat "$SANDBOX_ROOT/etc/logrotate.d/broadcast")" "logs" \
        "the config must rotate the Broadcast logs"
    assert_contains "$output" "fixed:" "the repair must be reported"
}

test_fix_restores_helper_script_exec_bits() {
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"
    chmod -x "$SANDBOX_ROOT/scripts/post-upgrade-cleanup.sh"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    if [ ! -x "$SANDBOX_ROOT/scripts/post-upgrade-cleanup.sh" ]; then
        assert_equals "executable" "not executable" \
            "a helper script that lost its exec bit must be repaired even when its unit exists"
    fi
}

test_fix_adds_missing_secret_key_base() {
    /usr/bin/grep -v "^SECRET_KEY_BASE=" "$SANDBOX_ROOT/app/.env" > "$SANDBOX_ROOT/app/.env.tmp"
    mv "$SANDBOX_ROOT/app/.env.tmp" "$SANDBOX_ROOT/app/.env"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    local count
    count=$(/usr/bin/grep -c "^SECRET_KEY_BASE=" "$SANDBOX_ROOT/app/.env")
    assert_equals "1" "$count" "a missing SECRET_KEY_BASE must be generated"
}

test_fix_adds_missing_tls_domain_from_domain_file() {
    /usr/bin/grep -v "^TLS_DOMAIN=" "$SANDBOX_ROOT/app/.env" > "$SANDBOX_ROOT/app/.env.tmp"
    mv "$SANDBOX_ROOT/app/.env.tmp" "$SANDBOX_ROOT/app/.env"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "TLS_DOMAIN=test.example.com" \
        "TLS_DOMAIN must be re-derived from .domain"
}

test_fix_copies_database_password_from_db_env() {
    /usr/bin/grep -v "^DATABASE_PASSWORD=" "$SANDBOX_ROOT/app/.env" > "$SANDBOX_ROOT/app/.env.tmp"
    mv "$SANDBOX_ROOT/app/.env.tmp" "$SANDBOX_ROOT/app/.env"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "DATABASE_PASSWORD=pass123" \
        "a missing DATABASE_PASSWORD must be restored from db/.env (the source of truth)"
}

test_fix_fails_on_database_password_mismatch() {
    echo "POSTGRES_PASSWORD=different456" > "$SANDBOX_ROOT/db/.env"

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "mismatched database passwords are not auto-fixable"
    assert_contains "$output" "FAIL" "the mismatch must be reported loudly"
}

test_fix_survives_a_failed_repair() {
    # The watcher unit is missing from BOTH systemd and the scripts dir, so
    # the cp repair fails. fix must record the failure, keep going, and
    # still end with an honest summary and exit 1 — not die mid-run.
    rm -f "$SANDBOX_ROOT/scripts/broadcast-logs-watcher.service"

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "a failed repair must fail the run"
    assert_contains "$output" "FAIL" "the failed repair must be reported"
    assert_contains "$output" "Done:" "the run must reach its summary despite the failure"
}

test_fix_reports_clean_on_healthy_system() {
    # Healthy: correct ownership, units present AND current, cron populated,
    # keys exist. broadcast.service must match the template — an empty or
    # stale unit is drift that fix repairs.
    harness_mock stat 'echo broadcast'
    sandbox_run "create_broadcast_service" >/dev/null
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"
    echo "broadcast ALL=(ALL) NOPASSWD:ALL" > "$SANDBOX_ROOT/etc/sudoers.d/broadcast"
    printf '* * * * * %s/broadcast.sh monitor\n* * * * * %s/broadcast.sh trigger\n* * * * * %s/broadcast.sh health\n0 0 * * * %s/broadcast.sh update\n' \
        "$SANDBOX_ROOT" "$SANDBOX_ROOT" "$SANDBOX_ROOT" "$SANDBOX_ROOT" > "$SANDBOX_ROOT/crontab.txt"
    cat >> "$SANDBOX_ROOT/app/.env" <<'ENV'
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=x
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=y
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=z
ENV

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "0" "$rc" "a healthy system should exit 0"
    assert_contains "$output" "ok:" "healthy checks should be reported ok"
    if [[ "$output" == *"fixed:"* ]]; then
        assert_equals "nothing to fix" "something was fixed" \
            "a healthy system must not report repairs: $output"
    fi
}

run_fix_tests() {
    echo "Running Fix Command Tests"
    echo "========================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_fix_recreates_missing_directories" test_fix_recreates_missing_directories
    run_test "test_fix_restores_broadcast_sh_executable_bit" test_fix_restores_broadcast_sh_executable_bit
    run_test "test_fix_repairs_ownership_drift" test_fix_repairs_ownership_drift
    run_test "test_fix_leaves_correct_ownership_alone" test_fix_leaves_correct_ownership_alone
    run_test "test_fix_recreates_missing_sudoers_entry" test_fix_recreates_missing_sudoers_entry
    run_test "test_fix_restores_docker_group_membership" test_fix_restores_docker_group_membership
    run_test "test_fix_installs_missing_systemd_units" test_fix_installs_missing_systemd_units
    run_test "test_fix_refreshes_stale_broadcast_unit" test_fix_refreshes_stale_broadcast_unit
    run_test "test_fix_enables_and_starts_inactive_services" test_fix_enables_and_starts_inactive_services
    run_test "test_fix_adds_missing_cron_entries_once" test_fix_adds_missing_cron_entries_once
    run_test "test_fix_preserves_existing_cron_entries" test_fix_preserves_existing_cron_entries
    run_test "test_fix_generates_missing_encryption_keys" test_fix_generates_missing_encryption_keys
    run_test "test_fix_fails_on_missing_docker_prerequisite" test_fix_fails_on_missing_docker_prerequisite
    run_test "test_fix_installs_inotify_tools_when_missing" test_fix_installs_inotify_tools_when_missing
    run_test "test_fix_regenerates_missing_image_file" test_fix_regenerates_missing_image_file
    run_test "test_fix_image_defaults_to_latest_without_version_file" test_fix_image_defaults_to_latest_without_version_file
    run_test "test_fix_preserves_existing_image_file" test_fix_preserves_existing_image_file
    run_test "test_fix_fails_when_db_env_missing" test_fix_fails_when_db_env_missing
    run_test "test_fix_installs_missing_compose_plugin" test_fix_installs_missing_compose_plugin
    run_test "test_fix_fails_when_compose_cannot_be_installed" test_fix_fails_when_compose_cannot_be_installed
    run_test "test_fix_restores_registry_login" test_fix_restores_registry_login
    run_test "test_fix_reports_failed_service_start_honestly" test_fix_reports_failed_service_start_honestly
    run_test "test_fix_recreates_logrotate_config" test_fix_recreates_logrotate_config
    run_test "test_fix_restores_helper_script_exec_bits" test_fix_restores_helper_script_exec_bits
    run_test "test_fix_adds_missing_secret_key_base" test_fix_adds_missing_secret_key_base
    run_test "test_fix_adds_missing_tls_domain_from_domain_file" test_fix_adds_missing_tls_domain_from_domain_file
    run_test "test_fix_copies_database_password_from_db_env" test_fix_copies_database_password_from_db_env
    run_test "test_fix_fails_on_database_password_mismatch" test_fix_fails_on_database_password_mismatch
    run_test "test_fix_survives_a_failed_repair" test_fix_survives_a_failed_repair
    run_test "test_fix_reports_clean_on_healthy_system" test_fix_reports_clean_on_healthy_system

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_fix_tests
fi
