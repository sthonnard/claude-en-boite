#!/bin/bash
set -euo pipefail

RULES_FILE="${NETWORK_RULES_FILE:-/etc/claude-network-rules.txt}"

if [[ -f "$RULES_FILE" ]]; then
    node /usr/local/bin/network-proxy.js "$RULES_FILE" &

    for i in {1..50}; do
        if node -e "const net = require('net'); const s = net.connect(8888, '127.0.0.1', () => { s.end(); process.exit(0); }); s.on('error', () => process.exit(1));" &>/dev/null; then
            break
        fi
        sleep 0.1
    done

    export HTTP_PROXY="http://127.0.0.1:8888"
    export HTTPS_PROXY="http://127.0.0.1:8888"
    export http_proxy="http://127.0.0.1:8888"
    export https_proxy="http://127.0.0.1:8888"
    export ALL_PROXY="http://127.0.0.1:8888"
    export all_proxy="http://127.0.0.1:8888"
    export NO_PROXY="127.0.0.1,localhost"
    export no_proxy="127.0.0.1,localhost"
fi

exec "$@"
