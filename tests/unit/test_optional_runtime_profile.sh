#!/bin/bash

# Regression tests for the optional runtime service and its proxy (the `plugins` and `egress`
# services in both compose files). Released images do not contain /rails/bin/plugin-runtime, so
# a service that runs it restart-loops with exit 127. Both services are in the Compose profile
# `runtime`, which is off by default. The scripts turn it on (COMPOSE_PROFILES in .env) only for
# an image that contains the binary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

MANUAL_COMPOSE="$PROJECT_ROOT/docker-compose.manual.yml"
AUTO_COMPOSE="$PROJECT_ROOT/docker-compose.yml"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license" > "$SANDBOX_ROOT/.license"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.52.1" > "$SANDBOX_ROOT/.image"
    echo "BROADCAST_REGISTRY_URL=r.example" > "$SANDBOX_ROOT/.env"
    # docker run --entrypoint test <image> -x /rails/bin/plugin-runtime exits with
    # IMAGE_HAS_RUNTIME_RC: 0 = the file is there, 1 = it is not, 125 = docker failed
    harness_mock docker 'case "$*" in
  *"--entrypoint test"*) exit "${IMAGE_HAS_RUNTIME_RC:-1}" ;;
esac
exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# The services Compose starts for a file, with the given COMPOSE_PROFILES. Uses `docker compose
# config` when it is available; otherwise reads the YAML: a service is active when it has no
# `profiles:` key, or when one of its profiles is in the list.
active_services() {
    local file="$1" profiles="${2:-}"
    if docker compose version >/dev/null 2>&1; then
        local empty_dir
        empty_dir=$(mktemp -d)
        (cd "$empty_dir" && env -u COMPOSE_PROFILES COMPOSE_PROFILES="$profiles" \
            docker compose --project-directory "$empty_dir" -f "$file" config --services 2>/dev/null) | sort
        rm -rf "$empty_dir"
        return
    fi
    awk -v profiles=",$profiles," '
        /^services:/ { in_services = 1; next }
        /^[a-z]/ { in_services = 0 }
        in_services && /^  [a-z][a-z0-9_-]*:/ {
            if (name != "" && (prof == "" || active)) print name
            name = $1; sub(":", "", name); prof = ""; active = 0; next
        }
        in_services && /^    profiles:/ {
            prof = $0; sub(/.*profiles:[ ]*/, "", prof); gsub(/[][" ]/, "", prof)
            n = split(prof, list, ",")
            for (i = 1; i <= n; i++) if (index(profiles, "," list[i] ",")) active = 1
        }
        END { if (name != "" && (prof == "" || active)) print name }
    ' "$file" | sort
}

assert_compose_keeps_runtime_off_by_default() {
    local file="$1" services
    services=$(active_services "$file")
    assert_contains "$services" "app" "$(basename "$file"): app must start by default"
    assert_contains "$services" "job" "$(basename "$file"): job must start by default"
    assert_equals "" "$(echo "$services" | /usr/bin/grep -x -E 'plugins|egress')" \
        "$(basename "$file"): the optional runtime services must not start by default (released images have no bin/plugin-runtime)"

    services=$(active_services "$file" "runtime")
    assert_contains "$services" "plugins" "$(basename "$file"): the runtime profile must start the runtime service"
    assert_contains "$services" "egress" "$(basename "$file"): the runtime profile must start its proxy"
}

test_manual_compose_keeps_the_runtime_services_off_by_default() {
    assert_compose_keeps_runtime_off_by_default "$MANUAL_COMPOSE"
}

test_automatic_compose_keeps_the_runtime_services_off_by_default() {
    assert_compose_keeps_runtime_off_by_default "$AUTO_COMPOSE"
}

test_manual_env_sample_does_not_turn_the_runtime_on() {
    assert_equals "" "$(/usr/bin/grep -E '^[[:space:]]*COMPOSE_PROFILES=' "$PROJECT_ROOT/manual/app/.env.sample" || true)" \
        "the manual sample must not turn the optional runtime on"
}

test_sync_leaves_the_profile_off_for_an_image_without_the_binary() {
    local output rc=0
    output=$(sandbox_run "sync_plugin_runtime_profile" "export IMAGE_HAS_RUNTIME_RC=1") || rc=$?

    assert_equals "0" "$rc" "sync must succeed on a released image"
    harness_assert_called "docker run --rm --pull never --entrypoint test gitea.hostedapp.org/broadcast/broadcast:2.52.1 -x /rails/bin/plugin-runtime" \
        "sync must look for the binary in the selected image"
    assert_equals "" "$(/usr/bin/grep '^COMPOSE_PROFILES=' "$SANDBOX_ROOT/.env" || true)" "the profile must stay off"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_URL=r.example" "other settings must stay"
}

test_sync_turns_the_profile_off_and_removes_the_containers_when_the_binary_is_gone() {
    printf 'BROADCAST_REGISTRY_URL=r.example\nCOMPOSE_PROFILES=custom,runtime\n' > "$SANDBOX_ROOT/.env"
    sandbox_run "sync_plugin_runtime_profile" "export IMAGE_HAS_RUNTIME_RC=1" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "COMPOSE_PROFILES=custom" "an operator's own profile must stay"
    assert_equals "" "$(/usr/bin/grep '^COMPOSE_PROFILES=.*runtime' "$SANDBOX_ROOT/.env" || true)" "runtime must be removed"
    harness_assert_called "docker rm -f plugins egress" "a restart-looping container left from before must be removed"
}

test_sync_turns_the_profile_on_for_an_image_with_the_binary() {
    local output
    output=$(sandbox_run "sync_plugin_runtime_profile" "export IMAGE_HAS_RUNTIME_RC=0")

    assert_equals "1" "$(/usr/bin/grep -c '^COMPOSE_PROFILES=runtime$' "$SANDBOX_ROOT/.env")" "the profile must be on, once"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_URL=r.example" "other settings must stay"
    harness_assert_not_called "docker rm" "nothing must be removed"

    sandbox_run "sync_plugin_runtime_profile" "export IMAGE_HAS_RUNTIME_RC=0" >/dev/null
    assert_equals "1" "$(/usr/bin/grep -c 'runtime' "$SANDBOX_ROOT/.env")" "a second sync must not add it again"
}

test_sync_changes_nothing_when_docker_cannot_answer() {
    printf 'BROADCAST_REGISTRY_URL=r.example\nCOMPOSE_PROFILES=runtime\n' > "$SANDBOX_ROOT/.env"
    local rc=0
    sandbox_run "sync_plugin_runtime_profile" "export IMAGE_HAS_RUNTIME_RC=125" >/dev/null || rc=$?

    assert_equals "0" "$rc" "sync must never stop an upgrade"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "COMPOSE_PROFILES=runtime" "an unknown answer must keep the current setting"
    harness_assert_not_called "docker rm" "an unknown answer must not remove containers"
}

test_upgrade_on_a_released_image_leaves_the_runtime_off() {
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    touch "$SANDBOX_ROOT/app/.env"
    harness_mock crontab 'exit 0'
    local rc=0
    sandbox_run "_upgrade_continue 2.52.1" "export IMAGE_HAS_RUNTIME_RC=1" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade should succeed"
    assert_equals "" "$(/usr/bin/grep '^COMPOSE_PROFILES=.*runtime' "$SANDBOX_ROOT/.env" || true)" \
        "an upgrade to a released image must leave the runtime off"
    harness_assert_call_order \
        "su - broadcast" \
        "docker run --rm --pull never --entrypoint test gitea.hostedapp.org/broadcast/broadcast:2.52.1 -x /rails/bin/plugin-runtime" \
        "systemctl start broadcast"
}

test_upgrade_on_an_image_with_the_binary_turns_the_runtime_on() {
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    touch "$SANDBOX_ROOT/app/.env"
    harness_mock crontab 'exit 0'
    sandbox_run "_upgrade_continue 3.0.0" "export IMAGE_HAS_RUNTIME_RC=0" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "COMPOSE_PROFILES=runtime" "the upgrade must turn the runtime on"
}

test_install_checks_the_image_after_the_pull_and_before_the_start() {
    local root="$PROJECT_ROOT/scripts/install.sh" sync_line pull_line start_line
    sync_line=$(/usr/bin/grep -n "sync_plugin_runtime_profile" "$root" | head -1 | cut -d: -f1)
    pull_line=$(/usr/bin/grep -n "docker compose pull" "$root" | head -1 | cut -d: -f1)
    start_line=$(/usr/bin/grep -n "systemctl start broadcast" "$root" | head -1 | cut -d: -f1)
    local ordered=no
    [ -n "$sync_line" ] && [ -n "$pull_line" ] && [ -n "$start_line" ] \
        && [ "$pull_line" -lt "$sync_line" ] && [ "$sync_line" -lt "$start_line" ] && ordered=yes
    assert_equals "yes" "$ordered" "install must check the pulled image before it starts the service"
}

test_update_checks_the_image_after_it_pulls_new_scripts() {
    assert_contains "$(cat "$PROJECT_ROOT/scripts/update.sh")" "sync_plugin_runtime_profile" \
        "the nightly update delivers the compose file, so it must set the profile for the current image"
}

test_safe_mode_does_not_start_the_runtime_when_the_profile_is_off() {
    local rc=0
    sandbox_run "plugins safe-mode on" >/dev/null || rc=$?

    assert_equals "0" "$rc" "safe-mode must work without the runtime"
    harness_assert_called "docker compose up -d --force-recreate app job" "app and job must restart"
    harness_assert_not_called "app job plugins" "naming the service would turn its profile on and start a failing container"
}

test_logs_for_the_runtime_do_not_fail_when_the_profile_is_off() {
    local output rc=0
    output=$(sandbox_run "display_logs logs plugins") || rc=$?

    assert_equals "0" "$rc" "logs must not fail when the optional service is off"
    assert_contains "$output" "is off on this server" "the operator must see why there are no logs"
    harness_assert_not_called "docker logs" "there is no container to follow"
}

run_optional_runtime_profile_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_manual_compose_keeps_the_runtime_services_off_by_default" test_manual_compose_keeps_the_runtime_services_off_by_default
    run_test "test_automatic_compose_keeps_the_runtime_services_off_by_default" test_automatic_compose_keeps_the_runtime_services_off_by_default
    run_test "test_manual_env_sample_does_not_turn_the_runtime_on" test_manual_env_sample_does_not_turn_the_runtime_on
    run_test "test_sync_leaves_the_profile_off_for_an_image_without_the_binary" test_sync_leaves_the_profile_off_for_an_image_without_the_binary
    run_test "test_sync_turns_the_profile_off_and_removes_the_containers_when_the_binary_is_gone" test_sync_turns_the_profile_off_and_removes_the_containers_when_the_binary_is_gone
    run_test "test_sync_turns_the_profile_on_for_an_image_with_the_binary" test_sync_turns_the_profile_on_for_an_image_with_the_binary
    run_test "test_sync_changes_nothing_when_docker_cannot_answer" test_sync_changes_nothing_when_docker_cannot_answer
    run_test "test_upgrade_on_a_released_image_leaves_the_runtime_off" test_upgrade_on_a_released_image_leaves_the_runtime_off
    run_test "test_upgrade_on_an_image_with_the_binary_turns_the_runtime_on" test_upgrade_on_an_image_with_the_binary_turns_the_runtime_on
    run_test "test_install_checks_the_image_after_the_pull_and_before_the_start" test_install_checks_the_image_after_the_pull_and_before_the_start
    run_test "test_update_checks_the_image_after_it_pulls_new_scripts" test_update_checks_the_image_after_it_pulls_new_scripts
    run_test "test_safe_mode_does_not_start_the_runtime_when_the_profile_is_off" test_safe_mode_does_not_start_the_runtime_when_the_profile_is_off
    run_test "test_logs_for_the_runtime_do_not_fail_when_the_profile_is_off" test_logs_for_the_runtime_do_not_fail_when_the_profile_is_off

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_optional_runtime_profile_tests
fi
