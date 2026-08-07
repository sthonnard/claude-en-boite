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

# ── MCP proxy helpers ────────────────────────────────────────────────────────

# Create a minimal mock MCP upstream server script.
# Returns the path to a temp JS file.
create_mock_mcp_server_script() {
    local script_file
    script_file=$(mktemp --suffix=.js)
    cat > "$script_file" << 'MOCKEOF'
const http = require('http');
const PORT = parseInt(process.env.MOCK_MCP_PORT || '18891', 10);
const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        let id = null;
        try { id = JSON.parse(body).id; } catch(e) {}
        const resp = JSON.stringify({
            jsonrpc: '2.0', id: id,
            result: { content: [{ type: 'text', text: 'mock-ok' }] }
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(resp);
    });
});
server.listen(PORT, '0.0.0.0', () => {
    console.log('[MOCK MCP] listening on port ' + PORT);
});
process.on('SIGTERM', () => { server.close(); process.exit(0); });
MOCKEOF
    echo "$script_file"
}

# Start the MCP proxy container for testing.
# Usage: start_test_mcp_proxy <config-file> <mock-upstream-port> [container-name] [proxy-port]
start_test_mcp_proxy() {
    local config_file="$1"
    local mock_port="$2"
    local cname="${3:-claude-mcp-proxy-test}"
    local proxy_port="${4:-18892}"

    podman run -d \
        --pull=never \
        --name "$cname" \
        --network host \
        -v "${config_file}:/etc/mcp-access-rules.yaml:ro,z" \
        -e MCP_PROXY_PORT="$proxy_port" \
        --entrypoint node \
        localhost/claude-proxy:latest \
        /usr/local/bin/mcp-proxy.js /etc/mcp-access-rules.yaml &>/dev/null
    echo "$cname"
}

# Start a mock MCP upstream server in a container.
# Usage: start_mock_mcp_server <script-file> [container-name] [port]
start_mock_mcp_server() {
    local script_file="$1"
    local cname="${2:-claude-mock-mcp}"
    local port="${3:-18891}"

    podman run -d \
        --pull=never \
        --name "$cname" \
        --network host \
        -v "${script_file}:/usr/local/bin/mock-mcp.js:ro,z" \
        -e MOCK_MCP_PORT="$port" \
        --entrypoint node \
        localhost/claude-proxy:latest \
        /usr/local/bin/mock-mcp.js &>/dev/null
    echo "$cname"
}

# Send a JSON-RPC request to the MCP proxy and return the response body.
# Usage: mcp_proxy_call <proxy-url> <json-body>
mcp_proxy_call() {
    local proxy_url="$1"
    local json_body="$2"
    curl -s -X POST "${proxy_url}/v1/mcp" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        --max-time 10 2>/dev/null
}

# Send a JSON-RPC request and return the HTTP status code.
# Usage: mcp_proxy_status <proxy-url> <json-body>
mcp_proxy_status() {
    local proxy_url="$1"
    local json_body="$2"
    curl -s -o /dev/null -w '%{http_code}' -X POST "${proxy_url}/v1/mcp" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        --max-time 10 2>/dev/null || echo "000"
}

# Check if an MCP response contains isError: true.
# Returns 0 (success) if isError is true, 1 otherwise.
mcp_response_is_error() {
    local response="$1"
    echo "$response" | grep -q '"isError"[[:space:]]*:[[:space:]]*true'
}

# Check if an MCP response contains the "mock-ok" text from our mock server.
# Returns 0 (success) if forwarded to mock, 1 otherwise.
mcp_response_is_forwarded() {
    local response="$1"
    echo "$response" | grep -q 'mock-ok'
}

# ── MITM test helpers ────────────────────────────────────────────────────────

# Generate test CA + server certs for MITM testing.
# Usage: generate_test_mitm_certs <hostname> <output-dir>
generate_test_mitm_certs() {
    local hostname="$1"
    local cert_dir="$2"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
        -days 1 -nodes -subj "/CN=Test MCP Proxy CA" 2>/dev/null
    openssl req -newkey rsa:2048 -keyout "$cert_dir/mitm.key" -out "$cert_dir/mitm.csr" \
        -nodes -subj "/CN=$hostname" 2>/dev/null
    openssl x509 -req -in "$cert_dir/mitm.csr" -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" \
        -CAcreateserial -out "$cert_dir/mitm.crt" -days 1 \
        -extfile <(echo "subjectAltName=DNS:$hostname") 2>/dev/null
    rm -f "$cert_dir/mitm.csr" "$cert_dir/ca.srl"
}

# Start the network proxy with MITM interception enabled.
# Usage: start_test_proxy_with_mitm <rules-file> <cert-dir> <mitm-host> <mcp-proxy-port> [container-name] [proxy-port]
start_test_proxy_with_mitm() {
    local rules_file="$1"
    local cert_dir="$2"
    local mitm_host="$3"
    local mcp_proxy_port="$4"
    local cname="${5:-claude-proxy-mitm-test}"
    local proxy_port="${6:-18893}"

    podman run -d \
        --pull=never \
        --name "$cname" \
        --network host \
        -v "${rules_file}:/etc/claude-network-rules.txt:ro,z" \
        -v "${cert_dir}/mitm.crt:/etc/mitm.crt:ro,z" \
        -v "${cert_dir}/mitm.key:/etc/mitm.key:ro,z" \
        -e PROXY_PORT="$proxy_port" \
        -e MCP_MITM_HOST="$mitm_host" \
        -e MCP_MITM_CERT="/etc/mitm.crt" \
        -e MCP_MITM_KEY="/etc/mitm.key" \
        -e MCP_PROXY_PORT="$mcp_proxy_port" \
        localhost/claude-proxy:latest \
        /etc/claude-network-rules.txt &>/dev/null
    echo "$cname"
}

# Send an HTTPS request through the MITM proxy and return the response body.
# Usage: mitm_proxy_call <proxy-port> <ca-cert> <mitm-host> <json-body>
mitm_proxy_call() {
    local proxy_port="$1"
    local ca_cert="$2"
    local mitm_host="$3"
    local json_body="$4"
    curl -s -X POST "https://${mitm_host}/v1/mcp" \
        --proxy "http://127.0.0.1:${proxy_port}" \
        --cacert "$ca_cert" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        --max-time 10 2>/dev/null
}

# Send an HTTPS request through the MITM proxy and return the HTTP status code.
# Usage: mitm_proxy_status <proxy-port> <ca-cert> <mitm-host> <json-body>
mitm_proxy_status() {
    local proxy_port="$1"
    local ca_cert="$2"
    local mitm_host="$3"
    local json_body="$4"
    curl -s -o /dev/null -w '%{http_code}' -X POST "https://${mitm_host}/v1/mcp" \
        --proxy "http://127.0.0.1:${proxy_port}" \
        --cacert "$ca_cert" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        --max-time 10 2>/dev/null || echo "000"
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


