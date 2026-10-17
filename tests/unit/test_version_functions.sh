#!/bin/bash

# Unit tests for the real version/config helpers in scripts/common.sh,
# scripts/restore.sh (compare_versions) and broadcast.sh (set_docker_image).
# Scripts are loaded unmodified via the sandbox harness (only the hardcoded
# /opt/broadcast constant is redirected to a scratch directory).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
}

teardown_sandbox() {
    harness_destroy_sandbox
}

test_validate_semantic_version_accepts_valid_versions() {
    local v
    for v in "1.2.3" "0.0.1" "10.20.30" "2.0.0-alpha.1" "1.2.3+build.5"; do
        local rc=0
        sandbox_run "validate_semantic_version '$v'" >/dev/null || rc=$?
        assert_equals "0" "$rc" "validate_semantic_version should accept $v"
    done
}

test_validate_semantic_version_rejects_invalid_versions() {
    local v
    for v in "1.2" "v1.2.3" "latest" "1.2.3.4" ""; do
        local rc=0
        sandbox_run "validate_semantic_version '$v'" >/dev/null || rc=$?
        assert_not_equals "0" "$rc" "validate_semantic_version should reject '$v'"
    done
}

test_compare_versions_return_codes() {
    local rc

    rc=0; sandbox_run "compare_versions 1.2.3 1.2.3" >/dev/null || rc=$?
    assert_equals "0" "$rc" "equal versions should return 0"

    rc=0; sandbox_run "compare_versions 2.0.0 1.9.9" >/dev/null || rc=$?
    assert_equals "1" "$rc" "first greater should return 1"

    rc=0; sandbox_run "compare_versions 1.0.0 2.0.0" >/dev/null || rc=$?
    assert_equals "2" "$rc" "first smaller should return 2"

    # Numeric, not lexicographic: 1.10.0 > 1.9.0
    rc=0; sandbox_run "compare_versions 1.10.0 1.9.0" >/dev/null || rc=$?
    assert_equals "1" "$rc" "1.10.0 should compare greater than 1.9.0"

    # Missing positions are zero-filled: 1.2 == 1.2.0
    rc=0; sandbox_run "compare_versions 1.2 1.2.0" >/dev/null || rc=$?
    assert_equals "0" "$rc" "1.2 should equal 1.2.0"
}

test_get_current_version_reads_version_file() {
    echo "3.1.4" > "$SANDBOX_ROOT/.current_version"
    local out
    out=$(sandbox_run "get_current_version")
    assert_equals "3.1.4" "$out" "should read .current_version"
}

test_get_current_version_defaults_to_unknown() {
    rm -f "$SANDBOX_ROOT/.current_version"
    local out
    out=$(sandbox_run "get_current_version")
    assert_equals "unknown" "$out" "missing .current_version should yield 'unknown'"
}

test_log_version_change_creates_history_with_header() {
    sandbox_run "log_version_change upgrade 1.0.0 1.1.0" >/dev/null

    local history="$SANDBOX_ROOT/.version_history"
    assert_file_exists "$history" "history file should be created"

    local first_line
    first_line=$(head -1 "$history")
    assert_contains "$first_line" "Broadcast Version History" "history should start with header"

    local entry
    entry=$(tail -1 "$history")
    assert_contains "$entry" "upgrade | 1.0.0 | 1.1.0" "entry should record the change"
}

test_log_version_change_caps_history_length() {
    # The implementation keeps the last 102 lines (100 entries + headers
    # until they scroll off). Write well past the cap and check it holds.
    sandbox_run 'for i in $(seq 1 150); do log_version_change upgrade "1.0.$((i-1))" "1.0.$i"; done' >/dev/null

    local lines
    lines=$(wc -l < "$SANDBOX_ROOT/.version_history" | tr -d ' ')
    assert_equals "102" "$lines" "history should be capped at 102 lines"

    local last
    last=$(tail -1 "$SANDBOX_ROOT/.version_history")
    assert_contains "$last" "1.0.150" "newest entry must survive the cap"
}

test_set_docker_image_amd64() {
    # Default harness uname mock reports x86_64
    sandbox_run "set_docker_image 2.1.0" >/dev/null

    local image
    image=$(cat "$SANDBOX_ROOT/.image")
    assert_contains "$image" "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.1.0" \
        "amd64 should use the plain image with the requested tag"
    if /usr/bin/grep -q "TARGETARCH" "$SANDBOX_ROOT/.image"; then
        assert_equals "no TARGETARCH" "TARGETARCH present" "amd64 must not set TARGETARCH"
    fi

    local version
    version=$(cat "$SANDBOX_ROOT/.current_version")
    assert_equals "2.1.0" "$version" ".current_version should track the deployed tag"
}

test_set_docker_image_arm64() {
    harness_mock_uname_arm64
    sandbox_run "set_docker_image 2.1.0" >/dev/null

    local image
    image=$(cat "$SANDBOX_ROOT/.image")
    assert_contains "$image" "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast-arm:2.1.0" \
        "arm64 should use the -arm image"
    assert_contains "$image" "TARGETARCH=arm64" "arm64 must set TARGETARCH"
}

test_set_docker_image_defaults_to_latest() {
    sandbox_run "set_docker_image" >/dev/null
    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":latest" "no argument should mean :latest"
    assert_equals "latest" "$(cat "$SANDBOX_ROOT/.current_version")" ".current_version should be latest"
}

test_generate_encryption_keys_adds_all_three_keys() {
    touch "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "generate_encryption_keys" >/dev/null || rc=$?
    assert_equals "0" "$rc" "generate_encryption_keys should succeed"

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "should add primary, deterministic and salt keys"
    harness_assert_called "chown broadcast:broadcast" "app/.env ownership should be restored"
}

