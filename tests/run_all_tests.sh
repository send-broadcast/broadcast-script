#!/bin/bash

# Main test runner for all Broadcast script tests

set -e

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test suite counters
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

# Test configuration
VERBOSE=false
PATTERN=""
SUITE=""

# Usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -v, --verbose     Enable verbose output"
    echo "  -p, --pattern     Run tests matching pattern"
    echo "  -s, --suite       Run specific test suite (unit|integration|mocks)"
    echo "  -h, --help        Show this help message"
    echo
    echo "Test Suites:"
    echo "  unit              Unit tests for individual functions"
    echo "  integration       Integration tests for workflows"
    echo "  mocks             Tests with mocked external dependencies"
    echo
    echo "Examples:"
    echo "  $0                        # Run all tests"
    echo "  $0 -s unit               # Run only unit tests"
    echo "  $0 -p backup             # Run tests matching 'backup'"
    echo "  $0 -v -s integration     # Run integration tests with verbose output"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -p|--pattern)
                PATTERN="$2"
                shift 2
                ;;
            -s|--suite)
                SUITE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Run a test suite
run_test_suite() {
    local suite_name="$1"
    local test_file="$2"
    
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    if [ ! -f "$test_file" ]; then
        echo -e "${RED}✗ SKIP: $suite_name (file not found: $test_file)${NC}"
        return
    fi
    
    if [ -n "$PATTERN" ] && [[ "$suite_name" != *"$PATTERN"* ]]; then
        if [ "$VERBOSE" = true ]; then
            echo -e "${YELLOW}⊘ SKIP: $suite_name (pattern mismatch)${NC}"
        fi
        return
    fi
    
    echo -e "${BLUE}Running $suite_name...${NC}"
    
    if [ "$VERBOSE" = true ]; then
        if bash "$test_file"; then
            echo -e "${GREEN}✓ PASS: $suite_name${NC}"
            PASSED_SUITES=$((PASSED_SUITES + 1))
        else
            echo -e "${RED}✗ FAIL: $suite_name${NC}"
            FAILED_SUITES=$((FAILED_SUITES + 1))
        fi
    else
        if bash "$test_file" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ PASS: $suite_name${NC}"
            PASSED_SUITES=$((PASSED_SUITES + 1))
        else
            echo -e "${RED}✗ FAIL: $suite_name${NC}"
            echo "  Run with -v for detailed output"
            FAILED_SUITES=$((FAILED_SUITES + 1))
        fi
    fi
    echo
}

# Run unit tests
run_unit_tests() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           UNIT TESTS                   ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    run_test_suite "Framework Test" "$SCRIPT_DIR/simple_test.sh"
    run_test_suite "Version Functions" "$SCRIPT_DIR/unit/test_version_functions.sh"
    run_test_suite "Log Streaming Functions" "$SCRIPT_DIR/unit/test_logs_streaming.sh"
    run_test_suite "Restore Functions" "$SCRIPT_DIR/unit/test_restore_functions.sh"
    run_test_suite "Upgrade/Downgrade Functions" "$SCRIPT_DIR/unit/test_upgrade_downgrade.sh"
    run_test_suite "Monitor Functions" "$SCRIPT_DIR/unit/test_monitor.sh"
    run_test_suite "Diagnose Command" "$SCRIPT_DIR/unit/test_diagnose.sh"
    run_test_suite "Upgrade Preflight" "$SCRIPT_DIR/unit/test_preflight.sh"
    run_test_suite "Fix Command" "$SCRIPT_DIR/unit/test_fix.sh"
    run_test_suite "Health Sender" "$SCRIPT_DIR/unit/test_health_sender.sh"
    run_test_suite "broadcast.sh Routing" "$SCRIPT_DIR/unit/test_broadcast_routing.sh"
    run_test_suite "System Service Scripts" "$SCRIPT_DIR/unit/test_system_services.sh"
    run_test_suite "Docker Reference Consistency" "$SCRIPT_DIR/unit/test_docker_references.sh"
}

