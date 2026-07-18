# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo contains two shell scripts for running Claude Code inside a rootless Podman container, authenticated via Azure AI Foundry (Eurocontrol's managed AI gateway).

- `install_claude_podman.sh` — builds a `claude-code` Podman image from Alpine Linux with Node.js and Claude Code CLI installed.
- `claude_podman.sh` — fetches an Azure access token and launches a Claude Code session in the container, mounting the current directory as `/workspace`.

## Usage

```bash
# One-time: build the container image
./install_claude_podman.sh

# Run Claude Code in a container
./claude_podman.sh [claude-args...]
```

`claude_podman.sh` requires `az` (Azure CLI) to be installed and authenticated (`az login`). It fetches a Cognitive Services token and passes it to the container via `ANTHROPIC_FOUNDRY_AUTH_TOKEN`.

## Key design points

- The container runs as the current user (`--userns=keep-id`) to avoid file permission issues on the mounted volume.
- On macOS, the default Podman machine is automatically started if it is stopped, and stopped when the session terminates.
- `~/.claude/CLAUDE.md` from the host is optionally bind-mounted into the container so global instructions are preserved.
- `--dangerously-skip-permissions` is passed by default; the container isolation is the security boundary.
- The Azure endpoint is specified by the `ANTHROPIC_FOUNDRY_BASE_URL` environment variable, with `CLAUDE_CODE_USE_FOUNDRY=1`.
