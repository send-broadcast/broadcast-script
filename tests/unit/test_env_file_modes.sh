#!/bin/bash

# The env files hold secrets: /opt/broadcast/.env the registry login, app/.env the database password
# and the Rails keys, db/.env the database password. Only their owner may read them (mode 600). The
# broadcast user owns them: broadcast.service runs `docker compose` as that user, and Compose reads
# all three. install, validate_license, upgrade and the nightly update set the mode; existing servers
# get it from the nightly update. The owner stays, except a file that root replaced: the broadcast
# user could not read it at mode 600, so it goes back to broadcast:broadcast.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

ENV_FILES=".env app/.env db/.env"

setup_sandbox() {
    harness_make_sandbox
    harness_fake_ownership
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license" > "$SANDBOX_ROOT/.license"
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.0.0" > "$SANDBOX_ROOT/.image"
    printf 'BROADCAST_REGISTRY_URL=r.example\nBROADCAST_REGISTRY_LOGIN=l\nBROADCAST_REGISTRY_PASSWORD=pw\n' > "$SANDBOX_ROOT/.env"
    printf 'DATABASE_PASSWORD=dbpw\nACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=a\nACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=b\nACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=c\n' > "$SANDBOX_ROOT/app/.env"
    printf 'POSTGRES_PASSWORD=dbpw\n' > "$SANDBOX_ROOT/db/.env"
    local f
    for f in $ENV_FILES; do
        /bin/chmod 644 "$SANDBOX_ROOT/$f"
    done
    # As install leaves them: everything in /opt/broadcast belongs to the broadcast user
    printf "R\tbroadcast:broadcast\t%s\n" "$SANDBOX_ROOT" >> "$SANDBOX_ROOT/.fake_owners"
    harness_mock id 'exit 0'
    harness_mock crontab 'exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

assert_env_files_are_private() {
    local why="$1" f
    for f in $ENV_FILES; do
        assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/$f")" "$why: $f"
    done
}

test_upgrade_makes_the_env_files_readable_by_their_owner_only() {
    local rc=0
    sandbox_run "_upgrade_continue 2.1.0" "umask 022" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade should succeed"
    assert_env_files_are_private "upgrade must set mode 600 and keep the owner"
}

test_nightly_update_makes_the_env_files_readable_by_their_owner_only() {
    local rc=0
    sandbox_run "update" "umask 022" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the update should succeed"
    assert_env_files_are_private "the nightly update must repair existing servers"
}

test_files_with_the_right_owner_keep_it() {
    sandbox_run "secure_env_files" "umask 022" >/dev/null

    if /usr/bin/grep -q "^chown" "$SANDBOX_CALLS"; then
        echo "Assertion failed: chown ran although the broadcast user owns the files"
        /usr/bin/grep "^chown" "$SANDBOX_CALLS"
        TEST_FAILED=true
        return 1
    fi
}

test_a_file_that_root_replaced_goes_back_to_the_broadcast_user() {
    printf -- "-\troot:root\t%s\n" "$SANDBOX_ROOT/.env" >> "$SANDBOX_ROOT/.fake_owners"
    sandbox_run "secure_env_files" "umask 022" >/dev/null

    assert_env_files_are_private "at mode 600 a root-owned .env would stop docker compose as the broadcast user"
}

test_secure_env_files_skips_missing_files() {
    rm -f "$SANDBOX_ROOT/db/.env"
    local rc=0
    sandbox_run "secure_env_files" "umask 022" >/dev/null || rc=$?

    assert_equals "0" "$rc" "a missing file is not an error"
    assert_file_not_exists "$SANDBOX_ROOT/db/.env" "a missing file must not be created"
}

test_validate_license_writes_the_registry_login_in_place_at_mode_600() {
    local before after rc=0
    before=$("$SANDBOX_ROOT/mocks/stat" -c "%i" "$SANDBOX_ROOT/.env")
    sandbox_run "validate_license" "umask 022
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='{\"registry_url\":\"r2.example\",\"registry_login\":\"l2\",\"registry_password\":\"pw2\"}'" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the license check should succeed"
    after=$("$SANDBOX_ROOT/mocks/stat" -c "%i" "$SANDBOX_ROOT/.env")
    assert_equals "$before" "$after" "validate_license must rewrite .env in place, so its owner stays"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "the registry password must be private"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw2" "the new login must be written"
    assert_equals "1" "$(/usr/bin/grep -c '^BROADCAST_REGISTRY_PASSWORD=' "$SANDBOX_ROOT/.env")" "the login must appear once"
}

test_validate_license_creates_a_new_env_at_mode_600() {
    rm -f "$SANDBOX_ROOT/.env"
    sandbox_run "validate_license" "umask 022
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='{\"registry_url\":\"r2.example\",\"registry_login\":\"l2\",\"registry_password\":\"pw2\"}'" >/dev/null

    assert_equals "600" "$("$SANDBOX_ROOT/mocks/stat" -c "%a" "$SANDBOX_ROOT/.env")" "a new .env must never be readable by others"
}

run_env_file_modes_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_upgrade_makes_the_env_files_readable_by_their_owner_only" test_upgrade_makes_the_env_files_readable_by_their_owner_only
    run_test "test_nightly_update_makes_the_env_files_readable_by_their_owner_only" test_nightly_update_makes_the_env_files_readable_by_their_owner_only
    run_test "test_files_with_the_right_owner_keep_it" test_files_with_the_right_owner_keep_it
    run_test "test_a_file_that_root_replaced_goes_back_to_the_broadcast_user" test_a_file_that_root_replaced_goes_back_to_the_broadcast_user
    run_test "test_secure_env_files_skips_missing_files" test_secure_env_files_skips_missing_files
    run_test "test_validate_license_writes_the_registry_login_in_place_at_mode_600" test_validate_license_writes_the_registry_login_in_place_at_mode_600
    run_test "test_validate_license_creates_a_new_env_at_mode_600" test_validate_license_creates_a_new_env_at_mode_600

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_env_file_modes_tests
fi