# Run integration tests
run_integration_tests() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}        INTEGRATION TESTS              ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    run_test_suite "Workflow Patterns" "$SCRIPT_DIR/integration/test_workflow_patterns.sh"

    # Backup/restore runs real pg_dump/pg_restore against a disposable
    # PostgreSQL container, so it needs a working Docker daemon.
    if docker info >/dev/null 2>&1; then
        run_test_suite "Backup/Restore (Docker)" "$SCRIPT_DIR/integration/test_backup_restore.sh"
        # Boots the real app image under Thruster + Puma against a disposable
        # PostgreSQL and floods it. Skips itself when the private app image is
        # not present locally.
        run_test_suite "Descriptor Exhaustion (Docker)" "$SCRIPT_DIR/integration/test_descriptor_exhaustion.sh"
    else
        echo -e "${YELLOW}⊘ SKIP: Backup/Restore (Docker) — Docker daemon not available${NC}"
        echo -e "${YELLOW}⊘ SKIP: Descriptor Exhaustion (Docker) — Docker daemon not available${NC}"
        echo
    fi
}

# Run mock tests
run_mock_tests() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           MOCK TESTS                  ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    run_test_suite "Functional Patterns" "$SCRIPT_DIR/mocks/test_functional_patterns.sh"
}

# Print final summary
print_final_summary() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}           FINAL SUMMARY               ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo -e "Total test suites: ${BLUE}$TOTAL_SUITES${NC}"
    echo -e "Suites passed: ${GREEN}$PASSED_SUITES${NC}"
    echo -e "Suites failed: ${RED}$FAILED_SUITES${NC}"
    echo
    
    if [ $FAILED_SUITES -eq 0 ]; then
        echo -e "${GREEN}🎉 ALL TEST SUITES PASSED! 🎉${NC}"
        echo -e "${GREEN}The Broadcast scripts are ready for deployment.${NC}"
        return 0
    else
        echo -e "${RED}❌ SOME TEST SUITES FAILED ❌${NC}"
        echo -e "${RED}Please fix the failing tests before deployment.${NC}"
        echo
        echo -e "${YELLOW}For detailed output, run with the -v flag:${NC}"
        echo -e "${YELLOW}  $0 -v${NC}"
        return 1
    fi
}

# Validate test environment
validate_test_environment() {
    # Check if required directories exist
    if [ ! -d "$SCRIPT_DIR" ]; then
        echo -e "${RED}Error: Test directory not found: $SCRIPT_DIR${NC}"
        exit 1
    fi
    
    # Check if test framework exists
    if [ ! -f "$SCRIPT_DIR/test_framework.sh" ]; then
        echo -e "${RED}Error: Test framework not found: $SCRIPT_DIR/test_framework.sh${NC}"
        exit 1
    fi
    
    # Ensure test framework is executable
    chmod +x "$SCRIPT_DIR/test_framework.sh"
    
    # Make all test files executable
    find "$SCRIPT_DIR" -name "*.sh" -type f -exec chmod +x {} \;
}

# Main function
main() {
    parse_args "$@"
    
    echo -e "${GREEN}Broadcast Script Test Suite${NC}"
    echo -e "${GREEN}===========================${NC}"
    echo
    
    if [ -n "$SUITE" ]; then
        echo -e "${YELLOW}Running test suite: $SUITE${NC}"
    fi
    
    if [ -n "$PATTERN" ]; then
        echo -e "${YELLOW}Pattern filter: $PATTERN${NC}"
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}Verbose mode enabled${NC}"
    fi
    
    echo
    
    # Validate environment
    validate_test_environment
    
    # Run test suites based on selection
    if [ -z "$SUITE" ] || [ "$SUITE" = "unit" ]; then
        run_unit_tests
    fi
    
    if [ -z "$SUITE" ] || [ "$SUITE" = "integration" ]; then
        run_integration_tests
    fi
    
    if [ -z "$SUITE" ] || [ "$SUITE" = "mocks" ]; then
        run_mock_tests
    fi
    
    # Print final results
    print_final_summary
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi