#!/bin/bash

# Every file the scripts create at runtime in /opt/broadcast (the git checkout
# that update.sh pulls into) must be gitignored. Otherwise `git status` on a
# customer server lists state files and customer data as untracked, and
# operators and support cannot see the real local changes among them. A fresh
# install on a VM (2026-10-06) showed .health_state, .recovery_state and
# .recovery_state.lock as untracked within minutes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"

# Top-level dotfiles that scripts name by their full /opt/broadcast path
script_root_dotfiles() {
    grep -rhoE '/opt/broadcast/\.[A-Za-z0-9_.-]+' \
        "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/broadcast.sh" "$PROJECT_ROOT/install.sh" 2>/dev/null |
        sed 's|^/opt/broadcast/||' | sort -u
}

# Files that scripts derive from another path, so the search above misses them
DERIVED_FILES=".recovery_state.lock"

# Directories that hold customer data at runtime (bind-mounted into containers)
DATA_DIR_SAMPLES="app/storage/broadcast-backup-20260101.tar.gz app/storage/ab/cd/blob db/backups/broadcast-backup-20260101.tar.gz db/backups/VERSION"

is_ignored() {
    git -C "$PROJECT_ROOT" check-ignore -q --no-index "$1"
}

test_search_finds_runtime_dotfiles() {
    # Guard against a search that silently matches nothing
    local found
    found=$(script_root_dotfiles)
    assert_contains "$found" ".health_state" "search finds .health_state"
    assert_contains "$found" ".recovery_state" "search finds .recovery_state"
}

test_runtime_dotfiles_are_ignored() {
    local f missing=""
    for f in $(script_root_dotfiles) $DERIVED_FILES; do
        is_ignored "$f" || missing="$missing $f"
    done
    assert_equals "" "$missing" "runtime files missing from .gitignore"
}

test_data_dirs_are_ignored() {
    local f missing=""
    for f in $DATA_DIR_SAMPLES; do
        is_ignored "$f" || missing="$missing $f"
    done
    assert_equals "" "$missing" "customer data paths missing from .gitignore"
}

test_ignored_data_dirs_track_only_gitkeep() {
    # git overwrites an ignored file without a warning when a pulled commit
    # starts to track the same path. Tracking only .gitkeep in these
    # directories keeps a pull from replacing customer data.
    local tracked
    tracked=$(git -C "$PROJECT_ROOT" ls-files app/storage db/backups | grep -v '/\.gitkeep$')
    assert_equals "" "$tracked" "tracked files in customer data directories"
}

run_gitignore_runtime_tests() {
    init_test_framework

    run_test "test_search_finds_runtime_dotfiles" test_search_finds_runtime_dotfiles
    run_test "test_runtime_dotfiles_are_ignored" test_runtime_dotfiles_are_ignored
    run_test "test_data_dirs_are_ignored" test_data_dirs_are_ignored
    run_test "test_ignored_data_dirs_track_only_gitkeep" test_ignored_data_dirs_track_only_gitkeep

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_gitignore_runtime_tests
fi
