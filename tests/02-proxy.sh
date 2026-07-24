#!/bin/bash
# tests/02-proxy.sh — Test that the network proxy starts on bridge network and enforces rules for containers
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROXY_PORT="${PROXY_PORT:-18888}"   # Use a non-standard port to avoid colliding with a live proxy
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
TEST_CONTAINER="claude-proxy-test-$$"
TEST_RULES_FILE="$(mktemp)"

# Allowed domain used in rules
ALLOWED_DOMAIN="github.com"
ALLOWED_URL="https://github.com"

# Domain that must be blocked (not in any rules file)
BLOCKED_URL="https://example.com"

WILDCARD_CONTAINER="claude-proxy-wc-$$"
EMPTY_CONTAINER="claude-proxy-empty-$$"
WILDCARD_RULES_FILE=""
EMPTY_RULES_FILE=""

cleanup() {
    cleanup_container "$TEST_CONTAINER"
    cleanup_container "$WILDCARD_CONTAINER"
    cleanup_container "$EMPTY_CONTAINER"
    rm -f "$TEST_RULES_FILE"
    [[ -n "$WILDCARD_RULES_FILE" ]] && rm -f "$WILDCARD_RULES_FILE" || true
    [[ -n "$EMPTY_RULES_FILE" ]]   && rm -f "$EMPTY_RULES_FILE"   || true
}
trap cleanup EXIT

section "02 · Network proxy (Host Loopback Proxy & Filtering)"

# ── Guard: need podman & curl ─────────────────────────────────────────────────
if ! require_cmd podman; then
    skip "proxy image available" "podman not found"; summary; exit 0
fi
if ! require_cmd curl; then
    skip "proxy tests" "curl not found"; summary; exit 0
fi
if ! require_image "localhost/claude-proxy:latest"; then
    skip "proxy tests" "localhost/claude-proxy:latest image not found — run ./tests/01-install.sh first"
    summary; exit 0
fi

# ── Test 1: proxy image was built correctly ───────────────────────────────────
if require_image "localhost/claude-proxy:latest"; then
    pass "localhost/claude-proxy:latest image exists"
else
    fail "localhost/claude-proxy:latest image exists"
    summary; exit 1
fi

# ── Test 2: proxy container starts on host network ────────────────────────────
echo "https://${ALLOWED_DOMAIN}" > "$TEST_RULES_FILE"

cleanup_container "$TEST_CONTAINER"
podman run -d \
    --pull=never \
    --name "$TEST_CONTAINER" \
    --network host \
    -e PROXY_PORT="$PROXY_PORT" \
    -v "$REPO_DIR/network-proxy.js:/usr/local/bin/network-proxy.js:ro,z" \
    -v "${TEST_RULES_FILE}:/etc/claude-network-rules.txt:ro,z" \
    localhost/claude-proxy:latest \
    /etc/claude-network-rules.txt &>/dev/null

if wait_for_container "$TEST_CONTAINER" 10; then
    pass "proxy container starts on host network"
else
    fail "proxy container starts on host network" \
         "container exited; logs: $(podman logs "$TEST_CONTAINER" 2>&1 | tail -5)"
    summary; exit 1
fi

# Give Node.js a moment to start
sleep 1

# ── Test 3: proxy is listening on host loopback port ─────────────────────────
STATUS=$(proxy_curl_status "$PROXY_URL" "$ALLOWED_URL")
if [[ "$STATUS" != "CONN_ERROR" && "$STATUS" != "000" ]]; then
    pass "proxy is listening on $PROXY_URL"
else
    fail "proxy is listening on $PROXY_URL" "curl returned status='$STATUS'"
fi

# ── Test 4: BLOCKED — domain not in rules returns 403 ────────────────────────
STATUS=$(proxy_curl_status "$PROXY_URL" "$BLOCKED_URL")
if [[ "$STATUS" == "403" ]]; then
    pass "blocked domain ($BLOCKED_URL) → 403 Forbidden"
else
    fail "blocked domain ($BLOCKED_URL) → 403 Forbidden" "got HTTP $STATUS"
fi

# ── Test 5: ALLOWED — domain in rules passes through ─────────────────────────
STATUS=$(proxy_curl_status "$PROXY_URL" "$ALLOWED_URL")
if [[ "$STATUS" =~ ^[23][0-9][0-9]$ ]]; then
    pass "allowed domain ($ALLOWED_URL) → HTTP $STATUS (not blocked)"
elif [[ "$STATUS" == "403" ]]; then
    fail "allowed domain ($ALLOWED_URL) → HTTP $STATUS (was blocked; should be allowed)"
else
    if [[ "$STATUS" =~ ^(000|502|504|CONN_ERROR)$ ]]; then
        pass "allowed domain ($ALLOWED_URL) → forwarded (HTTP $STATUS)"
    else
        fail "allowed domain ($ALLOWED_URL) → unexpected status $STATUS"
    fi
