#!/bin/bash

# Manual (non-script) installs copy manual/app/.env.sample instead of running
# install.sh. The sample once lacked the Active Record encryption keys that
# install.sh generates, so manual installs booted without them and every save
# of an encrypted value (2FA, backup destinations, AI and Autopilot API keys)
# failed. This test keeps the sample in step with the keys install.sh writes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"

APP_SAMPLE="$PROJECT_ROOT/manual/app/.env.sample"

# Encryption variables that install.sh writes to app/.env
install_encryption_variables() {
    grep -hoE 'ACTIVE_RECORD_ENCRYPTION_[A-Z_]+=' "$PROJECT_ROOT/scripts/install.sh" |
        tr -d '=' | sort -u
}

# Variable names (uncommented) set in the manual app sample
sample_variables() {
    grep -oE '^[A-Z_]+=' "$APP_SAMPLE" | tr -d '=' | sort -u
}

test_search_finds_install_encryption_variables() {
    # Guard against a search that silently matches nothing
    local found
    found=$(install_encryption_variables)
    assert_contains "$found" "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" "search finds the primary key"
    assert_equals "3" "$(echo "$found" | wc -l | tr -d ' ')" "install.sh writes three encryption variables"
}

test_sample_has_every_encryption_variable() {
    local v sample missing=""
    sample=$(sample_variables)
    for v in $(install_encryption_variables); do
        echo "$sample" | grep -qx "$v" || missing="$missing $v"
    done
    assert_equals "" "$missing" "encryption variables missing from manual/app/.env.sample"
}

test_sample_explains_how_to_generate_keys() {
    local content
    content=$(cat "$APP_SAMPLE")
    assert_contains "$content" "openssl rand -hex 16" "sample shows the command that generates each key"
    assert_contains "$content" "Never change" "sample warns not to change the keys after first start"
}

# A placeholder value (e.g. "replace-with-...") is a non-empty string, so the
# app would accept it as a real key and encrypt data with a value that is
# public. Leaving the values empty makes the app log its "not configured"
# warning until the operator generates real keys.
test_sample_encryption_values_are_empty() {
    local v line nonempty=""
    for v in $(install_encryption_variables); do
        line=$(grep -E "^${v}=" "$APP_SAMPLE")
        [[ "$line" == "${v}=" ]] || nonempty="$nonempty $v"
    done
    assert_equals "" "$nonempty" "encryption variables with a value in manual/app/.env.sample"
}

run_manual_env_sample_tests() {
    init_test_framework

    run_test "test_search_finds_install_encryption_variables" test_search_finds_install_encryption_variables
    run_test "test_sample_has_every_encryption_variable" test_sample_has_every_encryption_variable
    run_test "test_sample_explains_how_to_generate_keys" test_sample_explains_how_to_generate_keys
    run_test "test_sample_encryption_values_are_empty" test_sample_encryption_values_are_empty

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_manual_env_sample_tests
fi
