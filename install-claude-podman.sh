#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v podman &>/dev/null; then
    echo "Podman not found, installing..."
    sudo apt-get update -qq && sudo apt-get install -y podman
fi

IMAGE_NAME="claude-code"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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