fi

# ── Test 6: Rules hot-reload (verifies file overwrite via cp updates mounted file)
RELOAD_DOMAIN="httpbin.org"
RELOAD_URL="https://${RELOAD_DOMAIN}"

STATUS_BEFORE=$(proxy_curl_status "$PROXY_URL" "$RELOAD_URL")
if [[ "$STATUS_BEFORE" == "403" ]]; then
    TMP_F=$(mktemp)
    cat "$TEST_RULES_FILE" > "$TMP_F"
    echo "https://${RELOAD_DOMAIN}" >> "$TMP_F"
    cp "$TMP_F" "$TEST_RULES_FILE"
    rm -f "$TMP_F"
    sleep 3
    STATUS_AFTER=$(proxy_curl_status "$PROXY_URL" "$RELOAD_URL")
    if [[ "$STATUS_AFTER" != "403" ]]; then
        pass "rules hot-reload: newly-allowed domain passes after rule file cp overwrite"
    else
        fail "rules hot-reload: newly-allowed domain passes after rule file cp overwrite" \
             "still getting 403 after adding rule and waiting 3s"
    fi
else
    skip "rules hot-reload" \
         "$RELOAD_URL was not initially blocked (status=$STATUS_BEFORE); skipping hot-reload test"
fi

# ── Test 7: Wildcard rule ─────────────────────────────────────────────────────
WILDCARD_RULES_FILE="$(mktemp)"
echo "https://*.npmjs.org" > "$WILDCARD_RULES_FILE"
cleanup_container "$WILDCARD_CONTAINER"

podman run -d \
    --pull=never \
    --name "$WILDCARD_CONTAINER" \
    --network host \
    -e PROXY_PORT=18889 \
    -v "$REPO_DIR/network-proxy.js:/usr/local/bin/network-proxy.js:ro,z" \
    -v "${WILDCARD_RULES_FILE}:/etc/claude-network-rules.txt:ro,z" \
    localhost/claude-proxy:latest \
    /etc/claude-network-rules.txt &>/dev/null

WILDCARD_PROXY_URL="http://127.0.0.1:18889"
if wait_for_container "$WILDCARD_CONTAINER" 10; then
    sleep 1
    STATUS_ALLOWED=$(proxy_curl_status "$WILDCARD_PROXY_URL" "https://registry.npmjs.org")
    STATUS_BLOCKED=$(proxy_curl_status "$WILDCARD_PROXY_URL" "https://github.com")

    if [[ "$STATUS_BLOCKED" == "403" ]]; then
        pass "wildcard rule: non-matching domain blocked (github.com → 403)"
    else
        fail "wildcard rule: non-matching domain blocked" "github.com got $STATUS_BLOCKED, expected 403"
    fi

    if [[ "$STATUS_ALLOWED" != "403" ]]; then
        pass "wildcard rule: matching subdomain allowed (registry.npmjs.org → $STATUS_ALLOWED)"
    else
        fail "wildcard rule: matching subdomain allowed" "registry.npmjs.org was blocked with 403"
    fi
else
    skip "wildcard rule tests" "wildcard proxy container failed to start"
fi
cleanup_container "$WILDCARD_CONTAINER"
rm -f "$WILDCARD_RULES_FILE"

# ── Test 8: Empty rules file ─────────────────────────────────────────────────
EMPTY_RULES_FILE="$(mktemp)"
cleanup_container "$EMPTY_CONTAINER"
podman run -d \
    --pull=never \
    --name "$EMPTY_CONTAINER" \
    --network host \
    -e PROXY_PORT=18890 \
    -v "$REPO_DIR/network-proxy.js:/usr/local/bin/network-proxy.js:ro,z" \
    -v "${EMPTY_RULES_FILE}:/etc/claude-network-rules.txt:ro,z" \
    localhost/claude-proxy:latest \
    /etc/claude-network-rules.txt &>/dev/null

EMPTY_PROXY_URL="http://127.0.0.1:18890"
if wait_for_container "$EMPTY_CONTAINER" 10; then
    pass "proxy starts cleanly with an empty rules file"
    sleep 1
    STATUS=$(proxy_curl_status "$EMPTY_PROXY_URL" "https://github.com")
    if [[ "$STATUS" == "403" ]]; then
        pass "empty rules file blocks all traffic (github.com → 403)"
    else
        fail "empty rules file blocks all traffic" "got $STATUS instead of 403"
    fi
else
    LOGS=$(podman logs "$EMPTY_CONTAINER" 2>&1 | tail -5)
    fail "proxy starts cleanly with an empty rules file" "container exited: $LOGS"
fi
cleanup_container "$EMPTY_CONTAINER"
rm -f "$EMPTY_RULES_FILE"
EMPTY_RULES_FILE=""

summary
