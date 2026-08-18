#!/bin/bash

# Container-backed tests for recover.sh's guards and the fd metrics.
#
# The unit suite covers these with mocked docker/flock/timeout, which is fast
# and deterministic but proves nothing about the commands themselves. Two of
# those unit tests originally passed BEFORE the feature existed: flock and
# timeout do not exist on macOS, so `set -e` aborted the script early and "no
# restart happened" looked like success. Mocks cannot catch a production command
# that is malformed, unsupported by the image, or wrong about /proc.
#
# So these run the real commands against real containers. Where a guard needs a
# binary the host may not have (flock, timeout — absent on macOS, present on the
# Linux CI runner), the test SKIPS loudly rather than passing quietly.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

source "$TEST_DIR/test_framework.sh"

APP=broadcast-rh-test-app
NOCURL=broadcast-rh-test-nocurl
APP_IMAGE=""
RECOVER_SANDBOX=""

log_pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail_test() { echo -e "${RED}  ✗ $1${NC}"; TEST_FAILED=true; }
log_skip() { echo -e "${YELLOW}  ⊘ SKIP: $1${NC}"; }

detect_app_image() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "SKIP: docker is not available"; return 1
    fi
    APP_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
        grep -E '/broadcast(-arm)?:' | grep -v ':<none>' | sort -V | tail -1)
    [ -z "$APP_IMAGE" ] && { echo "SKIP: no broadcast app image available locally"; return 1; }
    echo "Using app image: $APP_IMAGE"; return 0
}

teardown_stack() { docker rm -f "$APP" "$NOCURL" >/dev/null 2>&1 || true; }

# The app image with a known ulimit, running something inert. No database is
# needed: these tests probe the container, they do not exercise Rails.
start_app_container() {
    local limit="$1"
    docker rm -f "$APP" >/dev/null 2>&1 || true
    docker run -d --name "$APP" --ulimit "nofile=${limit}:${limit}" \
        --entrypoint sh "$APP_IMAGE" -c 'sleep 600' >/dev/null
}

prepare_recover_script() {
    RECOVER_SANDBOX=$(mktemp -d)
    mkdir -p "$RECOVER_SANDBOX/logs"
    sed "s|/opt/broadcast|$RECOVER_SANDBOX|g" \
        "$PROJECT_ROOT/scripts/recover.sh" > "$RECOVER_SANDBOX/recover.sh"
}

run_recover_tick() {
    local container="$1"
    (
        # shellcheck disable=SC1090
        source "$RECOVER_SANDBOX/recover.sh"
        RECOVERY_CONTAINER="$container" \
        RECOVERY_COMMAND="echo RESTART_WOULD_RUN >> $RECOVER_SANDBOX/restarts.log" recover
    ) >>"$RECOVER_SANDBOX/out.log" 2>&1 || true
}

restarts_logged() { grep -c "RESTART_WOULD_RUN" "$RECOVER_SANDBOX/restarts.log" 2>/dev/null || echo 0; }

# The value docker-compose.yml declares for the app service.
declared_nofile() {
    grep -A3 'nofile:' "$PROJECT_ROOT/docker-compose.yml" | grep -m1 'soft:' | awk '{print $2}'
}

#######################
# Tests
#######################

# The unit test asserts monitor.sh's JSON fields. It cannot tell whether the
# command inside `docker exec` is valid for this image -- an earlier version
# carried a stray token that would have run as a bogus command in every
# customer's container, and the mocked test passed happily.
test_fd_count_command_works_against_the_real_image() {
    start_app_container 65536
    sleep 2

    local count
    count=$(docker exec "$APP" sh -c 'ls /proc/[0-9]*/fd 2>/dev/null | grep -c .' 2>/dev/null | tail -1)

    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
        log_pass "counted $count open descriptors in a real container"
    else
        fail_test "fd count command returned '$count' against the real image"
    fi
}

# Replaces a genuinely vacuous unit assertion whose comment claimed "this
# asserts the kernel agrees" while only grepping YAML. The kernel is only ever
# consulted through docker's --ulimit, so this consults it.
test_declared_compose_limit_is_what_the_kernel_gives_the_process() {
    local declared
    declared=$(declared_nofile)
    assert_equals "65536" "$declared" "docker-compose.yml must declare the limit this suite verifies"

    start_app_container "$declared"
    sleep 2

    local actual
    actual=$(docker exec "$APP" sh -c 'ulimit -n' 2>/dev/null | tail -1)
    assert_equals "$declared" "$actual" \
        "the limit declared in compose must be the limit a process in the container actually gets"
}

