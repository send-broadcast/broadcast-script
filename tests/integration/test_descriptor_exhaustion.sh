#!/bin/bash

# Descriptor-exhaustion reproduction, with a control.
#
# Customer incident 2026-08-15. A campaign send produced a burst of Amazon SES
# webhooks -- 1,253 of them in 21 seconds, roughly 65/second. The app ran out of
# file descriptors, Puma's listen loop began failing with
# "Errno::EMFILE: Too many open files - accept(2)", and the site served nothing
# but 502s for 31 minutes until an operator restarted it by hand.
#
# What makes it worth an executed test rather than a comment is the shape of the
# failure, which every liveness signal we had reported as healthy:
#
#   * the container never exited, so `restart: always` never fired
#   * `docker ps` showed it Up for the whole outage
#   * systemd recorded one continuous 3d23h run of broadcast.service
#
# So the assertion that matters is not "it broke". It is "it broke AND the
# container still reports Running" -- that combination is why nobody found out
# for half an hour, and why the fix had to be a descriptor limit rather than a
# restart policy.
#
# Scope worth knowing. This reproduces the failure MODE (sustained connection
# pressure exhausts descriptors; the stack stops serving; the container still
# looks healthy) against the real image, real Thruster, real Puma and a real
# database. It does not reproduce the exact production arithmetic: there, each
# webhook ALSO opened an outbound TLS connection to Amazon to re-download the
# SNS signing certificate, because the app built a new
# Aws::SNS::MessageVerifier per request. That multiplier is fixed in the
# broadcast repo and covered by a unit test there
# (test/controllers/webhooks/amazon_ses_controller_test.rb); reproducing it here
# would mean flooding Amazon's certificate endpoint from CI, which we are not
# going to do.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

source "$TEST_DIR/test_framework.sh"

NET=broadcast-fd-test-net
PG=broadcast-fd-test-pg
APP=broadcast-fd-test-app
HOST_PORT=39110

# Low enough that a sustained flood exhausts it, high enough that Rails can
# still boot (booting opens several hundred gem files).
CONTROL_NOFILE=1024
# The value docker-compose.yml now sets for app and job.
TREATMENT_NOFILE=65536

FLOOD_SOCKETS=2000
FLOOD_HOLD_SECONDS=25

APP_IMAGE=""

#######################
# Local helpers
#######################

# test_framework.sh provides assertions but no pass/fail logging or polling
# helper (the smoke suite carries its own). These are the minimum needed to
# report against run_test's TEST_FAILED contract.
log_pass() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

fail_test() {
    echo -e "${RED}  ✗ $1${NC}"
    TEST_FAILED=true
}

# Polls until the command succeeds. Returns non-zero on timeout so callers can
# fail loudly rather than proceeding against a stack that never came up.
wait_for() {
    local label="$1" cmd="$2" attempts="$3" delay="$4" i
    for ((i = 1; i <= attempts; i++)); do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay"
    done
    echo -e "${RED}  ✗ timed out waiting for: $label${NC}"
    return 1
}

#######################
# Environment
#######################

# The app image is pulled from a private registry, so a machine that has never
# run an install will not have it. Skip rather than fail: this suite is about
# the descriptor ceiling, not about registry access.
detect_app_image() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "SKIP: docker is not available"
        return 1
    fi

    APP_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
        grep -E '/broadcast(-arm)?:' | grep -v ':<none>' | sort -V | tail -1)

    if [ -z "$APP_IMAGE" ]; then
        echo "SKIP: no broadcast app image available locally (docker pull required)"
        return 1
    fi

    echo "Using app image: $APP_IMAGE"
    return 0
}

teardown_stack() {
    docker rm -f "$APP" "$PG" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}

start_postgres() {
    docker network create "$NET" >/dev/null 2>&1 || true
    docker run -d --name "$PG" --network "$NET" \
        -e POSTGRES_USER=broadcast \
        -e POSTGRES_PASSWORD=fdtestpw \
        -e POSTGRES_MULTIPLE_DATABASES=broadcast_primary_production,broadcast_queue_production,broadcast_cable_production \
        -v "$PROJECT_ROOT/db/init-scripts:/docker-entrypoint-initdb.d:ro" \
        postgres:17-alpine >/dev/null

    wait_for "postgres accepting connections" \
        "docker exec $PG pg_isready -U broadcast" 30 2 || return 1
}

