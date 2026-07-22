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

This creates a local `claude-code` image based on Alpine Linux with Node.js, Python, pre-installed MCP servers, and the Claude Code CLI. It also installs a `claude-podman` symlink into `~/.local/bin/` so the command is available system-wide.

### MCP & Claude Configuration Resolution

During image build (`install-claude-podman.sh`), Claude settings and MCP server definitions are loaded from the first existing config file in the following order:
1. `$CLAUDE_CONFIG_FILE` (environment variable path)
2. `./.claude.json` or `./claude.local.json` (local project override, gitignored)
3. `./claude.json` (current workspace default)
4. `~/.config/claude-podman/claude.json` (global user configuration)
5. Default [`claude.json`](claude.json) in the repository

Example `claude.json`:
```json
{
  "mcpServers": {
    "atlassian": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp"
    }
  }
}
```


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

## Network Security Rules

`claude-podman` runs outbound network security filtering inside a **dedicated Podman proxy container** (`claude-proxy`). The agent container (`claude-code`) cannot inspect, tamper with, or kill the proxy server process, and has no access to the rules configuration file.

### Configuration File Resolution

Rules are loaded from the first existing config file in the following order:
1. `$NETWORK_RULES_FILE` (environment variable path)
2. `./.claude-network-rules` or `./network-rules.local.txt` (local project override, gitignored)
3. `./network-rules.txt` (current workspace default)
4. `~/.config/claude-podman/network-rules.txt` (global user configuration)
5. Default [`network-rules.txt`](network-rules.txt) in the repository

### Rule Format & Examples

Edit your rules file using scheme, hostname, port, and wildcard (`*`) patterns:

```text
# Allow all HTTPS traffic
https://*

# Allow specific endpoint
https://www.google.com

# Allow domain and all subdomains
https://*.azure.com
https://*.github.com

# Allow local HTTP services
http://localhost:*

# Allow all traffic across all schemes
*
```

> [!NOTE]
> The Azure AI Foundry endpoint specified by `ANTHROPIC_FOUNDRY_BASE_URL` is automatically allowed so Claude Code authentication works without manual rule entries.

## How it works

| Component | Detail |
|---|---|
| Base image | `alpine:3.22` |
| Agent container | `claude-code` — runs Claude Code as unprivileged user `claude` (UID 1000) |
| Proxy container | `claude-proxy` — isolated sidecar container running `network-proxy.js` on port 8888 |
| Podman Network | Ephemeral `claude-net-<session_id>` bridge network linking agent and proxy containers |
| Userns | `keep-id` — files created in the container are owned by the host user |
| AI endpoint | Loaded from host `$ANTHROPIC_FOUNDRY_BASE_URL` environment variable |
| Auth | Azure Cognitive Services bearer token (refreshed each run) |
| Permissions | `--dangerously-skip-permissions` — container isolation is the security boundary |



## Troubleshooting

- **`ANTHROPIC_FOUNDRY_BASE_URL environment variable is not set`** — define `ANTHROPIC_FOUNDRY_BASE_URL` in your terminal environment before running.
- **`az account get-access-token` fails** — run `az login` first.
- **Token expired mid-session** — restart the script; it fetches a fresh token each run.
- **File permission issues** — ensure `--userns=keep-id` is supported by your Podman version (`podman --version` ≥ 3.0).
