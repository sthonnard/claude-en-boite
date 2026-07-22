#!/usr/bin/env node
const http = require('http');
const net = require('net');
const url = require('url');
const fs = require('fs');

const rulesFile = process.argv[2] || '/etc/claude-network-rules.txt';
const PORT = parseInt(process.env.PROXY_PORT || '8888', 10);

function parseRule(line) {
    line = line.trim();
    if (!line || line.startsWith('#')) return null;

    let scheme = '*';
    let hostPortStr = line;

    if (line.startsWith('http://')) {
        scheme = 'http';
        hostPortStr = line.slice(7);
    } else if (line.startsWith('https://')) {
        scheme = 'https';
        hostPortStr = line.slice(8);
    }

    const slashIdx = hostPortStr.indexOf('/');
    if (slashIdx !== -1) {
        hostPortStr = hostPortStr.slice(0, slashIdx);
    }

    let host = hostPortStr;
    let port = '*';

    const lastColon = hostPortStr.lastIndexOf(':');
    if (lastColon !== -1 && !hostPortStr.endsWith(']')) {
        const pStr = hostPortStr.slice(lastColon + 1);
        if (pStr === '*' || !isNaN(parseInt(pStr, 10))) {
            host = hostPortStr.slice(0, lastColon);
            port = pStr === '*' ? '*' : parseInt(pStr, 10);
        }
    }

    return { scheme, host: host.toLowerCase(), port };
}

function loadRules() {
    const rules = [];
    if (fs.existsSync(rulesFile)) {
        const content = fs.readFileSync(rulesFile, 'utf8');
        for (const line of content.split('\n')) {
            const rule = parseRule(line);
            if (rule) rules.push(rule);
        }
    } else {
        console.warn(`[NETWORK FILTER] Warning: Rules file '${rulesFile}' not found.`);
    }

    if (process.env.ANTHROPIC_FOUNDRY_BASE_URL) {
        try {
            const parsed = new url.URL(process.env.ANTHROPIC_FOUNDRY_BASE_URL);
            const scheme = parsed.protocol.replace(':', '');
            const host = parsed.hostname;
            const port = parsed.port ? parseInt(parsed.port, 10) : (scheme === 'https' ? 443 : 80);
            rules.push({ scheme, host: host.toLowerCase(), port });
            console.log(`[NETWORK FILTER] Auto-allowed Azure Foundry endpoint: ${scheme}://${host}:${port}`);
        } catch (e) {
            console.warn(`[NETWORK FILTER] Warning: Could not parse ANTHROPIC_FOUNDRY_BASE_URL: ${e.message}`);
        }
    }

    return rules;
}

const rules = loadRules();

function isAllowed(targetScheme, targetHost, targetPort) {
    targetHost = targetHost.toLowerCase();
    targetPort = parseInt(targetPort, 10);

    for (const rule of rules) {
        if (rule.scheme !== '*' && rule.scheme !== targetScheme) {
            continue;
        }
        if (rule.port !== '*' && rule.port !== targetPort) {
            continue;
        }
        if (rule.host === '*' || rule.host === '*.*') {
            return true;
        }
        if (rule.host.startsWith('*.')) {
            const suffix = rule.host.slice(2);
            if (targetHost === suffix || targetHost.endsWith('.' + suffix)) {
                return true;
            }
        }
        if (rule.host === targetHost) {
            return true;
        }
    }
    return false;
}

const server = http.createServer((req, res) => {
    try {
        let reqUrl;
        if (req.url.startsWith('http://') || req.url.startsWith('https://')) {
            reqUrl = new url.URL(req.url);
        } else {
            const hostHeader = req.headers.host || 'localhost';
            reqUrl = new url.URL(req.url, `http://${hostHeader}`);
        }

        const targetScheme = reqUrl.protocol.replace(':', '') || 'http';
        const targetHost = reqUrl.hostname;
        const targetPort = reqUrl.port ? parseInt(reqUrl.port, 10) : (targetScheme === 'https' ? 443 : 80);

        if (!isAllowed(targetScheme, targetHost, targetPort)) {
            console.warn(`[NETWORK FILTER] BLOCKED HTTP ${req.method} ${targetScheme}://${targetHost}:${targetPort}${reqUrl.pathname}`);
            res.writeHead(403, { 'Content-Type': 'text/plain' });
            res.end(`403 Forbidden: Endpoint ${targetScheme}://${targetHost}:${targetPort} not allowed by network security policy.\n`);
            return;
        }

        console.log(`[NETWORK FILTER] ALLOWED HTTP ${req.method} ${targetScheme}://${targetHost}:${targetPort}${reqUrl.pathname}`);

        const options = {
            hostname: targetHost,
            port: targetPort,
            path: reqUrl.pathname + reqUrl.search,
            method: req.method,
            headers: req.headers
        };

        const proxyReq = http.request(options, (proxyRes) => {
            res.writeHead(proxyRes.statusCode, proxyRes.headers);
            proxyRes.pipe(res, { end: true });
        });

        proxyReq.on('error', (err) => {
            console.error(`[NETWORK FILTER] Error proxying HTTP to ${targetHost}:${targetPort}: ${err.message}`);
            res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end(`502 Bad Gateway: ${err.message}\n`);
        });

        req.pipe(proxyReq, { end: true });
    } catch (err) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end(`400 Bad Request: ${err.message}\n`);
    }
});

server.on('connect', (req, clientSocket, head) => {
    try {
        const parts = req.url.split(':');
        const targetHost = parts[0];
        const targetPort = parseInt(parts[1] || '443', 10);
        const targetScheme = 'https';

        if (!isAllowed(targetScheme, targetHost, targetPort)) {
            console.warn(`[NETWORK FILTER] BLOCKED HTTPS CONNECT to ${targetScheme}://${targetHost}:${targetPort}`);
            clientSocket.write(
                'HTTP/1.1 403 Forbidden\r\n' +
                'Content-Type: text/plain\r\n' +
                'Connection: close\r\n' +
                '\r\n' +
                `403 Forbidden: Endpoint https://${targetHost}:${targetPort} not allowed by network security policy.\r\n`
            );
            clientSocket.destroy();
            return;
        }

        console.log(`[NETWORK FILTER] ALLOWED HTTPS CONNECT to ${targetScheme}://${targetHost}:${targetPort}`);

        const serverSocket = net.connect(targetPort, targetHost, () => {
            clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            serverSocket.write(head);
            serverSocket.pipe(clientSocket);
            clientSocket.pipe(serverSocket);
        });

        serverSocket.on('error', (err) => {
            console.error(`[NETWORK FILTER] Error connecting HTTPS tunnel to ${targetHost}:${targetPort}: ${err.message}`);
            clientSocket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
            clientSocket.destroy();
        });

        clientSocket.on('error', () => {
            serverSocket.destroy();
        });
    } catch (err) {
        clientSocket.destroy();
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[NETWORK FILTER] Proxy running on 0.0.0.0:${PORT} with ${rules.length} active rules.`);
});

