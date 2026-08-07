#!/bin/bash
# tests/04-mcp-proxy.sh — Test that the MCP proxy enforces tool-level access control
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MOCK_PORT="${MOCK_MCP_PORT:-18891}"
PROXY_PORT="${MCP_PROXY_PORT:-18892}"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"

MOCK_CONTAINER="claude-mock-mcp-$$"
PROXY_CONTAINER="claude-mcp-proxy-test-$$"
MOCK_SCRIPT=""
CONFIG_FILE=""

cleanup() {
    cleanup_container "$PROXY_CONTAINER"
    cleanup_container "$MOCK_CONTAINER"
    [[ -n "$MOCK_SCRIPT" ]] && rm -f "$MOCK_SCRIPT" || true
    [[ -n "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE" || true
}
trap cleanup EXIT

section "04 · MCP Proxy (Tool-Level Access Control)"

# ── Guards ───────────────────────────────────────────────────────────────────
if ! require_cmd podman; then
    skip "MCP proxy tests" "podman not found"; summary; exit 0
fi
if ! require_cmd curl; then
    skip "MCP proxy tests" "curl not found"; summary; exit 0
fi
if ! require_image "localhost/claude-proxy:latest"; then
    skip "MCP proxy tests" "localhost/claude-proxy:latest image not found — run install first"
    summary; exit 0
fi

# ── Setup: write test config ─────────────────────────────────────────────────
CONFIG_FILE="$(mktemp --suffix=.yaml)"
cat > "$CONFIG_FILE" << EOF
upstream: http://127.0.0.1:${MOCK_PORT}/v1/mcp

allow:
  - confluence_search
  - confluence_get_*
  - jira_get_*
  - jira_search

deny:
  - confluence_delete_page

restrict:
  confluence_update_page:
    field: pageId
    allowed: ["111", "222"]
  jira_update_issue:
    field: issueKey
    allowed: ["PROJ-*"]
  jira_create_issue:
    field: projectKey
    allowed: ["PROJ", "TEAM"]

default: deny
EOF

# ── Setup: start mock MCP upstream ───────────────────────────────────────────
MOCK_SCRIPT="$(create_mock_mcp_server_script)"
cleanup_container "$MOCK_CONTAINER"
start_mock_mcp_server "$MOCK_SCRIPT" "$MOCK_CONTAINER" "$MOCK_PORT" >/dev/null

if ! wait_for_container "$MOCK_CONTAINER" 10; then
    fail "mock MCP server starts" "container exited; logs: $(podman logs "$MOCK_CONTAINER" 2>&1 | tail -5)"
    summary; exit 1
fi
sleep 1

# ── Setup: start MCP proxy ──────────────────────────────────────────────────
cleanup_container "$PROXY_CONTAINER"
podman run -d \
    --pull=never \
    --name "$PROXY_CONTAINER" \
    --network host \
    -v "${CONFIG_FILE}:/etc/mcp-access-rules.yaml:ro,z" \
    -v "$REPO_DIR/mcp-proxy.js:/usr/local/bin/mcp-proxy.js:ro,z" \
    -e MCP_PROXY_PORT="$PROXY_PORT" \
    --entrypoint node \
    localhost/claude-proxy:latest \
    /usr/local/bin/mcp-proxy.js /etc/mcp-access-rules.yaml &>/dev/null

# ── Test 1: MCP proxy container starts ───────────────────────────────────────
if wait_for_container "$PROXY_CONTAINER" 10; then
    pass "MCP proxy container starts"
else
    fail "MCP proxy container starts" \
         "container exited; logs: $(podman logs "$PROXY_CONTAINER" 2>&1 | tail -5)"
    summary; exit 1
fi
sleep 1

# ── Test 2: MCP proxy is listening ──────────────────────────────────────────
STATUS=$(mcp_proxy_status "$PROXY_URL" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
if [[ "$STATUS" != "000" && "$STATUS" != "" ]]; then
    pass "MCP proxy is listening on $PROXY_URL"
else
    fail "MCP proxy is listening on $PROXY_URL" "curl returned status='$STATUS'"
fi

# ── Test 3: Non-tool-call passes through ────────────────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "non-tool-call (initialize) passes through to upstream"
else
    fail "non-tool-call (initialize) passes through" "response: $RESP"
fi

# ── Test 4: tools/list passes through ───────────────────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "tools/list passes through to upstream"
else
    fail "tools/list passes through" "response: $RESP"
fi

# ── Test 5: Allowed read tool passes through ────────────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"confluence_search","arguments":{"query":"test"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "allowed read tool (confluence_search) passes through"
else
    fail "allowed read tool (confluence_search) passes through" "response: $RESP"
fi

# ── Test 6: Allowed read tool with wildcard passes through ──────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"confluence_get_page","arguments":{"pageId":"999"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "wildcard allow (confluence_get_*) matches confluence_get_page"
else
    fail "wildcard allow (confluence_get_*) matches confluence_get_page" "response: $RESP"
fi

# ── Test 7: Denied tool is blocked ──────────────────────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"confluence_delete_page","arguments":{"pageId":"111"}}}')
if mcp_response_is_error "$RESP"; then
    pass "denied tool (confluence_delete_page) returns isError"
else
    fail "denied tool (confluence_delete_page) returns isError" "response: $RESP"
fi

# ── Test 8: Restricted tool with allowed resource passes ────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"confluence_update_page","arguments":{"pageId":"111","body":"new content"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "restricted tool with allowed resource (pageId=111) passes"
else
    fail "restricted tool with allowed resource (pageId=111) passes" "response: $RESP"
fi

# ── Test 9: Restricted tool with disallowed resource is blocked ─────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"confluence_update_page","arguments":{"pageId":"999","body":"new content"}}}')
if mcp_response_is_error "$RESP"; then
    if echo "$RESP" | grep -q "pageId"; then
        pass "restricted tool with disallowed resource (pageId=999) blocked with detail"
    else
        pass "restricted tool with disallowed resource (pageId=999) blocked"
    fi
else
    fail "restricted tool with disallowed resource (pageId=999) blocked" "response: $RESP"
fi

# ── Test 10: Wildcard matching in restrict (PROJ-* matches PROJ-123) ────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"jira_update_issue","arguments":{"issueKey":"PROJ-123","summary":"updated"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "restrict wildcard (PROJ-*) matches PROJ-123"
else
    fail "restrict wildcard (PROJ-*) matches PROJ-123" "response: $RESP"
fi

# ── Test 11: Wildcard restrict does NOT match wrong prefix ──────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"jira_update_issue","arguments":{"issueKey":"OTHER-456","summary":"updated"}}}')
if mcp_response_is_error "$RESP"; then
    pass "restrict wildcard (PROJ-*) does not match OTHER-456"
else
    fail "restrict wildcard (PROJ-*) does not match OTHER-456" "response: $RESP"
fi

# ── Test 12: Unknown tool uses default policy (deny) ────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"some_unknown_tool","arguments":{}}}')
if mcp_response_is_error "$RESP"; then
    pass "unknown tool blocked by default deny policy"
else
    fail "unknown tool blocked by default deny policy" "response: $RESP"
fi

# ── Test 13: Config hot-reload ──────────────────────────────────────────────
RESP_BEFORE=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"some_new_tool","arguments":{}}}')
if mcp_response_is_error "$RESP_BEFORE"; then
    TMP_CONFIG=$(mktemp --suffix=.yaml)
    cat "$CONFIG_FILE" > "$TMP_CONFIG"
    echo "" >> "$TMP_CONFIG"
    echo "  - some_new_tool" >> "$TMP_CONFIG"
    # Rewrite the allow list properly
    cat > "$TMP_CONFIG" << EOF
upstream: http://127.0.0.1:${MOCK_PORT}/v1/mcp

allow:
  - confluence_search
  - confluence_get_*
  - jira_get_*
  - jira_search
  - some_new_tool

deny:
  - confluence_delete_page

restrict:
  confluence_update_page:
    field: pageId
    allowed: ["111", "222"]
  jira_update_issue:
    field: issueKey
    allowed: ["PROJ-*"]
  jira_create_issue:
    field: projectKey
    allowed: ["PROJ", "TEAM"]

default: deny
EOF
    cp "$TMP_CONFIG" "$CONFIG_FILE"
    rm -f "$TMP_CONFIG"
    sleep 3
    RESP_AFTER=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"some_new_tool","arguments":{}}}')
    if mcp_response_is_forwarded "$RESP_AFTER"; then
        pass "config hot-reload: newly-allowed tool passes after config update"
    else
        fail "config hot-reload: newly-allowed tool passes after config update" \
             "still blocked after adding to allow list and waiting 3s; response: $RESP_AFTER"
    fi
