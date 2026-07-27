# claude-en-boite

Run [Claude Code](https://claude.ai/code) inside a rootless Podman container, authenticated via Azure AI Foundry, and with a limited internet connectivity.

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
  *(Note: The scripts will automatically initialize and start the Podman machine if missing, stopping it when execution finishes.)*
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
3. Passes an enriched `CLAUDE.md` to the container (including host instructions from `~/.claude/CLAUDE.md` if present, enriched with Alpine Linux environment and network rules context)
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

### Architecture Diagram

```mermaid
graph TD
    subgraph Host ["Host System"]
        subgraph Config ["Configuration & Auth"]
            Rules["Active Rules File<br>active-network-rules.txt"]
            AzureCLI["Azure CLI (az)<br>Fetches Access Token"]
        end

        subgraph Proxy ["Proxy Component"]
            ProxyCont["Shared Proxy Container<br>(claude-proxy)"]
            ProxyScript["network-proxy.js<br>(Binds to localhost:8888)"]
            ProxyCont -->|Runs| ProxyScript
            Rules -->|Volume Mounted - Read-Only| ProxyCont
        end

        subgraph Agents ["Parallel Agent Sessions"]
            subgraph AgentA ["Agent Session A (Project A)"]
                CodeA["Claude Code Container<br>(claude-code)"]
                WS_A["Project A Dir<br>(Mounted to /workspace)"]
                CodeA -.->|Mounts| WS_A
            end

            subgraph AgentB ["Agent Session B (Project B)"]
                CodeB["Claude Code Container<br>(claude-code)"]
                WS_B["Project B Dir<br>(Mounted to /workspace)"]
                CodeB -.->|Mounts| WS_B
            end
        end

        AzureCLI -->|Injects Bearer Token & Base URL| CodeA
        AzureCLI -->|Injects Bearer Token & Base URL| CodeB
        
        CodeA -->|HTTP/HTTPS Proxy traffic<br>via 127.0.0.1:8888| ProxyScript
        CodeB -->|HTTP/HTTPS Proxy traffic<br>via 127.0.0.1:8888| ProxyScript
    end

    subgraph WAN ["Internet / External Services"]
        AzureFoundry["Azure AI Foundry<br>(Eurocontrol Gateway)"]
        AllowedDomains["Allowed Domains<br>(GitHub, npm, pip, etc.)"]
        BlockedDomains["Unallowed Domains<br>(Blocked by Proxy)"]
    end

    ProxyScript -->|Allow / Forward| AzureFoundry
    ProxyScript -->|Allow / Forward| AllowedDomains
    ProxyScript -.->|Deny / Block| BlockedDomains
```

### Component Details

| Component | Detail |
|---|---|
| Base image | `alpine:3.22` |
| Agent container | `claude-code` — runs Claude Code as unprivileged user `claude` (UID 1000) |
| Proxy container | `claude-proxy` — isolated sidecar container running `network-proxy.js` on port 8888 |
| Podman Network | Shared `claude-net` bridge network linking agent containers and the shared proxy container |
| Userns | `keep-id` — files created in the container are owned by the host user |
| AI endpoint | Loaded from host `$ANTHROPIC_FOUNDRY_BASE_URL` environment variable |
| Auth | Azure Cognitive Services bearer token (refreshed each run) |
| Permissions | `--dangerously-skip-permissions` — container isolation is the security boundary |



## Troubleshooting

- **`ANTHROPIC_FOUNDRY_BASE_URL environment variable is not set`** — define `ANTHROPIC_FOUNDRY_BASE_URL` in your terminal environment before running.
- **`az account get-access-token` fails** — run `az login` first.
- **Token expired mid-session** — restart the script; it fetches a fresh token each run.
- **File permission issues** — ensure `--userns=keep-id` is supported by your Podman version (`podman --version` ≥ 3.0). If files created/modified by the container cannot be updated on the host (e.g., due to host user UID mismatch), upgrade to Podman ≥ 4.3.0, which maps the host user to container UID/GID 1000 (`--userns=keep-id:uid=1000,gid=1000`). To fix the permissions of existing files in the workspace, run: `podman unshare chown -R 0:0 .`
