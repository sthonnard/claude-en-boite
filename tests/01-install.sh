#!/bin/bash
# tests/01-install.sh — Test that install-claude-podman.sh works correctly
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FORCE_BUILD="${FORCE_BUILD:-false}"

section "01 · install-claude-podman.sh"

# ── Guard: need podman ────────────────────────────────────────────────────────
if ! require_cmd podman; then
    skip "podman available" "podman not found in PATH"
    skip "proxy image exists" "podman not found"
    skip "code image exists" "podman not found"
    skip "claude-podman symlink exists" "podman not found"
    summary; exit $?
fi

# ── Test 1: install script is executable ──────────────────────────────────────
if [[ -x "$REPO_DIR/install-claude-podman.sh" ]]; then
    pass "install-claude-podman.sh is executable"
else
    fail "install-claude-podman.sh is executable" "file not found or not executable"
fi

# ── Test 2: run install (or skip if images exist and not forcing) ─────────────
PROXY_EXISTS=false
CODE_EXISTS=false
require_image "localhost/claude-proxy:latest" && PROXY_EXISTS=true
require_image "localhost/claude-code:latest"  && CODE_EXISTS=true

if [[ "$FORCE_BUILD" == "true" ]] || [[ "$PROXY_EXISTS" == "false" ]] || [[ "$CODE_EXISTS" == "false" ]]; then
    echo "  Running install-claude-podman.sh (this may take several minutes)..."
    if "$REPO_DIR/install-claude-podman.sh" 2>&1 | sed 's/^/    /'; then
        pass "install-claude-podman.sh exits 0"
    else
        fail "install-claude-podman.sh exits 0" "script returned non-zero"
        # Don't run subsequent image checks
        summary; exit $?
    fi
else
    skip "install-claude-podman.sh runs cleanly" "images already exist (run with FORCE_BUILD=true to rebuild)"
fi

# ── Test 3: proxy image exists ────────────────────────────────────────────────
if require_image "localhost/claude-proxy:latest"; then
    pass "localhost/claude-proxy:latest image exists"
else
    fail "localhost/claude-proxy:latest image exists" "image not found after install"
fi

# ── Test 4: code image exists ─────────────────────────────────────────────────
if require_image "localhost/claude-code:latest"; then
    pass "localhost/claude-code:latest image exists"
else
    fail "localhost/claude-code:latest image exists" "image not found after install"
fi

# ── Test 5: claude-podman symlink is created ──────────────────────────────────
SYMLINK="$HOME/.local/bin/claude-podman"
if [[ -L "$SYMLINK" ]]; then
    TARGET=$(readlink -f "$SYMLINK" 2>/dev/null || readlink "$SYMLINK")
    if [[ "$TARGET" == "$REPO_DIR/claude-podman.sh" ]]; then
        pass "~/.local/bin/claude-podman symlink → claude-podman.sh"
    else
        fail "~/.local/bin/claude-podman symlink → claude-podman.sh" "points to '$TARGET' instead"
    fi
else
    fail "~/.local/bin/claude-podman symlink exists" "not a symlink: $SYMLINK"
fi

# ── Test 6: claude-podman is on PATH ─────────────────────────────────────────
if require_cmd claude-podman; then
    pass "claude-podman is on PATH"
else
    # Try adding ~/.local/bin (it may not be in PATH in this shell)
    export PATH="$HOME/.local/bin:$PATH"
    if require_cmd claude-podman; then
        pass "claude-podman is on PATH (via ~/.local/bin)"
    else
        fail "claude-podman is on PATH" "not found; ensure ~/.local/bin is in your PATH"
    fi
fi

summary
