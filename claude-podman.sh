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
    if [[ "$MACHINE_STATE" != "running" ]]; then
        WAS_MACHINE_RUNNING=false
        if [[ "$MACHINE_STATE" == "not-found" ]]; then
            echo "Error: No Podman machine found. Please run 'podman machine init' first."
            exit 1
        fi
        echo "Starting Podman machine..."
        podman machine start
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Discover network rules file
RULES_FILE=""
if [[ -n "${NETWORK_RULES_FILE:-}" && -f "$NETWORK_RULES_FILE" ]]; then
    RULES_FILE="$NETWORK_RULES_FILE"
elif [[ -f "$(pwd)/network-rules.txt" ]]; then
    RULES_FILE="$(pwd)/network-rules.txt"
elif [[ -f "$(pwd)/.claude-network-rules" ]]; then
    RULES_FILE="$(pwd)/.claude-network-rules"
elif [[ -f "$HOME/.config/claude-podman/network-rules.txt" ]]; then
    RULES_FILE="$HOME/.config/claude-podman/network-rules.txt"
elif [[ -f "$SCRIPT_DIR/network-rules.txt" ]]; then
    RULES_FILE="$SCRIPT_DIR/network-rules.txt"
fi

SESSION_ID="claude-$$"
PODMAN_NET="claude-net-$SESSION_ID"
PROXY_CONTAINER="claude-proxy-$SESSION_ID"

cleanup() {
    echo "Cleaning up network proxy and resources..."
    podman rm -f "$PROXY_CONTAINER" &>/dev/null || true
    podman network rm "$PODMAN_NET" &>/dev/null || true

    if [[ "$WAS_MACHINE_RUNNING" == "false" && "$(uname)" == "Darwin" ]]; then
        echo "Stopping Podman machine..."
        podman machine stop
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
    --name "$PROXY_CONTAINER" \
    --network "$PODMAN_NET" \
    "${PROXY_MOUNT_ARGS[@]}" \
    -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
    claude-proxy \
    /etc/claude-network-rules.txt >/dev/null

sleep 0.5

CLAUDE_MD_ARGS=()
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    CLAUDE_MD_ARGS+=(-v "$HOME/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro,z")
fi

PROXY_URL="http://${PROXY_CONTAINER}:8888"

# 3. Launch agent container connected to podman network
podman run --rm -it \
    --userns=keep-id \
    --network "$PODMAN_NET" \
    -v "$(pwd):/workspace:z" \
    "${CLAUDE_MD_ARGS[@]}" \
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
