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

if ! command -v podman &>/dev/null; then
    echo "Podman not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y podman
fi

PROXY_IMAGE_NAME="localhost/claude-proxy"
CODE_IMAGE_NAME="localhost/claude-code"

WAS_MACHINE_RUNNING=true
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v podman &>/dev/null; then
        echo "Error: podman command not found. Please install Podman first (e.g. 'brew install podman')."
        exit 1
    fi
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

TMPDIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMPDIR"
    if [[ "${WAS_MACHINE_RUNNING:-true}" == "false" && "$(uname)" == "Darwin" ]]; then
        echo "Stopping Podman machine..."
        podman machine stop &>/dev/null || true
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
if podman container inspect claude-proxy &>/dev/null; then
    echo "Removing existing 'claude-proxy' container to apply new proxy image..."
    podman rm -f claude-proxy &>/dev/null || true
    # Kill any zombie rootlessport process left behind by the removed container.
    ZOMBIE=$(ss -tlnp 2>/dev/null | grep ':8888[[:space:]]' | grep 'rootlessport' \
        | grep -oP '(?<=pid=)\d+' | head -1 || true)
    if [[ -n "$ZOMBIE" ]]; then
        echo "Cleaning up zombie rootlessport process (pid=$ZOMBIE) on port 8888..."
        kill "$ZOMBIE" 2>/dev/null || true
        sleep 0.5
    fi
fi
podman build -t claude-proxy -t localhost/claude-proxy -t localhost/claude-proxy:latest "$TMPDIR/proxy"

# 2. Build claude-code image
mkdir -p "$TMPDIR/code"

# Discover Claude configuration file (for MCP servers and custom settings)
CONFIG_FILE=""
if [[ -n "${CLAUDE_CONFIG_FILE:-}" && -f "$CLAUDE_CONFIG_FILE" ]]; then
    CONFIG_FILE="$CLAUDE_CONFIG_FILE"
elif [[ -f "$(pwd)/.claude.json" ]]; then
    CONFIG_FILE="$(pwd)/.claude.json"
elif [[ -f "$(pwd)/claude.local.json" ]]; then
    CONFIG_FILE="$(pwd)/claude.local.json"
elif [[ -f "$(pwd)/claude.json" ]]; then
    CONFIG_FILE="$(pwd)/claude.json"
elif [[ -f "$HOME/.config/claude-podman/claude.json" ]]; then
    CONFIG_FILE="$HOME/.config/claude-podman/claude.json"
elif [[ -f "$SCRIPT_DIR/.claude.json" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/.claude.json"
elif [[ -f "$SCRIPT_DIR/claude.json" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/claude.json"
fi

if [[ -n "$CONFIG_FILE" ]]; then
    echo "Using Claude config file: $CONFIG_FILE"
    cp "$CONFIG_FILE" "$TMPDIR/code/user-config.json"
else
    echo "{}" > "$TMPDIR/code/user-config.json"
fi

cat > "$TMPDIR/code/Containerfile" << 'EOF'
FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    curl \
    git \
    nodejs \
    npm \
    python3 \
    py3-pip \
    py3-setuptools \
    py3-wheel \
    py3-lxml \
    py3-pillow \
    build-base \
    python3-dev \
    ca-certificates && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED

ENV PIP_BREAK_SYSTEM_PACKAGES=1


RUN npm install -g \
    @modelcontextprotocol/server-filesystem \
    @modelcontextprotocol/server-memory

RUN adduser -D -u 1000 -s /bin/bash claude

USER claude
WORKDIR /home/claude

COPY --chown=claude:claude user-config.json /home/claude/user-config.json

RUN curl -fsSL https://claude.ai/install.sh | bash && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile && \
    mkdir -p ~/.claude && \
    echo '{"theme":"dark"}' > ~/.claude/settings.json && \
    python3 -c 'import json; base = {"hasCompletedOnboarding": True, "projects": {"/workspace": {"hasTrustDialogAccepted": True}}, "mcpServers": {"filesystem": {"command": "mcp-server-filesystem", "args": ["/workspace"]}, "memory": {"command": "mcp-server-memory"}}}; user = json.load(open("user-config.json")); mcp = base.get("mcpServers", {}); mcp.update(user.get("mcpServers", {})); base.update(user); base["mcpServers"] = mcp; json.dump(base, open(".claude.json", "w"), indent=2)' && \
    rm -f user-config.json

ENV PATH="/home/claude/.local/bin:$PATH"

CMD ["/bin/bash"]
EOF

echo "Building agent image '${CODE_IMAGE_NAME}' from Alpine Linux..."
podman build -t claude-code -t localhost/claude-code -t localhost/claude-code:latest "$TMPDIR/code"

mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/claude-podman.sh" ~/.local/bin/claude-podman

echo ""
echo "Images '${PROXY_IMAGE_NAME}' and '${CODE_IMAGE_NAME}' built successfully."
echo "Run 'claude-podman' from anywhere to start."
