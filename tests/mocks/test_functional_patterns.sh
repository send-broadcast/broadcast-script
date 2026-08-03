#!/bin/bash

# Tests for the real external-dependency code paths in scripts/common.sh:
# license validation against the (mocked) sendbroadcast.net API and registry
# credential loading. The unmodified functions run inside the sandbox
# harness; curl is a PATH shim whose response is set per test via
# CURL_MOCK_HTTP_CODE / CURL_MOCK_BODY.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license-key-123" > "$SANDBOX_ROOT/.license"
}

teardown_sandbox() {
    harness_destroy_sandbox
}

VALID_LICENSE_RESPONSE='{"registry_url":"gitea.hostedapp.org","registry_login":"broadcast-user","registry_password":"s3cret"}'

# Count BROADCAST_REGISTRY_* lines written to the sandbox .env
registry_lines_in_env() {
    if [ -f "$SANDBOX_ROOT/.env" ]; then
        /usr/bin/grep -c "^BROADCAST_REGISTRY_" "$SANDBOX_ROOT/.env" || true
    else
        echo "0"
    fi
}

test_validate_license_success_writes_registry_credentials() {
    local rc=0 output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$VALID_LICENSE_RESPONSE'") || rc=$?

    assert_equals "0" "$rc" "a valid license should validate"
    assert_contains "$output" "License key valid" "success should be reported"

    assert_equals "3" "$(registry_lines_in_env)" ".env should gain url, login and password"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_URL=gitea.hostedapp.org" \
        "registry URL should be persisted"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=s3cret" \
        "registry password should be persisted"

    # The request itself must be an HTTPS POST to the license endpoint
    harness_assert_called "https://sendbroadcast.net/license/check" \
        "validation must target the license API over HTTPS"
}

RICH_LICENSE_RESPONSE='{"registry_url":"gitea.hostedapp.org","registry_login":"broadcast-user","registry_password":"s3cret","license_name":"Test Extended License","license_status":"active","license_key_masked":"••••••••3F2A","buyer_name":"Simon Chiu","buyer_email":"s•••@furvur.com","servers_total":5,"servers_used":2,"domains":["test.example.com","demo.other.com"],"monitoring_enabled":true,"latest_version":"2.23.0"}'

test_validate_license_prints_the_operator_summary() {
    echo "2.23.0" > "$SANDBOX_ROOT/.current_version"

    local output rc=0
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$RICH_LICENSE_RESPONSE'") || rc=$?

    assert_equals "0" "$rc" "an enriched response should validate"
    assert_contains "$output" "Test Extended License" "the license name must be shown"
    assert_contains "$output" "active" "the license status must be shown"
    assert_contains "$output" "Simon Chiu" "the buyer must be shown"
    assert_contains "$output" "s•••@furvur.com" "the masked buyer email must be shown"
    assert_contains "$output" "••••••••3F2A" "the masked key must be shown"
    assert_contains "$output" "2 of 5" "server usage must be shown"
    assert_contains "$output" "demo.other.com" "other registered domains must be listed"
    assert_contains "$output" "up to date" "matching versions must be reported as current"
    assert_contains "$output" "enabled for this server" "the monitoring state must be shown"
}

test_validate_license_flags_an_available_update() {
    echo "2.20.0" > "$SANDBOX_ROOT/.current_version"

    local output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$RICH_LICENSE_RESPONSE'")

    assert_contains "$output" "update available: 2.23.0" \
        "a newer release must be surfaced with the installed version"
    assert_contains "$output" "upgrade" "the fix should be named"
}

test_validate_license_notes_disabled_monitoring() {
    local body="${RICH_LICENSE_RESPONSE/\"monitoring_enabled\":true/\"monitoring_enabled\":false}"
    local output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$body'")

    assert_contains "$output" "disabled" "disabled monitoring must be shown"
    assert_contains "$output" "dashboard" "the way to enable it should be pointed at"
}

test_validate_license_replaces_credentials_instead_of_appending() {
    # validate_license is now an information command operators run casually
    # — repeated runs must not grow .env with duplicate credential lines.
    local run_env="
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$VALID_LICENSE_RESPONSE'"
    sandbox_run "validate_license" "$run_env" >/dev/null
    sandbox_run "validate_license" "$run_env" >/dev/null

    assert_equals "3" "$(registry_lines_in_env)" \
        ".env must hold exactly one line per registry credential after repeated runs"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=s3cret" \
        "the current credentials must be present"
}

test_validate_license_preserves_unrelated_env_lines() {
    echo "SOME_OTHER_SETTING=keep-me" > "$SANDBOX_ROOT/.env"

    sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='$VALID_LICENSE_RESPONSE'" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "SOME_OTHER_SETTING=keep-me" \
        "non-registry lines must survive a credential refresh"
    assert_equals "3" "$(registry_lines_in_env)" "credentials written once"
}