else
    skip "config hot-reload" "some_new_tool was not initially blocked"
fi

# ── Test 14: Malformed JSON body returns error ──────────────────────────────
STATUS=$(mcp_proxy_status "$PROXY_URL" 'this is not json')
if [[ "$STATUS" == "400" ]]; then
    pass "malformed JSON body returns 400"
else
    fail "malformed JSON body returns 400" "got HTTP $STATUS"
fi

# ── Test 15: Restrict with multiple allowed projects ────────────────────────
RESP=$(mcp_proxy_call "$PROXY_URL" '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"jira_create_issue","arguments":{"projectKey":"TEAM","summary":"test"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "restrict with multiple allowed values (projectKey=TEAM) passes"
else
    fail "restrict with multiple allowed values (projectKey=TEAM) passes" "response: $RESP"
fi

# ── Test 16: Audit logging ──────────────────────────────────────────────────
LOGS=$(podman logs "$PROXY_CONTAINER" 2>&1)
if echo "$LOGS" | grep -q '\[MCP FILTER\] DENIED' && echo "$LOGS" | grep -q '\[MCP FILTER\] ALLOWED'; then
    pass "audit logging contains ALLOWED and DENIED entries"
else
    fail "audit logging contains ALLOWED and DENIED entries" "logs: $(echo "$LOGS" | grep 'MCP FILTER' | head -5)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# MITM Integration Tests — full HTTPS → network proxy → MCP proxy → mock flow
# ══════════════════════════════════════════════════════════════════════════════

MITM_HOST="testmcp.example.com"
MITM_NET_PROXY_PORT="${MITM_NET_PROXY_PORT:-18893}"
MITM_CERT_DIR=""
MITM_NET_CONTAINER="claude-proxy-mitm-test-$$"
MITM_RULES_FILE=""

orig_cleanup=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
trap 'cleanup_container "$MITM_NET_CONTAINER"; [[ -n "${MITM_CERT_DIR:-}" ]] && rm -rf "$MITM_CERT_DIR" || true; [[ -n "${MITM_RULES_FILE:-}" ]] && rm -f "$MITM_RULES_FILE" || true; '"$orig_cleanup" EXIT

if ! require_cmd openssl; then
    skip "MITM integration tests" "openssl not found"
else

section "04b · MITM Integration (HTTPS → network proxy → MCP proxy → mock)"

# ── Generate test certs ─────────────────────────────────────────────────────
MITM_CERT_DIR=$(mktemp -d)
generate_test_mitm_certs "$MITM_HOST" "$MITM_CERT_DIR"

if [[ -f "$MITM_CERT_DIR/ca.crt" && -f "$MITM_CERT_DIR/mitm.crt" && -f "$MITM_CERT_DIR/mitm.key" ]]; then
    pass "MITM test certificates generated"
else
    fail "MITM test certificates generated" "missing cert files in $MITM_CERT_DIR"
    summary; exit 1
fi

# ── Network rules allowing the MITM host ────────────────────────────────────
MITM_RULES_FILE=$(mktemp --suffix=.txt)
cat > "$MITM_RULES_FILE" << EOF
https://$MITM_HOST
EOF

# ── Start network proxy with MITM ──────────────────────────────────────────
cleanup_container "$MITM_NET_CONTAINER"
start_test_proxy_with_mitm "$MITM_RULES_FILE" "$MITM_CERT_DIR" "$MITM_HOST" "$PROXY_PORT" "$MITM_NET_CONTAINER" "$MITM_NET_PROXY_PORT" >/dev/null

if wait_for_container "$MITM_NET_CONTAINER" 10; then
    pass "network proxy with MITM starts"
else
    fail "network proxy with MITM starts" \
         "container exited; logs: $(podman logs "$MITM_NET_CONTAINER" 2>&1 | tail -5)"
    summary; exit 1
fi
sleep 1

# ── Verify MITM log message ─────────────────────────────────────────────────
MITM_LOGS=$(podman logs "$MITM_NET_CONTAINER" 2>&1)
if echo "$MITM_LOGS" | grep -q "MITM interception enabled"; then
    pass "network proxy logs MITM interception enabled"
else
    fail "network proxy logs MITM interception enabled" "logs: $MITM_LOGS"
fi

# ── Test 17: HTTPS request through MITM reaches MCP proxy and mock upstream ─
RESP=$(mitm_proxy_call "$MITM_NET_PROXY_PORT" "$MITM_CERT_DIR/ca.crt" "$MITM_HOST" \
    '{"jsonrpc":"2.0","id":100,"method":"initialize","params":{}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "MITM: HTTPS initialize passes through to mock upstream"
else
    fail "MITM: HTTPS initialize passes through to mock upstream" "response: $RESP"
fi

# ── Test 18: Allowed tool through MITM ───────────────────────────────────────
RESP=$(mitm_proxy_call "$MITM_NET_PROXY_PORT" "$MITM_CERT_DIR/ca.crt" "$MITM_HOST" \
    '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"confluence_search","arguments":{"query":"test"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "MITM: allowed tool (confluence_search) passes through"
else
    fail "MITM: allowed tool (confluence_search) passes through" "response: $RESP"
fi

# ── Test 19: Denied tool blocked through MITM ───────────────────────────────
RESP=$(mitm_proxy_call "$MITM_NET_PROXY_PORT" "$MITM_CERT_DIR/ca.crt" "$MITM_HOST" \
    '{"jsonrpc":"2.0","id":102,"method":"tools/call","params":{"name":"confluence_delete_page","arguments":{"pageId":"111"}}}')
if mcp_response_is_error "$RESP"; then
    pass "MITM: denied tool (confluence_delete_page) is blocked"
else
    fail "MITM: denied tool (confluence_delete_page) is blocked" "response: $RESP"
fi

# ── Test 20: Restricted tool with allowed resource through MITM ─────────────
RESP=$(mitm_proxy_call "$MITM_NET_PROXY_PORT" "$MITM_CERT_DIR/ca.crt" "$MITM_HOST" \
    '{"jsonrpc":"2.0","id":103,"method":"tools/call","params":{"name":"confluence_update_page","arguments":{"pageId":"111","body":"ok"}}}')
if mcp_response_is_forwarded "$RESP"; then
    pass "MITM: restricted tool with allowed resource (pageId=111) passes"
else
    fail "MITM: restricted tool with allowed resource (pageId=111) passes" "response: $RESP"
fi

# ── Test 21: Restricted tool with disallowed resource blocked through MITM ──
RESP=$(mitm_proxy_call "$MITM_NET_PROXY_PORT" "$MITM_CERT_DIR/ca.crt" "$MITM_HOST" \
    '{"jsonrpc":"2.0","id":104,"method":"tools/call","params":{"name":"confluence_update_page","arguments":{"pageId":"999","body":"nope"}}}')
if mcp_response_is_error "$RESP"; then
    pass "MITM: restricted tool with disallowed resource (pageId=999) blocked"
else
    fail "MITM: restricted tool with disallowed resource (pageId=999) blocked" "response: $RESP"
fi

# ── Test 22: MITM intercept logged by network proxy ─────────────────────────
MITM_LOGS=$(podman logs "$MITM_NET_CONTAINER" 2>&1)
if echo "$MITM_LOGS" | grep -q "MITM INTERCEPT"; then
    pass "network proxy logs MITM INTERCEPT for $MITM_HOST"
else
    fail "network proxy logs MITM INTERCEPT for $MITM_HOST" "logs: $(echo "$MITM_LOGS" | tail -5)"
fi

fi  # end openssl guard

summary
