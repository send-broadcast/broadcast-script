#!/bin/bash

# Unit tests for the real restore functions in scripts/restore.sh.
# Exercises restore() end-to-end (with restore_apply stubbed out) against a
# scratch BROADCAST_ROOT, so no Docker or root privileges are needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"

# Scratch installation root rebuilt for each test
RESTORE_TEST_ROOT=""
APPLY_MARKER=""

setup_restore_test() {
    RESTORE_TEST_ROOT=$(mktemp -d)
    APPLY_MARKER="$RESTORE_TEST_ROOT/apply-was-called"

    export BROADCAST_ROOT="$RESTORE_TEST_ROOT"
    unset BROADCAST_ASSUME_YES 2>/dev/null || true

    mkdir -p "$RESTORE_TEST_ROOT/db/backups"

    # Load the real functions with BROADCAST_ROOT pointing at the scratch dir
    source "$PROJECT_ROOT/scripts/restore.sh"

    # Stub out the environment-mutating apply phase (systemctl/docker); the
    # Docker integration test covers the real pg_restore mechanics.
    restore_apply() {
        touch "$APPLY_MARKER"
        return 0
    }
}

teardown_restore_test() {
    unset BROADCAST_ROOT
    unset BROADCAST_ASSUME_YES 2>/dev/null || true
    if [ -n "$RESTORE_TEST_ROOT" ] && [ -d "$RESTORE_TEST_ROOT" ]; then
        rm -rf "$RESTORE_TEST_ROOT"
    fi
}

# Build a valid backup archive: <name>.dump + VERSION inside a tar.gz
# Usage: make_backup_archive <dir> <version> [archive_name]
make_backup_archive() {
    local dir="$1"
    local version="$2"
    local name="${3:-broadcast-backup-v${version}-2026-01-01-00-00-00}"
    local work
    work=$(mktemp -d)

    echo "fake pg_dump payload" > "$work/${name}.dump"
    echo "$version" > "$work/VERSION"
    tar -czf "$dir/${name}.tar.gz" -C "$work" "${name}.dump" VERSION
    rm -rf "$work"

    echo "$dir/${name}.tar.gz"
}

test_restore_requires_backup_file_argument() {
    local result=0
    restore "" </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "restore with no argument should fail"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run without an argument"
}

test_restore_fails_for_missing_file() {
    local result=0
    restore "no-such-backup.tar.gz" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "restore with a nonexistent file should fail"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run for a missing file"
}

test_find_backup_file_checks_standard_locations() {
    local archive found
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT/db/backups" "1.0.0")

    # Bare filename resolves via $BROADCAST_ROOT/db/backups
    found=$(restore_find_backup_file "$(basename "$archive")" 2>/dev/null)
    assert_equals "$archive" "$found" "should find backup in db/backups by bare filename"

    # Absolute path resolves as-is
    found=$(restore_find_backup_file "$archive" 2>/dev/null)
    assert_equals "$archive" "$found" "should find backup by full path"
}

test_restore_cancelled_without_confirmation() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")

    echo "no" | restore "$(basename "$archive")" >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "cancelled restore should exit cleanly"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run when the user answers no"
}

test_restore_runs_with_yes_flag() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "1.0.0" > "$RESTORE_TEST_ROOT/.current_version"

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "restore --yes should succeed without a prompt"
    assert_file_exists "$APPLY_MARKER" "restore_apply should run with --yes"
}

test_restore_runs_with_assume_yes_env() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "1.0.0" > "$RESTORE_TEST_ROOT/.current_version"

    BROADCAST_ASSUME_YES=1 restore "$(basename "$archive")" </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "BROADCAST_ASSUME_YES=1 should skip the prompt"
    assert_file_exists "$APPLY_MARKER" "restore_apply should run with BROADCAST_ASSUME_YES=1"
}

test_restore_rejects_newer_backup_version() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "9.9.9")
    echo "1.0.0" > "$RESTORE_TEST_ROOT/.current_version"

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "newer backup on older install must be refused"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run on version mismatch"
}

test_restore_allows_older_backup_version() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "2.5.0" > "$RESTORE_TEST_ROOT/.current_version"

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "older backup on newer install should proceed (migrations handle schema)"
    assert_file_exists "$APPLY_MARKER" "restore_apply should run for an older backup"
}

# Installs pinned to a rolling tag record it in .current_version ("latest" on
# fresh installs, "edge" on dev servers). compare_versions on a non-numeric
# string is a bash arithmetic error, so the gate must skip instead of crash.
test_restore_skips_version_gate_on_rolling_tag() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "edge" > "$RESTORE_TEST_ROOT/.current_version"

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "restore on an edge-pinned install should proceed"
    assert_file_exists "$APPLY_MARKER" "restore_apply should run when installed version is a rolling tag"
}

