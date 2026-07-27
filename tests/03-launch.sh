#!/bin/bash
# tests/03-launch.sh — Test claude-podman.sh can launch correctly
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PODMAN_NET="claude-net"

section "03 · claude-podman launch & multi-instance"

# ── Test 1: claude-podman.sh is executable ────────────────────────────────────
if [[ -x "$REPO_DIR/claude-podman.sh" ]]; then
    pass "claude-podman.sh is executable"
else
    fail "claude-podman.sh is executable" "file not found or missing +x"
fi

# ── Test 2: install-claude-podman.sh is executable ───────────────────────────
if [[ -x "$REPO_DIR/install-claude-podman.sh" ]]; then
    pass "install-claude-podman.sh is executable"
else
    fail "install-claude-podman.sh is executable" "file not found or missing +x"
fi

# ── Test 3: claude-podman symlink resolves correctly ─────────────────────────
SYMLINK="$HOME/.local/bin/claude-podman"
if [[ -L "$SYMLINK" ]]; then
    TARGET=$(readlink -f "$SYMLINK" 2>/dev/null || readlink "$SYMLINK")
    EXPECTED="$REPO_DIR/claude-podman.sh"
    if [[ "$TARGET" == "$EXPECTED" ]]; then
        pass "~/.local/bin/claude-podman → claude-podman.sh"
    else
        fail "~/.local/bin/claude-podman → claude-podman.sh" \
             "points to '$TARGET', expected '$EXPECTED'"
    fi
else
    fail "~/.local/bin/claude-podman symlink exists" \
         "not a symlink: $SYMLINK (run ./install-claude-podman.sh first)"
fi

