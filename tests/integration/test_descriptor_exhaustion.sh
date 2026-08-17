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

# Runs the flood from a sibling container so the suite needs no Ruby on the
# host. Its own nofile must be generous or the flooder hits the ceiling first
# and never applies pressure to the app.
start_flood() {
    docker run -d --rm --name broadcast-fd-test-flood --network "$NET" \
        --ulimit nofile=65536:65536 \
        -v "$TEST_DIR/fixtures/descriptor_flood.rb:/tmp/flood.rb:ro" \
        --entrypoint sh "$APP_IMAGE" \
        -c "cd /rails && ruby /tmp/flood.rb $APP 80 $FLOOD_SOCKETS $FLOOD_HOLD_SECONDS" >/dev/null
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