# The one path where recover.sh could restart a perfectly healthy box forever.
# postgres:17-alpine ships no curl, so this is the real 127, not a mocked one.
test_recovery_skips_a_container_with_no_probe_binary() {
    prepare_recover_script
    docker rm -f "$NOCURL" >/dev/null 2>&1 || true
    docker run -d --name "$NOCURL" --entrypoint sh postgres:17-alpine -c 'sleep 600' >/dev/null
    sleep 2

    if docker exec "$NOCURL" sh -c 'command -v curl' >/dev/null 2>&1; then
        log_skip "this image unexpectedly has curl; the 127 path cannot be exercised"
        rm -rf "$RECOVER_SANDBOX"; return 0
    fi

    local i
    for ((i = 1; i <= 6; i++)); do run_recover_tick "$NOCURL"; done

    assert_equals "0" "$(restarts_logged)" \
        "a container without curl must never be restarted -- the probe is broken, not the app"
    if grep -q "cannot probe" "$RECOVER_SANDBOX/out.log" 2>/dev/null; then
        log_pass "warned that the probe binary is missing instead of acting"
    else
        fail_test "no warning explaining why the probe failed: $(tail -2 "$RECOVER_SANDBOX/out.log" 2>/dev/null)"
    fi
    rm -rf "$RECOVER_SANDBOX"
}

# The flock and timeout guards, exercised inside a Linux container.
#
# These used to run on the host and skip on macOS, which meant shipping guards
# whose tests had never executed anywhere but CI. Running them in the container
# makes them identical on every machine. The fixture explains the docker stub it
# uses and why that trade is the right one.
run_guard_checks_in_container() {
    docker run --rm \
        -v "$PROJECT_ROOT:/src:ro" \
        --entrypoint bash "$APP_IMAGE" \
        /src/tests/fixtures/recovery_guard_checks.sh 2>/dev/null
}

guard_result() {
    echo "$GUARD_OUTPUT" | grep -oE "^RESULT $1=.*" | cut -d= -f2 | tr -d '[:space:]'
}

test_guards_hold_on_linux() {
    GUARD_OUTPUT=$(run_guard_checks_in_container)

    if [ -z "$GUARD_OUTPUT" ]; then
        fail_test "the in-container guard checks produced no output"
        return 0
    fi

    # Recovery must still fire when nothing is contending -- a guard that
    # simply never acts would satisfy the two assertions below.
    local primed held free elapsed
    primed=$(guard_result primed_restarts)
    held=$(guard_result lock_held_restarts)
    free=$(guard_result lock_free_restarts)
    elapsed=$(guard_result wedged_elapsed)

    # The three counts describe the SAME tick under three conditions, so the
    # lock is the only variable between the second and the third.
    assert_equals "0" "$primed" \
        "two failures must not act yet, or the ticks below prove nothing about locking"
    assert_equals "0" "$held" \
        "while another tick holds the lock, this one must do nothing -- otherwise overlapping cron ticks double-restart"
    assert_equals "1" "$free" \
        "the same tick with the lock free MUST act, or the assertion above passes for the wrong reason"

    if [ -n "$elapsed" ] && [ "$elapsed" -lt 60 ] 2>/dev/null; then
        log_pass "a probe that hangs for 120s was cut off after ${elapsed}s"
    else
        fail_test "wedged probe ran for '${elapsed}'s; the docker call is not bounded"
    fi
}

#######################
# Runner
#######################

run_recovery_hardening_tests() {
    echo "Running Recovery Hardening Tests (containers)"
    echo "============================================="

    if ! detect_app_image; then echo "Suite skipped."; return 0; fi

    init_test_framework
    trap 'teardown_stack' EXIT

    run_test "test_fd_count_command_works_against_the_real_image" test_fd_count_command_works_against_the_real_image
    run_test "test_declared_compose_limit_is_what_the_kernel_gives_the_process" test_declared_compose_limit_is_what_the_kernel_gives_the_process
    run_test "test_recovery_skips_a_container_with_no_probe_binary" test_recovery_skips_a_container_with_no_probe_binary
    run_test "test_guards_hold_on_linux" test_guards_hold_on_linux

    local result
    print_test_summary
    result=$?

    teardown_stack
    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_recovery_hardening_tests
fi
