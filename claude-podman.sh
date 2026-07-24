#!/bin/bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
if [[ "$SOURCE" != /* ]]; then
    RESOLVED="$(command -v "$SOURCE" 2>/dev/null || true)"
    if [[ -n "$RESOLVED" ]]; then
        SOURCE="$RESOLVED"
    fi
fi

while [[ -h "$SOURCE" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

if [[ -z "${ANTHROPIC_FOUNDRY_BASE_URL:-}" ]]; then
    echo "Error: ANTHROPIC_FOUNDRY_BASE_URL environment variable is not set." >&2
    exit 1
fi

echo "Fetching Azure access token..."
AZURE_TOKEN=$(az account get-access-token \
    --resource https://cognitiveservices.azure.com \
    --query accessToken -o tsv 2>/dev/null) || {
    echo "Error: could not get Azure access token. Run 'az login' first."
    exit 1
}

WAS_MACHINE_RUNNING=true
if [[ "$(uname)" == "Darwin" ]]; then
    MACHINE_STATE=$(podman machine inspect --format '{{.State}}' 2>/dev/null | tr -d '[:space:]' || echo "not-found")
    if [[ "$MACHINE_STATE" == "not-found" ]]; then
        WAS_MACHINE_RUNNING=false
        echo "No Podman machine found. Creating Podman machine..."
        podman machine init
        echo "Starting Podman machine..."
        podman machine start
    elif [[ "$MACHINE_STATE" != "running" ]]; then
        WAS_MACHINE_RUNNING=false
        echo "Starting Podman machine..."
        podman machine start
    fi
fi

PROXY_TARGET_IMAGE="localhost/claude-proxy:latest"
CODE_TARGET_IMAGE="localhost/claude-code:latest"

# Ensure required images exist, auto-building if necessary
if ! podman image inspect "$PROXY_TARGET_IMAGE" &>/dev/null || ! podman image inspect "$CODE_TARGET_IMAGE" &>/dev/null; then
    if ! podman image inspect "claude-proxy" &>/dev/null || ! podman image inspect "claude-code" &>/dev/null; then
        echo "Required Podman images not found. Building images now..."
        "$SCRIPT_DIR/install-claude-podman.sh"
    fi
fi

if podman image inspect "$PROXY_TARGET_IMAGE" &>/dev/null; then
    PROXY_IMAGE="$PROXY_TARGET_IMAGE"
else
    PROXY_IMAGE="claude-proxy"
fi

if podman image inspect "$CODE_TARGET_IMAGE" &>/dev/null; then
    CODE_IMAGE="$CODE_TARGET_IMAGE"
else
    CODE_IMAGE="claude-code"
fi

# Persistent configuration and state directories
CONFIG_DIR="$HOME/.config/claude-podman"
STATE_DIR="$CONFIG_DIR/state"
echo "Using STATE_DIR: $STATE_DIR"
mkdir -p "$STATE_DIR"

ACTIVE_RULES_FILE="$CONFIG_DIR/active-network-rules.txt"

# Discover project network rules file
PROJECT_RULES_FILE=""
if [[ -n "${NETWORK_RULES_FILE:-}" && -f "$NETWORK_RULES_FILE" ]]; then
    PROJECT_RULES_FILE="$NETWORK_RULES_FILE"
elif [[ -f "$(pwd)/.claude-network-rules" ]]; then
    PROJECT_RULES_FILE="$(pwd)/.claude-network-rules"
elif [[ -f "$(pwd)/network-rules.local.txt" ]]; then
    PROJECT_RULES_FILE="$(pwd)/network-rules.local.txt"
elif [[ -f "$(pwd)/network-rules.txt" ]]; then
    PROJECT_RULES_FILE="$(pwd)/network-rules.txt"
elif [[ -f "$CONFIG_DIR/network-rules.txt" ]]; then
    PROJECT_RULES_FILE="$CONFIG_DIR/network-rules.txt"
elif [[ -f "$SCRIPT_DIR/network-rules.txt" ]]; then
    PROJECT_RULES_FILE="$SCRIPT_DIR/network-rules.txt"
fi

# Combine default and project rules into active rules file
TMP_RULES=$(mktemp)
if [[ -f "$SCRIPT_DIR/network-rules.txt" ]]; then
    cat "$SCRIPT_DIR/network-rules.txt" >> "$TMP_RULES"
    echo "" >> "$TMP_RULES"
fi
if [[ -f "$CONFIG_DIR/network-rules.txt" && "$CONFIG_DIR/network-rules.txt" != "$SCRIPT_DIR/network-rules.txt" ]]; then
    cat "$CONFIG_DIR/network-rules.txt" >> "$TMP_RULES"
    echo "" >> "$TMP_RULES"
fi
if [[ -n "$PROJECT_RULES_FILE" && -f "$PROJECT_RULES_FILE" ]]; then
    cat "$PROJECT_RULES_FILE" >> "$TMP_RULES"
    echo "" >> "$TMP_RULES"
fi
if [[ -f "$ACTIVE_RULES_FILE" ]]; then
    cat "$ACTIVE_RULES_FILE" >> "$TMP_RULES"
fi

grep -v '^[[:space:]]*$' "$TMP_RULES" | awk '!seen[$0]++' > "$ACTIVE_RULES_FILE.tmp" || true
cp "$ACTIVE_RULES_FILE.tmp" "$ACTIVE_RULES_FILE"
rm -f "$ACTIVE_RULES_FILE.tmp" "$TMP_RULES"

# Ensure the rules file actually exists as a regular file before we volume-mount it.
touch "$ACTIVE_RULES_FILE"

SESSION_ID="claude-$$"
PODMAN_NET="claude-net"
PROXY_CONTAINER="claude-proxy"
TEMP_CLAUDE_MD=""

cleanup() {
    if [[ -n "${TEMP_CLAUDE_MD:-}" && -f "$TEMP_CLAUDE_MD" ]]; then
        rm -f "$TEMP_CLAUDE_MD"
    fi

    # Count other running agent containers, excluding this session
    RUNNING_CLAUDE=$(set +o pipefail; podman ps --filter "ancestor=$CODE_IMAGE" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -v "^${SESSION_ID}$" | wc -l)
    RUNNING_CLAUDE=${RUNNING_CLAUDE//[[:space:]]/}

    if [[ "$RUNNING_CLAUDE" -eq 0 ]]; then
        if podman container inspect "$PROXY_CONTAINER" &>/dev/null; then
            echo "Stopping network proxy container ($PROXY_CONTAINER)..."
            podman rm -f "$PROXY_CONTAINER" &>/dev/null || true
        fi

        if [[ "${WAS_MACHINE_RUNNING:-true}" == "false" && "$(uname)" == "Darwin" ]]; then
            echo "Stopping Podman machine..."
            podman machine stop &>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

# 1. Create shared network for agent containers
if ! podman network inspect "$PODMAN_NET" &>/dev/null; then
    podman network create "$PODMAN_NET" > /dev/null
fi

# Helper: build (or rebuild) only the proxy image from the current network-proxy.js
build_proxy_image() {
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$SCRIPT_DIR/network-proxy.js" "$tmpdir/"
    cat > "$tmpdir/Containerfile" << 'DOCKERFILE'
FROM alpine:3.22
RUN apk add --no-cache nodejs
COPY network-proxy.js /usr/local/bin/network-proxy.js
RUN chmod +x /usr/local/bin/network-proxy.js
EXPOSE 8888
ENTRYPOINT ["node", "/usr/local/bin/network-proxy.js"]
DOCKERFILE
    echo "Building proxy image..."
    podman build --quiet -t claude-proxy -t localhost/claude-proxy -t localhost/claude-proxy:latest "$tmpdir" > /dev/null
    rm -rf "$tmpdir"
}

# Helper: start the proxy container on the host network.
# Using host network ensures full access to host DNS, VPNs, and Azure endpoints,
# while binding to port 8888 so agent containers can proxy through 127.0.0.1:8888.
start_proxy() {
    podman run -d \
        --pull=never \
        --name "$PROXY_CONTAINER" \
        --network host \
        -v "$ACTIVE_RULES_FILE:/etc/claude-network-rules.txt:ro,z" \
        -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
        -e PROXY_PORT="$PROXY_PORT" \
        "$PROXY_IMAGE" \
        /etc/claude-network-rules.txt &>/dev/null
}

PROXY_PORT=8888

# 2. Ensure the shared proxy container is running with current rules & environment.
if podman container inspect "$PROXY_CONTAINER" &>/dev/null; then
    echo "Refreshing network proxy container ($PROXY_CONTAINER)..."
    podman rm -f "$PROXY_CONTAINER" &>/dev/null || true
fi
echo "Starting network proxy container ($PROXY_CONTAINER)..."
start_proxy


# Health-check: give the proxy up to 3s to start.
sleep 1.5
if ! podman container inspect -f '{{.State.Running}}' "$PROXY_CONTAINER" 2>/dev/null | grep -q true; then
    PROXY_LOGS=$(podman logs "$PROXY_CONTAINER" 2>&1 || true)
    # Likely a stale image bug — rebuild from current network-proxy.js and retry once.
    echo "Proxy container exited — rebuilding proxy image and retrying..."
    echo "Proxy logs: $PROXY_LOGS" >&2
    podman rm -f "$PROXY_CONTAINER" &>/dev/null || true
    build_proxy_image
    PROXY_IMAGE="localhost/claude-proxy:latest"
    start_proxy
    sleep 2
    if ! podman container inspect -f '{{.State.Running}}' "$PROXY_CONTAINER" 2>/dev/null | grep -q true; then
        echo "Error: proxy container failed to start. Logs:" >&2
        podman logs "$PROXY_CONTAINER" >&2 2>/dev/null || true
        exit 1
    fi
fi

# 3. Proxy URL: agent container connects via host loopback proxy
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
echo "Proxy URL: $PROXY_URL"



TEMP_CLAUDE_MD=$(mktemp)
echo "Enriched CLAUDE.md file: $TEMP_CLAUDE_MD"
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    echo "Using global CLAUDE.md file: $HOME/.claude/CLAUDE.md"
    cat "$HOME/.claude/CLAUDE.md" > "$TEMP_CLAUDE_MD"
    echo "" >> "$TEMP_CLAUDE_MD"
fi

cat >> "$TEMP_CLAUDE_MD" << EOF

# Container Environment Context

- **Operating System**: Alpine Linux (package manager: \`apk\`).
- **Network Access**: Outbound network connections are proxied and restricted to allowed destinations defined in the network rules configuration.
EOF

if [[ -n "$PROJECT_RULES_FILE" && -f "$PROJECT_RULES_FILE" ]]; then
    cat >> "$TEMP_CLAUDE_MD" << EOF
- **Network Rules File**: \`$PROJECT_RULES_FILE\`

Allowed network rules:
\`\`\`
$(cat "$PROJECT_RULES_FILE")
\`\`\`
EOF
else
    cat >> "$TEMP_CLAUDE_MD" << EOF
- **Network Rules File**: None specified (default network proxy rules apply).
EOF
fi

CLAUDE_MD_ARGS=(-v "$TEMP_CLAUDE_MD:/home/claude/.claude/CLAUDE.md:ro,z")

ENV_ARGS=()
if [[ -f "$(pwd)/.env" ]]; then
    ENV_ARGS+=(--env-file "$(pwd)/.env")
elif [[ -f "$HOME/.config/claude-podman/.env" ]]; then
    ENV_ARGS+=(--env-file "$HOME/.config/claude-podman/.env")
fi

# Automatically forward credentials matching common MCP prefixes if present in host environment
for var in $(env | grep -E '^(MCP_|ATLASSIAN_|GITHUB_|SLACK_)' | cut -d= -f1); do
    ENV_ARGS+=("-e" "$var")
done

AGENT_NET_ARGS=(--network host)

# 3. Check if podman version is >= 4.3.0 to support keep-id mapping to container UID/GID 1000
PODMAN_VERSION=$(podman --version 2>/dev/null | awk '{print $3}' || echo "0.0.0")
IFS='.' read -r major minor patch <<< "$PODMAN_VERSION" || true
major=$(echo "${major:-0}" | tr -dc '0-9')
minor=$(echo "${minor:-0}" | tr -dc '0-9')
major=${major:-0}
minor=${minor:-0}

USERNS_ARG="--userns=keep-id"
if [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -ge 3 ]]; }; then
    USERNS_ARG="--userns=keep-id:uid=1000,gid=1000"
fi

# 4. Launch agent container connected to podman network
podman run --rm -it \
    --name "$SESSION_ID" \
    --pull=never \
    "$USERNS_ARG" \
    ${AGENT_NET_ARGS+"${AGENT_NET_ARGS[@]}"} \
    -v "$(pwd):/workspace:z" \
    -v "$STATE_DIR:/home/claude/.claude:z" \
    ${CLAUDE_MD_ARGS+"${CLAUDE_MD_ARGS[@]}"} \
    ${ENV_ARGS+"${ENV_ARGS[@]}"} \
    -w /workspace \
    -e HTTP_PROXY="$PROXY_URL" \
    -e HTTPS_PROXY="$PROXY_URL" \
    -e http_proxy="$PROXY_URL" \
    -e https_proxy="$PROXY_URL" \
    -e ALL_PROXY="$PROXY_URL" \
    -e all_proxy="$PROXY_URL" \
    -e NO_PROXY="127.0.0.1,localhost" \
    -e no_proxy="127.0.0.1,localhost" \
    -e CLAUDE_CODE_USE_FOUNDRY=1 \
    -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
    -e ANTHROPIC_FOUNDRY_AUTH_TOKEN="$AZURE_TOKEN" \
    -e PIP_BREAK_SYSTEM_PACKAGES=1 \
    "$CODE_IMAGE" \
    claude --dangerously-skip-permissions --model claude-sonnet-4-6 "$@"