test_restore_fails_when_archive_has_no_dump() {
    local work archive result=0
    work=$(mktemp -d)
    echo "1.0.0" > "$work/VERSION"
    archive="$RESTORE_TEST_ROOT/broadcast-backup-v1.0.0-no-dump.tar.gz"
    tar -czf "$archive" -C "$work" VERSION
    rm -rf "$work"

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "archive without a .dump file must be refused"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run without a dump file"
}

# Compute a file's sha256 portably (Linux sha256sum / macOS shasum)
test_sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

test_restore_verifies_a_matching_checksum_sidecar() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "$(test_sha256_of "$archive")  $(basename "$archive")" > "${archive}.sha256"

    local output
    output=$(restore "$(basename "$archive")" --yes </dev/null 2>&1) || result=$?

    assert_equals "0" "$result" "restore with a valid sidecar should succeed"
    assert_contains "$output" "integrity" "restore should mention the integrity check"
    assert_file_exists "$APPLY_MARKER" "restore_apply should run after a passing checksum"
}

test_restore_rejects_a_corrupted_backup() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")
    echo "$(test_sha256_of "$archive")  $(basename "$archive")" > "${archive}.sha256"
    printf 'corruption' >> "$archive"

    local output
    output=$(restore "$(basename "$archive")" --yes </dev/null 2>&1) || result=$?

    assert_equals "1" "$result" "a tarball that fails its checksum must be refused"
    assert_contains "$output" "checksum" "the refusal should name the checksum mismatch"
    assert_file_not_exists "$APPLY_MARKER" "restore_apply must not run on a corrupted backup"
}

# restore_apply runs in an || context from restore(), which suppresses set -e.
# Every docker step must therefore fail explicitly — an unchecked failure falls
# through to the RESTORE COMPLETE banner with nothing restored.
test_restore_apply_fails_fast_when_docker_fails() {
    # Reload the real restore_apply (setup stubbed it out)
    source "$PROJECT_ROOT/scripts/restore.sh"

    touch "$RESTORE_TEST_ROOT/.image"
    RESTORE_DUMP_FILE="$RESTORE_TEST_ROOT/fake.dump"
    touch "$RESTORE_DUMP_FILE"

    # Neutralize host-touching commands; make docker fail
    systemctl() { return 0; }
    sleep() { :; }
    docker() { return 1; }

    local output result=0
    output=$(restore_apply 2>&1) || result=$?

    assert_equals "1" "$result" "restore_apply must fail when docker fails"
    if [[ "$output" == *"RESTORE COMPLETE"* ]]; then
        assert_equals "no completion banner" "RESTORE COMPLETE printed" \
            "a failed apply must never claim the restore completed"
    fi
    unset -f systemctl sleep docker
}

test_restore_cleans_up_temp_dir() {
    local archive result=0
    archive=$(make_backup_archive "$RESTORE_TEST_ROOT" "1.0.0")

    restore "$(basename "$archive")" --yes </dev/null >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "restore should succeed"
    if [ -n "${RESTORE_TEMP_DIR:-}" ] && [ -d "$RESTORE_TEMP_DIR" ]; then
        assert_equals "cleaned" "left behind" "temp dir $RESTORE_TEMP_DIR should be removed after restore"
    fi
}

run_restore_function_tests() {
    echo "Running Restore Function Tests"
    echo "=============================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_restore_test"
    TEST_TEARDOWN_FUNCTION="teardown_restore_test"

    run_test "test_restore_requires_backup_file_argument" test_restore_requires_backup_file_argument
    run_test "test_restore_fails_for_missing_file" test_restore_fails_for_missing_file
    run_test "test_find_backup_file_checks_standard_locations" test_find_backup_file_checks_standard_locations
    run_test "test_restore_cancelled_without_confirmation" test_restore_cancelled_without_confirmation
    run_test "test_restore_runs_with_yes_flag" test_restore_runs_with_yes_flag
    run_test "test_restore_runs_with_assume_yes_env" test_restore_runs_with_assume_yes_env
    run_test "test_restore_rejects_newer_backup_version" test_restore_rejects_newer_backup_version
    run_test "test_restore_allows_older_backup_version" test_restore_allows_older_backup_version
    run_test "test_restore_skips_version_gate_on_rolling_tag" test_restore_skips_version_gate_on_rolling_tag
    run_test "test_restore_fails_when_archive_has_no_dump" test_restore_fails_when_archive_has_no_dump
    run_test "test_restore_verifies_a_matching_checksum_sidecar" test_restore_verifies_a_matching_checksum_sidecar
    run_test "test_restore_rejects_a_corrupted_backup" test_restore_rejects_a_corrupted_backup
    run_test "test_restore_apply_fails_fast_when_docker_fails" test_restore_apply_fails_fast_when_docker_fails
    run_test "test_restore_cleans_up_temp_dir" test_restore_cleans_up_temp_dir

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_restore_function_tests
fi