test_generate_encryption_keys_is_idempotent() {
    touch "$SANDBOX_ROOT/app/.env"
    sandbox_run "generate_encryption_keys" >/dev/null
    local original
    original=$(/usr/bin/grep "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" "$SANDBOX_ROOT/app/.env")

    sandbox_run "generate_encryption_keys" >/dev/null

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "second run must not duplicate keys"
    local current
    current=$(/usr/bin/grep "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" "$SANDBOX_ROOT/app/.env")
    assert_equals "$original" "$current" "existing keys must not be regenerated"
}

# An app/.env copied from the manual sample can carry a key name with an empty
# value. The app uses the env keys only when all three have a value, so no
# data was encrypted with them yet: filling the empty ones is safe.
test_generate_encryption_keys_fills_empty_values() {
    cat > "$SANDBOX_ROOT/app/.env" <<'ENV'
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=
ENV
    sandbox_run "generate_encryption_keys" >/dev/null

    local name
    for name in PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT; do
        assert_equals "1" "$(/usr/bin/grep -cE "^ACTIVE_RECORD_ENCRYPTION_${name}=[0-9a-f]{32}$" "$SANDBOX_ROOT/app/.env")" \
            "$name should get one generated value"
    done
    assert_equals "3" "$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")" \
        "no empty duplicate lines should remain"
}

# A key with a value is never regenerated: data may be encrypted with it.
test_generate_encryption_keys_keeps_set_values_and_adds_only_missing() {
    cat > "$SANDBOX_ROOT/app/.env" <<'ENV'
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=keep-this-primary
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
ENV
    sandbox_run "generate_encryption_keys" >/dev/null

    local content
    content=$(cat "$SANDBOX_ROOT/app/.env")
    assert_contains "$content" "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=keep-this-primary" "a set key must survive"
    assert_equals "1" "$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" "$SANDBOX_ROOT/app/.env")" \
        "a set key must not be duplicated"
    assert_equals "1" "$(/usr/bin/grep -cE "^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=[0-9a-f]{32}$" "$SANDBOX_ROOT/app/.env")" \
        "an empty key gets a value"
    assert_equals "1" "$(/usr/bin/grep -cE "^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=[0-9a-f]{32}$" "$SANDBOX_ROOT/app/.env")" \
        "an absent key gets a value"
}

test_generate_encryption_keys_fails_without_app_env() {
    rm -f "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "generate_encryption_keys" >/dev/null || rc=$?
    assert_equals "1" "$rc" "missing app/.env should fail"
}

# /license/check answers 401 both for a wrong key and for a valid key that
# is already used on every server it allows; the second carries a reason.
test_validate_license_names_a_server_limit() {
    echo "mail.example.com" > "$SANDBOX_ROOT/.domain"
    echo "KEY-1" > "$SANDBOX_ROOT/.license"
    local output rc=0
    output=$(sandbox_run "validate_license" \
        "export CURL_MOCK_HTTP_CODE=401 CURL_MOCK_BODY='{\"error\":\"server_limit_reached\",\"servers_total\":3,\"servers_used\":3}'") || rc=$?

    assert_equals "1" "$rc" "a key at its limit must fail validation"
    assert_contains "$output" "already used on every server it allows (3 of 3)" "the limit must be named"
    assert_contains "$output" "https://sendbroadcast.net/dashboard" "the operator must learn where to free a server"
}

test_validate_license_calls_a_bare_401_an_invalid_key() {
    echo "mail.example.com" > "$SANDBOX_ROOT/.domain"
    echo "KEY-1" > "$SANDBOX_ROOT/.license"
    local output rc=0
    output=$(sandbox_run "validate_license" "export CURL_MOCK_HTTP_CODE=401") || rc=$?

    assert_equals "1" "$rc" "a rejected key must fail validation"
    assert_contains "$output" "Invalid license key" "a bare 401 is a wrong key"
}

run_version_function_tests() {
    echo "Running Version Function Tests"
    echo "=============================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_validate_semantic_version_accepts_valid_versions" test_validate_semantic_version_accepts_valid_versions
    run_test "test_validate_semantic_version_rejects_invalid_versions" test_validate_semantic_version_rejects_invalid_versions
    run_test "test_compare_versions_return_codes" test_compare_versions_return_codes
    run_test "test_get_current_version_reads_version_file" test_get_current_version_reads_version_file
    run_test "test_get_current_version_defaults_to_unknown" test_get_current_version_defaults_to_unknown
    run_test "test_log_version_change_creates_history_with_header" test_log_version_change_creates_history_with_header
    run_test "test_log_version_change_caps_history_length" test_log_version_change_caps_history_length
    run_test "test_set_docker_image_amd64" test_set_docker_image_amd64
    run_test "test_set_docker_image_arm64" test_set_docker_image_arm64
    run_test "test_set_docker_image_defaults_to_latest" test_set_docker_image_defaults_to_latest
    run_test "test_generate_encryption_keys_adds_all_three_keys" test_generate_encryption_keys_adds_all_three_keys
    run_test "test_generate_encryption_keys_is_idempotent" test_generate_encryption_keys_is_idempotent
    run_test "test_generate_encryption_keys_fills_empty_values" test_generate_encryption_keys_fills_empty_values
    run_test "test_generate_encryption_keys_keeps_set_values_and_adds_only_missing" test_generate_encryption_keys_keeps_set_values_and_adds_only_missing
    run_test "test_validate_license_names_a_server_limit" test_validate_license_names_a_server_limit
    run_test "test_validate_license_calls_a_bare_401_an_invalid_key" test_validate_license_calls_a_bare_401_an_invalid_key
    run_test "test_generate_encryption_keys_fails_without_app_env" test_generate_encryption_keys_fails_without_app_env

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_version_function_tests
fi