# Boots the app exactly as production does: `thrust bin/rails server`, which is
# the image's own CMD, with Thruster on 80 in front of Puma on 3000.
start_app_with_nofile() {
    local limit="$1"
    docker rm -f "$APP" >/dev/null 2>&1 || true
    docker run -d --name "$APP" --network "$NET" \
        --ulimit "nofile=${limit}:${limit}" \
        -p "${HOST_PORT}:80" \
        -e RAILS_ENV=production \
        -e SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        -e DATABASE_HOST="$PG" \
        -e DATABASE_USERNAME=broadcast \
        -e DATABASE_PASSWORD=fdtestpw \
        "$APP_IMAGE" >/dev/null

    wait_for "app serving on :$HOST_PORT" \
        "curl -sf -o /dev/null -m 5 http://127.0.0.1:${HOST_PORT}/up" 90 3 || return 1
}

# Starts the app and returns IMMEDIATELY, without waiting for it to serve. The
# window between "container Running" and "Puma listening" is where an upgrade
# runs its migrations, and it is the window recovery must not act in.
start_app_booting() {
    docker rm -f "$APP" >/dev/null 2>&1 || true
    docker run -d --name "$APP" --network "$NET" \
        --ulimit "nofile=${TREATMENT_NOFILE}:${TREATMENT_NOFILE}" \
        -p "${HOST_PORT}:80" \
        -e RAILS_ENV=production \
        -e SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        -e DATABASE_HOST="$PG" \
        -e DATABASE_USERNAME=broadcast \
        -e DATABASE_PASSWORD=fdtestpw \
        "$APP_IMAGE" >/dev/null
}

# Runs the flood from a sibling container so the suite needs no Ruby on the
# host. Its own nofile must be generous or the flooder hits the ceiling first
# and never applies pressure to the app.
start_flood() {
    local hold="${1:-$FLOOD_HOLD_SECONDS}"
    docker run -d --rm --name broadcast-fd-test-flood --network "$NET" \
        --ulimit nofile=65536:65536 \
        -v "$TEST_DIR/fixtures/descriptor_flood.rb:/tmp/flood.rb:ro" \
        --entrypoint sh "$APP_IMAGE" \
        -c "cd /rails && ruby /tmp/flood.rb $APP 80 $FLOOD_SOCKETS $hold" >/dev/null
}

# scripts/recover.sh writes its state and log under /opt/broadcast. Rewrite
# those paths into a scratch directory so the test cannot touch a real install
# on the machine running it. Only the path constants change; the decision logic
# under test is the original text.
prepare_recover_script() {
    RECOVER_SANDBOX=$(mktemp -d)
    mkdir -p "$RECOVER_SANDBOX/logs"
    sed "s|/opt/broadcast|$RECOVER_SANDBOX|g" \
        "$PROJECT_ROOT/scripts/recover.sh" > "$RECOVER_SANDBOX/recover.sh"
}

# One cron tick. Real docker, real probe against the real container -- only the
# target container and the restart action are redirected at the test stack.
run_recover_tick() {
    (
        # shellcheck disable=SC1090
        source "$RECOVER_SANDBOX/recover.sh"
        RECOVERY_CONTAINER="$APP" RECOVERY_COMMAND="docker restart $APP" recover
    ) >>"$RECOVER_SANDBOX/recover-output.log" 2>&1 || true
}

stop_flood() {
    docker rm -f broadcast-fd-test-flood >/dev/null 2>&1 || true
}

app_is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = "true" ]
}

app_restart_count() {
    docker inspect -f '{{.RestartCount}}' "$APP" 2>/dev/null || echo "unknown"
}

app_logged_descriptor_exhaustion() {
    docker logs "$APP" 2>&1 | grep -qiE "too many open files|EMFILE"
}

serves_through_thruster() {
    curl -sf -o /dev/null -m 5 "http://127.0.0.1:${HOST_PORT}/up"
}

#######################
# Tests
#######################

# CONTROL: sustained pressure against a low ceiling reproduces the incident.
test_control_low_limit_exhausts_and_still_reports_healthy() {
    start_app_with_nofile "$CONTROL_NOFILE"

    local limit
    limit=$(docker exec "$APP" sh -c 'ulimit -n' 2>/dev/null | tr -d '[:space:]')
    assert_equals "$CONTROL_NOFILE" "$limit" \
        "the control's descriptor ceiling must actually be in effect, or the failure below proves nothing"

    start_flood
    sleep 12   # let the pressure build while the flooder holds its sockets

    if app_logged_descriptor_exhaustion; then
        log_pass "reproduced: the app logged descriptor exhaustion under load"
    else
        echo "FAIL: no descriptor exhaustion at nofile=$CONTROL_NOFILE -- the reproduction is not valid on this system"
        TEST_FAILED=true
    fi

    if serves_through_thruster; then
        echo "FAIL: still serving under the flood -- expected the stack to stop"
        TEST_FAILED=true
    else
        log_pass "reproduced: the site stopped serving (this is the customer's outage)"
    fi

    # THE POINT. Broken, and every signal we monitor says fine.
    if app_is_running; then
        log_pass "container still reports Running while serving nothing (why nobody noticed for 31 minutes)"
    else
        echo "FAIL: container exited -- then restart:always would have recovered it, which is not what happened"
        TEST_FAILED=true
    fi

    assert_equals "0" "$(app_restart_count)" \
        "Docker's restart policy must not have fired -- it never did during the incident"

    stop_flood
}