test_validate_license_rejects_401_as_invalid_key() {
    local rc=0 output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=401
export CURL_MOCK_BODY='{}'") || rc=$?

    assert_equals "1" "$rc" "a 401 must fail validation"
    assert_contains "$output" "Invalid license key" "401 should be reported as an invalid key"
    assert_equals "0" "$(registry_lines_in_env)" "no credentials may be written on failure"
}

test_validate_license_rejects_unexpected_http_status() {
    local rc=0 output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=500
export CURL_MOCK_BODY='oops'") || rc=$?

    assert_equals "1" "$rc" "a 500 must fail validation"
    assert_contains "$output" "Unexpected HTTP response (500)" "the status code should be reported"
    assert_equals "0" "$(registry_lines_in_env)" "no credentials may be written on failure"
}

test_validate_license_rejects_malformed_json() {
    local rc=0 output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='<html>not json</html>'") || rc=$?

    assert_equals "1" "$rc" "a non-JSON body must fail validation"
    assert_contains "$output" "Invalid response" "malformed JSON should be reported"
    assert_equals "0" "$(registry_lines_in_env)" "no credentials may be written on failure"
}

test_validate_license_rejects_missing_registry_fields() {
    local rc=0 output
    output=$(sandbox_run "validate_license" "
export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='{\"registry_url\":\"gitea.hostedapp.org\",\"registry_login\":\"user\"}'") || rc=$?

    assert_equals "1" "$rc" "a response without registry_password must fail"
    assert_contains "$output" "Missing registry password" "the missing field should be named"
    assert_equals "0" "$(registry_lines_in_env)" \
        "a partial response must not write any credentials"
}

test_validate_license_fails_without_license_file() {
    rm -f "$SANDBOX_ROOT/.license"
    local rc=0
    sandbox_run "validate_license" >/dev/null || rc=$?
    assert_equals "1" "$rc" "missing license file must fail before any network call"
    harness_assert_not_called "curl" "no API call should be made without a license file"
}

test_load_registry_info_exports_credentials() {
    cat > "$SANDBOX_ROOT/.env" <<'ENV'
BROADCAST_REGISTRY_URL=gitea.hostedapp.org
BROADCAST_REGISTRY_LOGIN=broadcast-user
BROADCAST_REGISTRY_PASSWORD=s3cret
ENV

    local output
    output=$(sandbox_run 'load_registry_info && echo "URL=$BROADCAST_REGISTRY_URL LOGIN=$BROADCAST_REGISTRY_LOGIN"')
    assert_contains "$output" "URL=gitea.hostedapp.org LOGIN=broadcast-user" \
        "credentials should be exported into the environment"
}

test_load_registry_info_skips_comment_lines() {
    cat > "$SANDBOX_ROOT/.env" <<'ENV'
# comment line that must not be exported
BROADCAST_REGISTRY_URL=gitea.hostedapp.org
BROADCAST_REGISTRY_LOGIN=broadcast-user
BROADCAST_REGISTRY_PASSWORD=s3cret
ENV

    local rc=0
    sandbox_run "load_registry_info" >/dev/null || rc=$?
    assert_equals "0" "$rc" "comments in .env must not break loading"
}

test_load_registry_info_fails_without_env_file() {
    rm -f "$SANDBOX_ROOT/.env"
    local rc=0 output
    output=$(sandbox_run "load_registry_info") || rc=$?
    assert_equals "1" "$rc" "missing .env must fail"
    assert_contains "$output" "validate your license" "the fix should be suggested"
}

run_functional_tests() {
    echo "Running License/Registry Functional Tests"
    echo "========================================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_validate_license_success_writes_registry_credentials" test_validate_license_success_writes_registry_credentials
    run_test "test_validate_license_prints_the_operator_summary" test_validate_license_prints_the_operator_summary
    run_test "test_validate_license_flags_an_available_update" test_validate_license_flags_an_available_update
    run_test "test_validate_license_notes_disabled_monitoring" test_validate_license_notes_disabled_monitoring
    run_test "test_validate_license_replaces_credentials_instead_of_appending" test_validate_license_replaces_credentials_instead_of_appending
    run_test "test_validate_license_preserves_unrelated_env_lines" test_validate_license_preserves_unrelated_env_lines
    run_test "test_validate_license_rejects_401_as_invalid_key" test_validate_license_rejects_401_as_invalid_key
    run_test "test_validate_license_rejects_unexpected_http_status" test_validate_license_rejects_unexpected_http_status
    run_test "test_validate_license_rejects_malformed_json" test_validate_license_rejects_malformed_json
    run_test "test_validate_license_rejects_missing_registry_fields" test_validate_license_rejects_missing_registry_fields
    run_test "test_validate_license_fails_without_license_file" test_validate_license_fails_without_license_file
    run_test "test_load_registry_info_exports_credentials" test_load_registry_info_exports_credentials
    run_test "test_load_registry_info_skips_comment_lines" test_load_registry_info_skips_comment_lines
    run_test "test_load_registry_info_fails_without_env_file" test_load_registry_info_fails_without_env_file

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_functional_tests
fi
