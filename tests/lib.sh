#!/bin/bash
# tests/lib.sh — shared helpers for claude-en-boite test suite

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Global counters ───────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_NAMES=()

# ── Output helpers ────────────────────────────────────────────────────────────
pass() {
    local name="${1:-}"
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo -e "  ${GREEN}✓${RESET} $name"
}

fail() {
    local name="${1:-}"; local reason="${2:-}"
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    FAILED_NAMES+=("$name")
    echo -e "  ${RED}✗${RESET} $name"
    [[ -n "$reason" ]] && echo -e "    ${RED}↳ $reason${RESET}"
}

skip() {
    local name="${1:-}"; local reason="${2:-}"
    TESTS_SKIPPED=$(( TESTS_SKIPPED + 1 ))
    echo -e "  ${YELLOW}⊘${RESET} $name ${YELLOW}(skipped: $reason)${RESET}"
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ $1${RESET}"
}

summary() {
    echo ""
    echo -e "${BOLD}Results: ${GREEN}$TESTS_PASSED passed${RESET}, ${RED}$TESTS_FAILED failed${RESET}, ${YELLOW}$TESTS_SKIPPED skipped${RESET}"
    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
        echo -e "${RED}Failed tests:${RESET}"
        for n in "${FAILED_NAMES[@]}"; do
            echo -e "  ${RED}•${RESET} $n"
        done
    fi
    [[ "$TESTS_FAILED" -eq 0 ]]
}

# ── Prerequisite guards ───────────────────────────────────────────────────────

# Ensure a command exists, else skip with reason.
require_cmd() {
    command -v "$1" &>/dev/null
}

# Ensure an env var is set and non-empty.
require_env() {
    [[ -n "${!1:-}" ]]
}

# Ensure a podman image exists.
require_image() {
    podman image inspect "$1" &>/dev/null 2>&1
}

# ── Container cleanup ─────────────────────────────────────────────────────────

# Remove a named container if it exists (suppress errors).
cleanup_container() {
    local name="$1"
    podman rm -f "$name" &>/dev/null 2>&1 || true
}

# Remove all containers whose name matches a prefix.
cleanup_containers_prefix() {
    local prefix="$1"
    podman ps -a --format '{{.Names}}' 2>/dev/null \
        | grep "^${prefix}" \
        | xargs -r podman rm -f &>/dev/null 2>&1 || true
}

# ── Assertion helpers ─────────────────────────────────────────────────────────

# Run a command and pass/fail based on exit code.
assert_success() {
    local name="$1"; shift
    if "$@" &>/dev/null; then
        pass "$name"
    else
        fail "$name" "command failed: $*"
    fi
}

# Run a command expecting failure.
assert_failure() {
    local name="$1"; shift
    if ! "$@" &>/dev/null; then
        pass "$name"
    else
        fail "$name" "expected failure but succeeded: $*"
    fi
}

# Assert output contains a string.
assert_output_contains() {
    local name="$1"; local needle="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qF "$needle"; then
        pass "$name"
    else
        fail "$name" "expected '$needle' in output; got: $(echo "$output" | head -5)"
    fi
}

# Assert output does NOT contain a string.
assert_output_not_contains() {
    local name="$1"; local needle="$2"; shift 2
    local output
    output=$("$@" 2>&1) || true
    if ! echo "$output" | grep -qF "$needle"; then
        pass "$name"
    else
        fail "$name" "did not expect '$needle' in output"
    fi
}

# Wait for a container to reach 'running' state (max N seconds).
wait_for_container() {
    local name="$1"; local max_secs="${2:-10}"
    for (( i=0; i<max_secs; i++ )); do
        if podman container inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ── Proxy helpers ─────────────────────────────────────────────────────────────

# Start the proxy container for testing.
# Usage: start_test_proxy <rules-file> [container-name]
start_test_proxy() {
    local rules_file="$1"
    local cname="${2:-claude-proxy-test}"

    podman run -d \
        --pull=never \
        --name "$cname" \
        --network host \
        -v "${rules_file}:/etc/claude-network-rules.txt:ro,z" \
        localhost/claude-proxy:latest \
        /etc/claude-network-rules.txt &>/dev/null
    echo "$cname"
}

# Make an HTTP/HTTPS request through the proxy and return HTTP status code.
# Usage: proxy_curl_status <proxy-url> <target-url>
proxy_curl_status() {
    local proxy_url="$1"
    local target_url="$2"
    local out
    out=$(curl -s -o /dev/null -w '%{http_code}:%{http_connect}:%{proxy_code}' \
        --proxy "$proxy_url" \
        --max-time 10 \
        --connect-timeout 5 \
        "$target_url" 2>/dev/null) || true

    local http_code=""
    local http_connect=""
    local proxy_code=""
    IFS=: read -r http_code http_connect proxy_code <<< "$out" || true

    if [[ "$proxy_code" == "403" || "$http_code" == "403" || "$http_connect" == "403" ]]; then
        echo "403"
    elif [[ "$http_code" =~ ^[1-5][0-9][0-9]$ && "$http_code" != "000" ]]; then
        echo "$http_code"
    elif [[ "$http_connect" =~ ^[1-5][0-9][0-9]$ && "$http_connect" != "000" ]]; then
        echo "$http_connect"
    elif [[ "$proxy_code" =~ ^[1-5][0-9][0-9]$ && "$proxy_code" != "000" ]]; then
        echo "$proxy_code"
    else
        echo "DEBUG_PROXY_CURL: out='$out' http_code='$http_code' http_connect='$http_connect' proxy_code='$proxy_code'" >&2
        echo "CONN_ERROR"
    fi
}

# Make an HTTP/HTTPS request through the proxy FROM INSIDE a podman container on the given bridge network.
# Usage: container_proxy_curl_status <network-name> <proxy-url> <target-url>
container_proxy_curl_status() {
    local podman_net="$1"
    local proxy_url="$2"
    local target_url="$3"
    local client_img="localhost/claude-code:latest"
    if ! require_image "$client_img"; then
        if require_image "claude-code"; then
            client_img="claude-code"
        else
            client_img="alpine:3.22"
        fi
    fi
    local out
    out=$(podman run --rm --pull=never --network "$podman_net" \
        "$client_img" curl -s -o /dev/null -w '%{http_code}:%{http_connect}:%{proxy_code}' \
        --proxy "$proxy_url" \
        --max-time 10 \
        --connect-timeout 5 \
        "$target_url" 2>/dev/null) || true

    local http_code=""
    local http_connect=""
    local proxy_code=""
    IFS=: read -r http_code http_connect proxy_code <<< "$out" || true

    if [[ "$proxy_code" == "403" || "$http_code" == "403" || "$http_connect" == "403" ]]; then
        echo "403"
    elif [[ "$http_code" =~ ^[1-5][0-9][0-9]$ && "$http_code" != "000" ]]; then
        echo "$http_code"
    elif [[ "$http_connect" =~ ^[1-5][0-9][0-9]$ && "$http_connect" != "000" ]]; then
        echo "$http_connect"
    elif [[ "$proxy_code" =~ ^[1-5][0-9][0-9]$ && "$proxy_code" != "000" ]]; then
        echo "$proxy_code"
    else
        echo "DEBUG_CONTAINER_PROXY_CURL: out='$out' http_code='$http_code' http_connect='$http_connect' proxy_code='$proxy_code'" >&2
        echo "CONN_ERROR"
    fi
}