# TREATMENT: the ceiling docker-compose.yml now sets, same flood.
test_treatment_high_limit_survives_the_same_flood() {
    start_app_with_nofile "$TREATMENT_NOFILE"

    local limit
    limit=$(docker exec "$APP" sh -c 'ulimit -n' 2>/dev/null | tr -d '[:space:]')
    assert_equals "$TREATMENT_NOFILE" "$limit" \
        "the treatment's descriptor ceiling must actually be in effect"

    start_flood
    sleep 12

    if serves_through_thruster; then
        log_pass "still serving under the same flood that broke the control"
    else
        echo "FAIL: stopped serving at nofile=$TREATMENT_NOFILE -- the limit is not sufficient"
        TEST_FAILED=true
    fi

    if app_logged_descriptor_exhaustion; then
        echo "FAIL: descriptor exhaustion at nofile=$TREATMENT_NOFILE"
        TEST_FAILED=true
    else
        log_pass "no descriptor exhaustion at nofile=$TREATMENT_NOFILE"
    fi

    stop_flood
}

# The whole point of scripts/recover.sh: the stack is broken in exactly the way
# Docker cannot see, and something on the box notices and fixes it without a
# human. This is the 31 minutes, closed.
test_auto_recovery_restores_the_broken_stack() {
    prepare_recover_script
    start_app_with_nofile "$TREATMENT_NOFILE"

    # Freeze Puma rather than flood it. Two reasons, both learned the hard way.
    #
    # First, a flood at these limits exhausts THRUSTER before Puma, so Puma keeps
    # answering on :3000 and recovery correctly declines to act -- the earlier
    # version of this test failed for exactly that reason. Production was the
    # other way round because each webhook also opened an outbound connection to
    # Amazon, which is what put the pressure on Puma.
    #
    # Second, a flood is released eventually and the stack comes back on its own,
    # so "it is serving again" would pass without recover.sh doing anything. A
    # stopped process never unfreezes itself, which makes the final assertion
    # mean something.
    #
    # SIGSTOP reproduces the observable state that mattered: process alive,
    # container Running, RestartCount 0, nothing served. -x matches the process
    # NAME, because -f "puma" matches the shell running pkill and freezes it.
    docker exec "$APP" pkill -STOP -x ruby >/dev/null 2>&1 || true
    sleep 3

    if serves_through_thruster; then
        fail_test "the stack is still serving -- nothing to recover, the rest of this test would prove nothing"
        return 0
    fi
    log_pass "stack is broken and not serving (precondition)"

    if app_is_running && [ "$(app_restart_count)" = "0" ]; then
        log_pass "and Docker still reports it healthy: Running, RestartCount 0 (the 2026-08-15 signature)"
    else
        fail_test "the container exited or restarted; then Docker would have recovered it and recovery would be unnecessary"
    fi

    # Ticks inside the boot grace must NOT act. The container was started moments
    # ago by this test, so recovery must treat it as still booting no matter how
    # many failures it sees.
    local i
    for ((i = 1; i <= 9; i++)); do
        run_recover_tick
    done
    if grep -q "RECOVERY" "$RECOVER_SANDBOX/logs/recovery.log" 2>/dev/null; then
        fail_test "recovery acted while the container was still inside its boot grace"
    else
        log_pass "nine failed probes inside the boot grace did not trigger a restart"
    fi

    # Nothing has healed on its own, so what happens next is attributable.
    if serves_through_thruster; then
        fail_test "the stack recovered by itself before recovery acted; the next assertion would prove nothing"
        return 0
    fi

    # Past the grace, the same failure is judged genuine.
    run_recover_tick

    if grep -q "RECOVERY" "$RECOVER_SANDBOX/logs/recovery.log" 2>/dev/null; then
        log_pass "the probe past the boot grace triggered recovery and recorded it for admins"
    else
        fail_test "recovery never fired: $(tail -3 "$RECOVER_SANDBOX/recover-output.log" 2>/dev/null)"
    fi

    if wait_for "the stack to serve again after recovery" \
        "curl -sf -o /dev/null -m 5 http://127.0.0.1:${HOST_PORT}/up" 40 3; then
        log_pass "site is serving again, restored with no human involved (the 31 minutes, closed)"
    else
        fail_test "the stack never came back after recovery restarted it"
    fi

    rm -rf "$RECOVER_SANDBOX"
}

