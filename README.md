# claude-en-boite

Run [Claude Code](https://claude.ai/code) inside a rootless Podman container, authenticated via Azure AI Foundry.

## Prerequisites

This tool requires **Podman** and the **Azure CLI**. Follow the instructions below to install them:

> [!NOTE]
> **Windows Users**: The scripts in this repository are written for Unix/macOS environments. If you are running on Windows, you can ask Claude to adapt the bash scripts (`install-claude-podman.sh` and `claude-podman.sh`) to PowerShell or Batch scripts.

### 1. Podman
* **macOS** (via Homebrew):
  ```bash
  brew install podman
  podman machine init
  ```
  *(Note: The `claude-podman` script will automatically start the Podman machine if it is stopped, and stop it once the session ends.)*
* **Ubuntu / Debian**:
  ```bash
  sudo apt-get update && sudo apt-get install -y podman
  ```
  *(Note: `install-claude-podman.sh` will automatically attempt to install it on Debian/Ubuntu systems if it is missing)*

### 2. Azure CLI
* **macOS** (via Homebrew):
  ```bash
  brew install azure-cli
  ```
* **Ubuntu / Debian**:
  ```bash
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  ```

Once installed, authenticate your Azure CLI session:
```bash
az login
```

### 3. Environment Variable
Define the `ANTHROPIC_FOUNDRY_BASE_URL` environment variable on your host system:
```bash
export ANTHROPIC_FOUNDRY_BASE_URL="https://blablabla-ai-gate.azure-api.net/ai/anthropic"
```

## Setup

Build the container image once:

```bash
./install-claude-podman.sh
```

This creates a local `claude-code` image based on Alpine Linux with Node.js and the Claude Code CLI, and installs a `claude-podman` symlink into `~/.local/bin/` so the command is available system-wide.

## Usage

From any project directory:

```bash
claude-podman
```

The script:
1. Fetches a short-lived Azure Cognitive Services token via `az account get-access-token`
2. Mounts the current directory into the container as `/workspace`
3. Optionally mounts `~/.claude/CLAUDE.md` from the host for global instructions
4. Launches an interactive Claude Code session against the Azure AI Foundry endpoint

Any extra arguments are forwarded to `claude`:

```bash
claude-podman "explain this codebase"
```

## How it works

| Component | Detail |
|---|---|
| Base image | `alpine:3.22` |
| Claude user | `claude` (UID 1000) |
| Userns | `keep-id` — files created in the container are owned by the host user |
| AI endpoint | Loaded from host `$ANTHROPIC_FOUNDRY_BASE_URL` environment variable |
| Auth | Azure Cognitive Services bearer token (refreshed each run) |
| Permissions | `--dangerously-skip-permissions` — container isolation is the security boundary |

## Troubleshooting

- **`ANTHROPIC_FOUNDRY_BASE_URL environment variable is not set`** — define `ANTHROPIC_FOUNDRY_BASE_URL` in your terminal environment before running.
- **`az account get-access-token` fails** — run `az login` first.
- **Token expired mid-session** — restart the script; it fetches a fresh token each run.
- **File permission issues** — ensure `--userns=keep-id` is supported by your Podman version (`podman --version` ≥ 3.0).
