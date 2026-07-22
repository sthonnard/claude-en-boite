#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v podman &>/dev/null; then
    echo "Podman not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y podman
fi

PROXY_IMAGE_NAME="claude-proxy"
CODE_IMAGE_NAME="claude-code"

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

# 1. Build claude-proxy image
mkdir -p "$TMPDIR/proxy"
cp "$SCRIPT_DIR/network-proxy.js" "$TMPDIR/proxy/"

cat > "$TMPDIR/proxy/Containerfile" << 'EOF'
FROM alpine:3.22

RUN apk add --no-cache nodejs

COPY network-proxy.js /usr/local/bin/network-proxy.js
RUN chmod +x /usr/local/bin/network-proxy.js

EXPOSE 8888
ENTRYPOINT ["node", "/usr/local/bin/network-proxy.js"]
EOF

echo "Building proxy image '${PROXY_IMAGE_NAME}'..."
podman build -t "$PROXY_IMAGE_NAME" "$TMPDIR/proxy"

# 2. Build claude-code image
mkdir -p "$TMPDIR/code"

cat > "$TMPDIR/code/Containerfile" << 'EOF'
FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    curl \
    nodejs \
    npm \
    python3 \
    py3-pip \
    ca-certificates && \
    ln -sf /usr/bin/python3 /usr/bin/python

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

echo "Building agent image '${CODE_IMAGE_NAME}' from Alpine Linux..."
podman build -t "$CODE_IMAGE_NAME" "$TMPDIR/code"

mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/claude-podman.sh" ~/.local/bin/claude-podman

echo ""
echo "Images '${PROXY_IMAGE_NAME}' and '${CODE_IMAGE_NAME}' built successfully."
echo "Run 'claude-podman' from anywhere to start."