# A booting container is NOT a broken one. `upgrade` stops the service, and the
# app container then runs database migrations before Puma starts listening. To a
# probe that only asks "is Puma answering", that is indistinguishable from the
# outage -- so naive recovery restarts the stack mid-migration, turning a
# recovery feature into an upgrade hazard.
#
# The container is Running throughout, so a Running check does not separate the
# two cases. Only the container's age does.
test_does_not_restart_a_container_that_is_still_booting() {
    prepare_recover_script
    start_app_with_nofile "$TREATMENT_NOFILE"

    # Make the container young the way an upgrade does, then make Puma
    # unreachable the way an unfinished migration does. Waiting for the real
    # boot window is not reliable -- once migrations are already applied the app
    # comes up in under five seconds -- so freeze Puma to hold the state open.
    # From the probe's side this is byte-identical to a slow migration: young
    # container, Running, Puma not answering.
    docker restart "$APP" >/dev/null 2>&1 || true
    sleep 6
    docker exec "$APP" pkill -STOP -x ruby >/dev/null 2>&1 || true
    sleep 2

    if serves_through_thruster; then
        fail_test "Puma is still answering; there is no boot window to protect here"
        return 0
    fi
    log_pass "container is young and Running, Puma not answering (the migration window)"

    # Every tick inside the grace must decline to act, including well past the
    # three-failure threshold that governs a long-running container.
    local i
    for ((i = 1; i <= 5; i++)); do
        run_recover_tick
    done

    if grep -q "RECOVERY" "$RECOVER_SANDBOX/logs/recovery.log" 2>/dev/null; then
        fail_test "recovery restarted a freshly started container -- on a real upgrade this interrupts migrations mid-flight"
    else
        log_pass "left the freshly started container alone"
    fi

    rm -rf "$RECOVER_SANDBOX"
}

# The upgrade window, end to end. `upgrade` stops the service (compose down
# removes the containers) and then pulls a new image, which takes minutes. If
# recovery acts here it runs `systemctl restart broadcast` into a running
# upgrade.
test_does_not_act_while_the_container_is_absent() {
    prepare_recover_script
    docker rm -f "$APP" >/dev/null 2>&1 || true

    if docker inspect -f '{{.State.Running}}' "$APP" >/dev/null 2>&1; then
        fail_test "the container is still present; this test needs it gone"
        return 0
    fi
    log_pass "no app container at all (the compose down + image pull window)"

    local i
    for ((i = 1; i <= 6; i++)); do
        run_recover_tick
    done

    if grep -q "RECOVERY" "$RECOVER_SANDBOX/logs/recovery.log" 2>/dev/null; then
        fail_test "recovery fired with no container present -- this restarts the service into a running upgrade"
    else
        log_pass "left the absent container alone (upgrade owns that window)"
    fi

    rm -rf "$RECOVER_SANDBOX"
}

# The limit compose declares must survive into the running container. The unit
# test asserts the YAML says "nofile"; this asserts the kernel agrees.
test_compose_declared_limit_reaches_the_container() {
    local declared
    declared=$(grep -A2 'nofile:' "$PROJECT_ROOT/docker-compose.yml" | grep -m1 'soft:' | awk '{print $2}')
    assert_equals "$TREATMENT_NOFILE" "$declared" \
        "docker-compose.yml must declare the same limit this suite proves sufficient"
}

#######################
# Runner
#######################

run_descriptor_exhaustion_tests() {
    echo "Running Descriptor Exhaustion Tests"
    echo "==================================="

    if ! detect_app_image; then
        echo "Suite skipped."
        return 0
    fi

    init_test_framework
    trap 'stop_flood; teardown_stack' EXIT

    start_postgres

    run_test "test_compose_declared_limit_reaches_the_container" test_compose_declared_limit_reaches_the_container
    run_test "test_control_low_limit_exhausts_and_still_reports_healthy" test_control_low_limit_exhausts_and_still_reports_healthy
    run_test "test_treatment_high_limit_survives_the_same_flood" test_treatment_high_limit_survives_the_same_flood
    run_test "test_auto_recovery_restores_the_broken_stack" test_auto_recovery_restores_the_broken_stack
    run_test "test_does_not_restart_a_container_that_is_still_booting" test_does_not_restart_a_container_that_is_still_booting
    run_test "test_does_not_act_while_the_container_is_absent" test_does_not_act_while_the_container_is_absent

    local result
    print_test_summary
    result=$?

    teardown_stack
    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_descriptor_exhaustion_tests
fi
