#!/bin/bash

# Cross-file consistency: every container/service name that a script passes to
# docker must actually exist in docker-compose.yml. Scripts and the compose
# file are edited independently, and a renamed service/container silently
# breaks whatever script still uses the old name — restore once targeted a
# container ("broadcast-postgres") that no compose file defines, which aborted
# a real restore midway with services stopped. This test makes that
# relationship an executed assertion.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"

COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

# Top-level service names in docker-compose.yml (two-space indented keys)
compose_services() {
    awk '/^services:/{in_s=1; next} /^[^ ]/{in_s=0} in_s && /^  [a-zA-Z0-9_-]+:$/{gsub(/[ :]/, ""); print}' "$COMPOSE_FILE"
}

# Explicit container_name values in docker-compose.yml
compose_container_names() {
    grep -E '^\s*container_name:' "$COMPOSE_FILE" | awk '{print $2}'
}

# Names scripts pass to docker-compose subcommands (exec/run/cp), which
# resolve SERVICE names. Skips shell variables.
script_service_references() {
    grep -rhoE 'docker compose (exec( -T)?|run --rm|cp) [a-zA-Z][a-zA-Z0-9_-]*' \
        "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/broadcast.sh" 2>/dev/null |
        awk '{print $NF}' | sort -u
}

# Names scripts pass to plain docker commands (cp targets like "name:/path",
# logs/exec by container), which resolve CONTAINER names. Skips variables.
script_container_references() {
    {
        grep -rhoE 'docker cp [^ ]+ [a-zA-Z][a-zA-Z0-9_-]*:' \
            "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/broadcast.sh" 2>/dev/null |
            sed -E 's/.* ([a-zA-Z][a-zA-Z0-9_-]*):$/\1/'
        grep -rhoE 'docker (logs( --follow| -f)?|exec) [a-zA-Z][a-zA-Z0-9_-]*' \
            "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/broadcast.sh" 2>/dev/null |
            awk '{print $NF}'
    } | sort -u
}

test_compose_file_parses() {
    local services
    services=$(compose_services)
    assert_contains "$services" "postgres" "compose file should define a postgres service"
    assert_contains "$services" "app" "compose file should define an app service"
}

test_service_references_exist_in_compose() {
    local services refs ref
    services=$(compose_services)

    refs=$(script_service_references)
    assert_not_equals "" "$refs" "expected scripts to reference at least one compose service"

    for ref in $refs; do
        if ! echo "$services" | grep -qx "$ref"; then
            assert_equals "a service in docker-compose.yml" "$ref" \
                "scripts use 'docker compose ... $ref' but no such service exists"
        fi
    done
}

test_container_references_exist_in_compose() {
    local names refs ref
    names=$(compose_container_names)

    refs=$(script_container_references)

    for ref in $refs; do
        if ! echo "$names" | grep -qx "$ref"; then
            assert_equals "a container_name in docker-compose.yml" "$ref" \
                "scripts target container '$ref' but no such container_name exists"
        fi
    done
}

# Incident (2026-08-03): `pull_policy: always` made `docker compose up`
# contact the registry before starting containers, so a reboot where the
# network came up after docker left Broadcast down (exit 18, then systemd
# rate-limit lockout) — despite perfectly good images in the local cache.
# Boot must never depend on the registry: upgrades pull explicitly
# (upgrade.sh runs `docker compose pull`), so `up` only needs `missing`.
test_compose_up_must_not_depend_on_the_registry() {
    local file always_count missing_count
    for file in "$COMPOSE_FILE" "$PROJECT_ROOT/docker-compose.manual.yml"; do
        always_count=$(/usr/bin/grep -c "pull_policy: always" "$file" || true)
        assert_equals "0" "$always_count" \
            "$(basename "$file"): pull_policy: always makes boot fail when the registry is unreachable"

        missing_count=$(/usr/bin/grep -c "pull_policy: missing" "$file" || true)
        assert_equals "2" "$missing_count" \
            "$(basename "$file"): app and job should pin pull_policy: missing so up never pulls"
    done
}

# Postmortem friction 9a (firstborngroup): the systemd unit's ExecStop runs
# `docker compose down`, which REMOVES containers and destroys their
# json-file logs — the standard remediation erases the incident's evidence.
# Production logging must go to journald, which survives container removal
# (`journalctl CONTAINER_NAME=app`). `docker logs`/streaming keep working
# via Docker's default dual-logging cache. The manual/dev compose file
# deliberately stays on json-file: macOS Docker has no journald.
test_production_compose_logs_to_journald() {
    local journald_count json_count
    journald_count=$(/usr/bin/grep -c 'driver: "journald"' "$COMPOSE_FILE" || true)
    assert_equals "3" "$journald_count" \
        "app, job and postgres must log to journald so logs survive compose down"

    json_count=$(/usr/bin/grep -c 'driver: "json-file"' "$COMPOSE_FILE" || true)
    assert_equals "0" "$json_count" \
        "no production service may keep the json-file driver (logs die with the container)"

    json_count=$(/usr/bin/grep -c 'driver: "json-file"' "$PROJECT_ROOT/docker-compose.manual.yml" || true)
    assert_not_equals "0" "$json_count" \
        "the manual/dev compose file must stay on json-file (no journald on macOS)"
}

run_docker_reference_tests() {
    echo "Running Docker Reference Consistency Tests"
    echo "=========================================="

    init_test_framework

    run_test "test_compose_file_parses" test_compose_file_parses
    run_test "test_service_references_exist_in_compose" test_service_references_exist_in_compose
    run_test "test_container_references_exist_in_compose" test_container_references_exist_in_compose
    run_test "test_compose_up_must_not_depend_on_the_registry" test_compose_up_must_not_depend_on_the_registry
    run_test "test_production_compose_logs_to_journald" test_production_compose_logs_to_journald

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_docker_reference_tests
fi