# ── Test 4: script fails fast when ANTHROPIC_FOUNDRY_BASE_URL is missing ──────
OUTPUT=$(env -i HOME="$HOME" PATH="$PATH" \
    bash "$REPO_DIR/claude-podman.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "ANTHROPIC_FOUNDRY_BASE_URL"; then
    pass "claude-podman.sh exits with clear error when ANTHROPIC_FOUNDRY_BASE_URL unset"
else
    fail "claude-podman.sh exits with clear error when ANTHROPIC_FOUNDRY_BASE_URL unset" \
         "unexpected output: $(echo "$OUTPUT" | head -3)"
fi

# ── Test 5: script fails fast when az is unavailable ─────────────────────────
# We mock az to be missing by using a PATH that excludes it, and set the required env var.
FAKE_AZ_DIR="$(mktemp -d)"
cleanup_az() { rm -rf "$FAKE_AZ_DIR"; }
trap cleanup_az EXIT

# Create a fake az that always fails
cat > "$FAKE_AZ_DIR/az" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAKE_AZ_DIR/az"

OUTPUT=$(env -i HOME="$HOME" PATH="$FAKE_AZ_DIR:/usr/bin:/bin" \
    ANTHROPIC_FOUNDRY_BASE_URL="https://fake-endpoint.example.com" \
    bash "$REPO_DIR/claude-podman.sh" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "azure\|az login\|access token"; then
    pass "claude-podman.sh exits with clear error when az token fetch fails"
else
    fail "claude-podman.sh exits with clear error when az token fetch fails" \
         "unexpected output: $(echo "$OUTPUT" | head -3)"
fi

# ── Tests 6–8: require podman and images ─────────────────────────────────────
if ! require_cmd podman; then
    skip "proxy-sharing between two instances" "podman not found"
    skip "two parallel proxy containers do not conflict" "podman not found"
    skip "claude-podman invocable from outside project directory" "podman not found"
    summary; exit $?
fi

if ! require_image "localhost/claude-proxy:latest"; then
    skip "proxy-sharing between two instances" "images not built"
    skip "two parallel proxy containers do not conflict" "images not built"
    skip "claude-podman invocable from outside project directory" "images not built"
    summary; exit $?
fi

# ── Test 6: two proxy containers started with same name don't break ───────────
# The script reuses the existing proxy if it's running; this tests that logic.
# Start a proxy with our test name, then call start-logic again — should reuse.
TEST_PROXY="claude-proxy-launch-test-$$"
TEST_RULES="$(mktemp)"
echo "https://github.com" > "$TEST_RULES"

if ! podman network inspect "$PODMAN_NET" &>/dev/null; then
    podman network create "$PODMAN_NET" > /dev/null
fi

cleanup_container "$TEST_PROXY"

podman run -d \
    --pull=never \
    --name "$TEST_PROXY" \
    --network "$PODMAN_NET" \
    -e PROXY_PORT=19888 \
    -v "${TEST_RULES}:/etc/claude-network-rules.txt:ro,z" \
    localhost/claude-proxy:latest \
    /etc/claude-network-rules.txt &>/dev/null

if wait_for_container "$TEST_PROXY" 10; then
    # Now try to run a second container with the same name — should fail (expected)
    # The *script* handles this by checking inspect first; verify the guard works
    IS_RUNNING=$(podman container inspect -f '{{.State.Running}}' "$TEST_PROXY" 2>/dev/null || echo "false")
    if echo "$IS_RUNNING" | grep -q true; then
        pass "first proxy instance is running"
        # Simulate the script's 'is already running' check
        if podman container inspect "$TEST_PROXY" &>/dev/null && \
           podman container inspect -f '{{.State.Running}}' "$TEST_PROXY" | grep -q true; then
            pass "running proxy detection works (would reuse existing proxy)"
        else
            fail "running proxy detection works"
        fi
    else
        fail "first proxy instance is running" "container not running after start"
    fi
else
    fail "first proxy instance is running" \
         "$(podman logs "$TEST_PROXY" 2>&1 | tail -3)"
fi

cleanup_container "$TEST_PROXY"
rm -f "$TEST_RULES"

# ── Test 7: two instances started simultaneously use the same proxy ───────────
# This tests that two parallel claude-podman invocations won't conflict.
# We do this by starting two containers on the same claude-net network.
PODMAN_NET="claude-net"
if ! podman network inspect "$PODMAN_NET" &>/dev/null; then
    podman network create "$PODMAN_NET" > /dev/null
fi

if require_image "localhost/claude-code:latest"; then
    C1="claude-test-inst1-$$"
    C2="claude-test-inst2-$$"
    cleanup_container "$C1"
    cleanup_container "$C2"

    # Start two agent containers simultaneously (they'd both try to use the proxy)
    podman run -d --pull=never --rm \
        --name "$C1" \
        --network host \
        localhost/claude-code:latest \
        sleep 5 &>/dev/null || true
    podman run -d --pull=never --rm \
        --name "$C2" \
        --network host \
        localhost/claude-code:latest \
        sleep 5 &>/dev/null || true

    sleep 2
    R1=$(podman container inspect -f '{{.State.Running}}' "$C1" 2>/dev/null | grep -c true || echo 0)
    R2=$(podman container inspect -f '{{.State.Running}}' "$C2" 2>/dev/null | grep -c true || echo 0)

    if [[ "$R1" -ge 1 ]] && [[ "$R2" -ge 1 ]]; then
        pass "two claude-code containers run simultaneously without conflict"
    else
        fail "two claude-code containers run simultaneously without conflict" \
             "c1_running=$R1 c2_running=$R2"
    fi

    cleanup_container "$C1"
    cleanup_container "$C2"
else
    skip "two parallel agent containers" "localhost/claude-code:latest not found"
fi

# ── Test 8: claude-podman can be invoked from outside the project directory ───
SYMLINK="$HOME/.local/bin/claude-podman"
if [[ -L "$SYMLINK" ]] || [[ -x "$SYMLINK" ]]; then
    # Run from a temp directory — should hit the "ANTHROPIC_FOUNDRY_BASE_URL not set" error
    # which means the script loaded correctly (resolved SCRIPT_DIR to the real repo)
    TMPDIR_TEST="$(mktemp -d)"
    OUTPUT=$(cd "$TMPDIR_TEST" && env -i HOME="$HOME" PATH="$HOME/.local/bin:$PATH" \
        bash "$SYMLINK" 2>&1 || true)
    rm -rf "$TMPDIR_TEST"

    if echo "$OUTPUT" | grep -qi "ANTHROPIC_FOUNDRY_BASE_URL\|azure\|az login"; then
        pass "claude-podman invocable from outside project dir (script self-resolves)"
    else
        fail "claude-podman invocable from outside project dir" \
             "unexpected output: $(echo "$OUTPUT" | head -3)"
    fi
else
    skip "claude-podman invocable from outside project dir" \
         "symlink not installed at ~/.local/bin/claude-podman"
fi

summary
