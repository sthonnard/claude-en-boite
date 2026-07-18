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

cleanup() {
    if [[ "$WAS_MACHINE_RUNNING" == "false" ]]; then
        echo "Stopping Podman machine..."
        podman machine stop
    fi
}
trap cleanup EXIT

CLAUDE_MD_ARGS=()
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    CLAUDE_MD_ARGS+=(-v "$HOME/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro,z")
fi

podman run --rm -it \
    --userns=keep-id \
    -v "$(pwd):/workspace:z" \
    "${CLAUDE_MD_ARGS[@]}" \
    -w /workspace \
    -e CLAUDE_CODE_USE_FOUNDRY=1 \
    -e ANTHROPIC_FOUNDRY_BASE_URL="$ANTHROPIC_FOUNDRY_BASE_URL" \
    -e ANTHROPIC_FOUNDRY_AUTH_TOKEN="$AZURE_TOKEN" \
    claude-code \
    claude --dangerously-skip-permissions --model claude-sonnet-4-6 "$@"
