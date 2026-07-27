#!/bin/bash
# tests/run-tests.sh — Master test runner for claude-en-boite
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [TEST_FILTER]

Options:
  --force-build     Force image rebuild even if images already exist
  --skip-build      Skip 01-install.sh (image build) tests
  --proxy-only      Run only proxy tests (02-proxy.sh)
  --no-proxy-net    Skip tests that require real outbound network access
  -h, --help        Show this help

Examples:
  $0                        # Run all tests
  $0 --force-build          # Rebuild images then run all tests
  $0 --proxy-only           # Only test the network proxy
  $0 02                     # Run only tests matching '02'
EOF
}

# ── Parse args ────────────────────────────────────────────────────────────────
FORCE_BUILD=false
SKIP_BUILD=false
PROXY_ONLY=false
FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-build)  FORCE_BUILD=true; shift ;;
        --skip-build)   SKIP_BUILD=true;  shift ;;
        --proxy-only)   PROXY_ONLY=true;  shift ;;
        --no-proxy-net) export NO_PROXY_NET=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "Unknown option: $1"; usage; exit 1 ;;
        *)              FILTER="$1"; shift ;;
    esac
done

export FORCE_BUILD

# ── Discover test files ───────────────────────────────────────────────────────
mapfile -t ALL_TESTS < <(find "$SCRIPT_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)

if [[ "$PROXY_ONLY" == "true" ]]; then
    mapfile -t TESTS < <(printf '%s\n' "${ALL_TESTS[@]}" | grep '02-proxy')
elif [[ "$SKIP_BUILD" == "true" ]]; then
    mapfile -t TESTS < <(printf '%s\n' "${ALL_TESTS[@]}" | grep -v '01-install')
elif [[ -n "$FILTER" ]]; then
    mapfile -t TESTS < <(printf '%s\n' "${ALL_TESTS[@]}" | grep "$FILTER" || true)
else
    TESTS=("${ALL_TESTS[@]}")
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "No test files found matching filter '${FILTER:-*}'."
    exit 1
fi

# ── Make all test scripts executable ─────────────────────────────────────────
chmod +x "$SCRIPT_DIR/lib.sh"
for t in "${ALL_TESTS[@]}"; do chmod +x "$t"; done

# ── Run each test suite and collect results ───────────────────────────────────
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   claude-en-boite test suite                 ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo ""

SUITE_PASS=0
SUITE_FAIL=0
SUITE_NAMES_FAILED=()

for test_file in "${TESTS[@]}"; do
    name="$(basename "$test_file")"
    echo -e "${BOLD}━━━ $name ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    if bash "$test_file"; then
        SUITE_PASS=$(( SUITE_PASS + 1 ))
    else
        SUITE_FAIL=$(( SUITE_FAIL + 1 ))
        SUITE_NAMES_FAILED+=("$name")
    fi
    echo ""
done

# ── Final summary ─────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
echo -e "${BOLD}Suite summary: ${GREEN}$SUITE_PASS passed${RESET}, ${RED}$SUITE_FAIL failed${RESET}${RESET}"

if [[ ${#SUITE_NAMES_FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}Failed suites:${RESET}"
    for n in "${SUITE_NAMES_FAILED[@]}"; do
        echo -e "  ${RED}•${RESET} $n"
    done
    exit 1
fi

echo -e "${GREEN}${BOLD}All tests passed.${RESET}"
exit 0
