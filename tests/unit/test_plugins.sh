#!/bin/bash

# Unit tests for the plugins command (scripts/plugins.sh), written TDD-first. Safe mode turns every
# plugin off without the web UI: BROADCAST_PLUGINS_SAFE_MODE in /opt/broadcast/.env, which Compose
# reads for interpolation (the plugins container never reads app/.env). ensure_plugin_runtime_secret
# creates the secret that the plugin runtime, the egress proxy and Rails share.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license" > "$SANDBOX_ROOT/.license"
}

teardown_sandbox() {
    harness_destroy_sandbox
}

GUARD_STUBS='
includeDependencies() { :; }
check_root() { :; }
check_installation_domain() { :; }
check_license() { :; }
'

test_safe_mode_on_writes_the_flag_and_recreates_the_services() {
    # The runtime profile is on (an image that contains the runtime), so the runtime service restarts too
    printf 'BROADCAST_REGISTRY_URL=r.example\nCOMPOSE_PROFILES=runtime\n' > "$SANDBOX_ROOT/.env"
    local output rc=0
    output=$(sandbox_run "plugins safe-mode on") || rc=$?

    assert_equals "0" "$rc" "safe-mode on should succeed"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_PLUGINS_SAFE_MODE=1" ".env should turn safe mode on"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_URL=r.example" "other settings in .env must stay"
    harness_assert_called "docker compose up -d --force-recreate app job plugins" "app, job and plugins must restart to read it"
    assert_contains "$output" "Safe mode is on" "the operator should see the new state"
}

test_safe_mode_off_clears_the_flag() {
    printf 'BROADCAST_PLUGINS_SAFE_MODE=1\nCOMPOSE_PROFILES=runtime\n' > "$SANDBOX_ROOT/.env"
    local rc=0
    sandbox_run "plugins safe-mode off" >/dev/null || rc=$?

    assert_equals "0" "$rc" "safe-mode off should succeed"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_PLUGINS_SAFE_MODE=0" ".env should turn safe mode off"
    assert_equals "1" "$(/usr/bin/grep -c BROADCAST_PLUGINS_SAFE_MODE "$SANDBOX_ROOT/.env")" "the key must appear once"
    harness_assert_called "docker compose up -d --force-recreate app job plugins" "the services must restart"
}

test_safe_mode_status_reads_the_file() {
    echo "BROADCAST_PLUGINS_SAFE_MODE=1" > "$SANDBOX_ROOT/.env"
    local output
    output=$(sandbox_run "plugins safe-mode status")

    assert_contains "$output" "Safe mode is on" "status should report on"
    harness_assert_not_called "docker" "status changes nothing"
}

test_unknown_subcommand_shows_usage() {
    local output rc=0
    output=$(sandbox_run "plugins safe-mode maybe") || rc=$?

    assert_equals "1" "$rc" "an unknown value must exit 1"
    assert_contains "$output" "safe-mode on|off|status" "usage should list the values"
    harness_assert_not_called "docker" "nothing should restart"
}

test_ensure_secret_creates_64_hex_characters_once() {
    sandbox_run "ensure_plugin_runtime_secret" >/dev/null
    local secret
    secret=$(cat "$SANDBOX_ROOT/secrets/plugin_runtime_secret")
    local shape=no
    [[ "$secret" =~ ^[0-9a-f]{64}$ ]] && shape=yes
    assert_equals "yes" "$shape" "the secret should be 64 hex characters"

    sandbox_run "ensure_plugin_runtime_secret" >/dev/null
    assert_equals "$secret" "$(cat "$SANDBOX_ROOT/secrets/plugin_runtime_secret")" "an existing secret must be kept"
}

# .env holds the registry password. safe-mode changes one line; every other line stays. The file's
# owner and mode, and a failed write, are in tests/unit/test_env_file_modes.sh.
assert_safe_mode_keeps_the_env_file() {
    local value="$1"
    harness_fake_ownership
    harness_mock id 'exit 0'
    printf 'BROADCAST_REGISTRY_URL=r.example\nBROADCAST_REGISTRY_PASSWORD=pw\n' > "$SANDBOX_ROOT/.env"

    sandbox_run "plugins safe-mode $value" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_URL=r.example" "the registry URL must stay"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw" "the registry login must stay"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "safe-mode $value must leave .env private"
}

test_safe_mode_on_keeps_the_owner_and_mode_of_env() {
    assert_safe_mode_keeps_the_env_file on
}

test_safe_mode_off_keeps_the_owner_and_mode_of_env() {
    assert_safe_mode_keeps_the_env_file off
}

# An existing secret with the wrong owner (a broad chown -R of /opt/broadcast) or mode must be
# repaired: the containers read it as uid 1000, and ensure_plugin_runtime_secret used to return as
# soon as the file existed.
wrong_owner_secret() {
    harness_fake_ownership
    mkdir -p "$SANDBOX_ROOT/secrets"
    echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$SANDBOX_ROOT/secrets/plugin_runtime_secret"
    /bin/chmod 644 "$SANDBOX_ROOT/secrets/plugin_runtime_secret"
    printf "R\tbroadcast:broadcast\t%s\n" "$SANDBOX_ROOT" >> "$SANDBOX_ROOT/.fake_owners"
}

test_upgrade_repairs_the_owner_and_mode_of_an_existing_secret() {
    wrong_owner_secret
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.52.1" > "$SANDBOX_ROOT/.image"
    touch "$SANDBOX_ROOT/app/.env"
    harness_mock crontab 'exit 0'
    local rc=0
    sandbox_run "_upgrade_continue 2.52.1" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade should succeed"
    assert_equals "1000:1000 400" "$(harness_owner_and_mode "$SANDBOX_ROOT/secrets/plugin_runtime_secret")" \
        "upgrade must give the secret back to the container uid with mode 0400"
    assert_equals "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
        "$(cat "$SANDBOX_ROOT/secrets/plugin_runtime_secret")" "the secret itself must not change"
}

test_update_repairs_the_owner_and_mode_of_an_existing_secret() {
    wrong_owner_secret
    local rc=0
    sandbox_run "update" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the update should succeed"
    assert_equals "1000:1000 400" "$(harness_owner_and_mode "$SANDBOX_ROOT/secrets/plugin_runtime_secret")" \
        "the nightly update must give the secret back to the container uid with mode 0400"
}

test_main_routes_plugins_with_arguments() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
plugins() { echo \"PLUGINS_CALLED argc=\$# sub=\${1:-none} arg=\${2:-none}\"; }
main plugins safe-mode on")

    assert_contains "$output" "PLUGINS_CALLED argc=2 sub=safe-mode arg=on" "main must forward the subcommand"
}

test_help_mentions_plugins() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
main help")

    assert_contains "$output" "plugins safe-mode" "help should list the plugins command"
}

test_logs_accepts_plugins_and_egress() {
    echo "COMPOSE_PROFILES=runtime" > "$SANDBOX_ROOT/.env"
    sandbox_run "display_logs logs plugins" >/dev/null
    harness_assert_called "docker logs --follow plugins" "logs plugins should follow the plugins container"
    sandbox_run "display_logs logs egress" >/dev/null
    harness_assert_called "docker logs --follow egress" "logs egress should follow the egress container"
}

# install, upgrade and the nightly update create the secret, so the plugins and egress services
# (which wait for it) start; Broadcast itself starts without it
test_install_upgrade_and_update_create_the_secret() {
    local root="$SCRIPT_DIR/../.."
    assert_contains "$(cat "$root/scripts/install.sh")" "ensure_plugin_runtime_secret" "install should create the secret"
    assert_contains "$(cat "$root/scripts/upgrade.sh")" "ensure_plugin_runtime_secret" "upgrade should create the secret"
    assert_contains "$(cat "$root/scripts/update.sh")" "ensure_plugin_runtime_secret" "the nightly update should create the secret"

    local upgrade_secret_line start_line
    upgrade_secret_line=$(/usr/bin/grep -n "ensure_plugin_runtime_secret" "$root/scripts/upgrade.sh" | head -1 | cut -d: -f1)
    start_line=$(/usr/bin/grep -n "systemctl start broadcast" "$root/scripts/upgrade.sh" | tail -1 | cut -d: -f1)
    local before=no
    [ -n "$upgrade_secret_line" ] && [ -n "$start_line" ] && [ "$upgrade_secret_line" -lt "$start_line" ] && before=yes
    assert_equals "yes" "$before" "upgrade must create the secret before it starts the service"
}

run_plugins_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_safe_mode_on_writes_the_flag_and_recreates_the_services" test_safe_mode_on_writes_the_flag_and_recreates_the_services
    run_test "test_safe_mode_off_clears_the_flag" test_safe_mode_off_clears_the_flag
    run_test "test_safe_mode_status_reads_the_file" test_safe_mode_status_reads_the_file
    run_test "test_unknown_subcommand_shows_usage" test_unknown_subcommand_shows_usage
    run_test "test_ensure_secret_creates_64_hex_characters_once" test_ensure_secret_creates_64_hex_characters_once
    run_test "test_safe_mode_on_keeps_the_owner_and_mode_of_env" test_safe_mode_on_keeps_the_owner_and_mode_of_env
    run_test "test_safe_mode_off_keeps_the_owner_and_mode_of_env" test_safe_mode_off_keeps_the_owner_and_mode_of_env
    run_test "test_upgrade_repairs_the_owner_and_mode_of_an_existing_secret" test_upgrade_repairs_the_owner_and_mode_of_an_existing_secret
    run_test "test_update_repairs_the_owner_and_mode_of_an_existing_secret" test_update_repairs_the_owner_and_mode_of_an_existing_secret
    run_test "test_main_routes_plugins_with_arguments" test_main_routes_plugins_with_arguments
    run_test "test_help_mentions_plugins" test_help_mentions_plugins
    run_test "test_logs_accepts_plugins_and_egress" test_logs_accepts_plugins_and_egress
    run_test "test_install_upgrade_and_update_create_the_secret" test_install_upgrade_and_update_create_the_secret

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_plugins_tests
fi
