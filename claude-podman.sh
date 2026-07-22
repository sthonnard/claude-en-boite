#!/bin/bash
set -euo pipefail

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

# Check that required images exist locally
if ! podman image exists claude-proxy &>/dev/null || ! podman image exists claude-code &>/dev/null; then
    echo "Error: Required Podman images ('claude-proxy' and/or 'claude-code') were not found." >&2
    echo "Please run './install-claude-podman.sh' first to build the images." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Discover network rules file
RULES_FILE=""
if [[ -n "${NETWORK_RULES_FILE:-}" && -f "$NETWORK_RULES_FILE" ]]; then
    RULES_FILE="$NETWORK_RULES_FILE"
elif [[ -f "$(pwd)/.claude-network-rules" ]]; then
    RULES_FILE="$(pwd)/.claude-network-rules"
elif [[ -f "$(pwd)/network-rules.local.txt" ]]; then
    RULES_FILE="$(pwd)/network-rules.local.txt"
elif [[ -f "$(pwd)/network-rules.txt" ]]; then
    RULES_FILE="$(pwd)/network-rules.txt"
elif [[ -f "$HOME/.config/claude-podman/network-rules.txt" ]]; then
    RULES_FILE="$HOME/.config/claude-podman/network-rules.txt"
elif [[ -f "$SCRIPT_DIR/network-rules.txt" ]]; then
    RULES_FILE="$SCRIPT_DIR/network-rules.txt"
fi

SESSION_ID="claude-$$"
PODMAN_NET="claude-net-$SESSION_ID"
PROXY_CONTAINER="claude-proxy-$SESSION_ID"
TEMP_CLAUDE_MD=""

cleanup() {
    echo "Cleaning up network proxy and resources..."
    podman rm -f "$PROXY_CONTAINER" &>/dev/null || true
    podman network rm "$PODMAN_NET" &>/dev/null || true
    if [[ -n "${TEMP_CLAUDE_MD:-}" && -f "$TEMP_CLAUDE_MD" ]]; then
        rm -f "$TEMP_CLAUDE_MD"
    fi

    if [[ "${WAS_MACHINE_RUNNING:-true}" == "false" && "$(uname)" == "Darwin" ]]; then
        echo "Stopping Podman machine..."
        podman machine stop &>/dev/null || true
    fi
}
trap cleanup EXIT

# 1. Create session network
podman network create "$PODMAN_NET" >/dev/null

# 2. Launch proxy container
PROXY_MOUNT_ARGS=()
if [[ -n "$RULES_FILE" ]]; then
    PROXY_MOUNT_ARGS+=(-v "$RULES_FILE:/etc/claude-network-rules.txt:ro,z")
fi

echo "Starting network proxy container ($PROXY_CONTAINER)..."
podman run -d \
    --pull=never \
    --name "$PROXY_CONTAINER" \
    --network "$PODMAN_NET" \
    -p 127.0.0.1:8888:8888 \
    ${PROXY_MOUNT_ARGS+"${PROXY_MOUNT_ARGS[@]}"} \
    -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
    claude-proxy \
    /etc/claude-network-rules.txt >/dev/null

sleep 0.5

# Persistent state directory for OAuth tokens, MCP settings, and session cache
STATE_DIR="$HOME/.config/claude-podman/state"
echo "Using STATE_DIR: $STATE_DIR"
mkdir -p "$STATE_DIR"

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

if [[ -n "$RULES_FILE" ]]; then
    cat >> "$TEMP_CLAUDE_MD" << EOF
- **Network Rules File**: \`$RULES_FILE\`

Allowed network rules:
\`\`\`
$(cat "$RULES_FILE")
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

AGENT_NET_ARGS=()
if [[ "$(uname)" == "Linux" ]]; then
    AGENT_NET_ARGS=(--network host)
    PROXY_URL="http://127.0.0.1:8888"
else
    AGENT_NET_ARGS=(--network "$PODMAN_NET")
    PROXY_URL="http://${PROXY_CONTAINER}:8888"
fi

# 3. Launch agent container connected to podman network
podman run --rm -it \
    --pull=never \
    --userns=keep-id \
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
    -e NO_PROXY="127.0.0.1,localhost,$PROXY_CONTAINER" \
    -e no_proxy="127.0.0.1,localhost,$PROXY_CONTAINER" \
    -e CLAUDE_CODE_USE_FOUNDRY=1 \
    -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
    -e ANTHROPIC_FOUNDRY_AUTH_TOKEN="$AZURE_TOKEN" \
    claude-code \
    claude --dangerously-skip-permissions --model claude-sonnet-4-6 "$@"
