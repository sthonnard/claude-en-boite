#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v podman &>/dev/null; then
    echo "Podman not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y podman
fi

IMAGE_NAME="claude-code"

WAS_MACHINE_RUNNING=true
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v podman &>/dev/null; then
        echo "Error: podman command not found. Please install Podman first (e.g. 'brew install podman')."
        exit 1
    fi
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

TMPDIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMPDIR"
    if [[ "$WAS_MACHINE_RUNNING" == "false" ]]; then
        echo "Stopping Podman machine..."
        podman machine stop
    fi
}
trap cleanup EXIT


cat > "$TMPDIR/Containerfile" << 'EOF'
FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    curl \
    nodejs \
    npm \
    ca-certificates

RUN adduser -D -u 1000 -s /bin/bash claude

USER claude
WORKDIR /home/claude

RUN curl -fsSL https://claude.ai/install.sh | bash && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && \
    mkdir -p ~/.claude && \
    echo '{"theme":"dark"}' > ~/.claude/settings.json && \
    echo '{"hasCompletedOnboarding":true,"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > ~/.claude.json

ENV PATH="/home/claude/.local/bin:$PATH"

CMD ["/bin/bash"]
EOF

echo "Building image '${IMAGE_NAME}' from Alpine Linux..."
podman build -t "$IMAGE_NAME" "$TMPDIR"

mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/claude-podman.sh" ~/.local/bin/claude-podman

echo ""
echo "Image '${IMAGE_NAME}' built successfully."
echo "Run 'claude-podman' from anywhere to start."
