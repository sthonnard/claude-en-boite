# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo contains two shell scripts for running Claude Code inside a rootless Podman container, authenticated via Azure AI Foundry (Eurocontrol's managed AI gateway).

- `install-claude-podman.sh` — builds a `claude-code` Podman image from Alpine Linux with Node.js, Python, Claude Code CLI, and pre-configured MCP servers.
- `claude-podman.sh` — fetches an Azure access token and launches a Claude Code session in the container, mounting the current directory as `/workspace`.

## Usage

```bash
# One-time: build the container image
./install-claude-podman.sh

# Run Claude Code in a container
./claude-podman.sh [claude-args...]
```

`claude-podman.sh` requires `az` (Azure CLI) to be installed and authenticated (`az login`). It fetches a Cognitive Services token and passes it to the container via `ANTHROPIC_FOUNDRY_AUTH_TOKEN`.

## Key design points

- The container runs as the current user (`--userns=keep-id`) to avoid file permission issues on the mounted volume.
- On macOS, the default Podman machine is automatically initialized/started if missing or stopped, and stopped when the script finishes.
- Host `~/.claude/CLAUDE.md` (if present) is enriched with container context (Alpine Linux OS details and network rule configuration) and mounted into the container as `/home/claude/.claude/CLAUDE.md`.
- `--dangerously-skip-permissions` is passed by default; the container isolation is the security boundary.
- The Azure endpoint is specified by the `ANTHROPIC_FOUNDRY_BASE_URL` environment variable, with `CLAUDE_CODE_USE_FOUNDRY=1`.
- Network egress is filtered by a shared Podman sidecar container (`claude-proxy`) running `network-proxy.js` on a shared Podman bridge network (`claude-net`), allowing multiple parallel `claude-podman` instances across projects to share the network proxy while enforcing domain and wildcard allow rules.

## Mandatory: test after every code change

**You must run the test suite after every change to any script or configuration file. Do not consider a task done until the tests pass.**

The test suite lives in `tests/`. Run it from the repo root:

```bash
# Make executable (first time only)
chmod +x tests/*.sh

# Fast: proxy + launch tests only (no Azure needed, no image rebuild)
./tests/run-tests.sh --skip-build

# Proxy tests only (fastest — use this when touching network-proxy.js or claude-podman.sh)
./tests/02-proxy.sh

# Full suite including image rebuild
./tests/run-tests.sh --force-build
```

Rules:
- After changing `network-proxy.js` or `claude-podman.sh`: run `./tests/02-proxy.sh` **and** `./tests/03-launch.sh`.
- After changing `install-claude-podman.sh`: run `./tests/01-install.sh`.
- After any change: run `./tests/run-tests.sh --skip-build` at minimum.
- If the test runner itself cannot be executed (e.g. tool sandbox failure), **say so explicitly** and ask the user to run it. Do not silently skip verification.
