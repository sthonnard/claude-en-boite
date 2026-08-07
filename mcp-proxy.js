#!/usr/bin/env node
const http = require('http');
const https = require('https');
const url = require('url');
const fs = require('fs');

const configFile = process.argv[2] || '/etc/mcp-access-rules.yaml';
const PORT = parseInt(process.env.MCP_PROXY_PORT || '8889', 10);

// ── Minimal YAML parser (subset: scalars, flat lists, one-level nested maps) ──

function parseYaml(text) {
    const result = {};
    let currentKey = null;
    let currentSubKey = null;
    let currentSubObj = null;

    for (const rawLine of text.split('\n')) {
        const line = rawLine.replace(/#.*$/, '');
        if (!line.trim()) continue;

        const indent = line.search(/\S/);

        if (indent === 0 && !line.trimStart().startsWith('-')) {
            if (currentKey && currentSubKey && currentSubObj) {
                if (!result.restrict) result.restrict = {};
                result.restrict[currentSubKey] = currentSubObj;
            }
            currentSubKey = null;
            currentSubObj = null;

            const colonIdx = line.indexOf(':');
            if (colonIdx === -1) continue;
            const key = line.slice(0, colonIdx).trim();
            const val = line.slice(colonIdx + 1).trim();
            if (val) {
                result[key] = val;
            } else {
                currentKey = key;
                if (!result[key]) result[key] = [];
            }
        } else if (indent >= 2 && line.trimStart().startsWith('- ')) {
            const item = line.trimStart().slice(2).trim()
                .replace(/^["']|["']$/g, '');
            if (currentSubObj && currentSubObj._collectingAllowed) {
                currentSubObj.allowed.push(item);
            } else if (currentKey && Array.isArray(result[currentKey])) {
                result[currentKey].push(item);
            }
        } else if (indent >= 2 && !line.trimStart().startsWith('-')) {
            const trimmed = line.trimStart();
            const colonIdx = trimmed.indexOf(':');
            if (colonIdx === -1) continue;
            const subKey = trimmed.slice(0, colonIdx).trim();
            const subVal = trimmed.slice(colonIdx + 1).trim();

            if (currentKey === 'restrict') {
                if (indent === 2) {
                    if (currentSubKey && currentSubObj) {
                        if (!result.restrict) result.restrict = {};
                        result.restrict[currentSubKey] = currentSubObj;
                    }
                    currentSubKey = subKey;
                    currentSubObj = { field: null, allowed: [], _collectingAllowed: false };
                } else if (indent >= 4 && currentSubObj) {
                    if (subKey === 'field') {
                        currentSubObj.field = subVal;
                        currentSubObj._collectingAllowed = false;
                    } else if (subKey === 'allowed') {
                        currentSubObj._collectingAllowed = true;
                        if (subVal) {
                            const items = subVal.replace(/^\[|\]$/g, '').split(',')
                                .map(s => s.trim().replace(/^["']|["']$/g, ''))
                                .filter(Boolean);
                            currentSubObj.allowed = items;
                            currentSubObj._collectingAllowed = false;
                        }
                    }
                }
            }
        }
    }

    if (currentSubKey && currentSubObj) {
        if (!result.restrict) result.restrict = {};
        result.restrict[currentSubKey] = currentSubObj;
    }

    if (result.restrict) {
        for (const k of Object.keys(result.restrict)) {
            delete result.restrict[k]._collectingAllowed;
        }
    }

    return result;
}

// ── Config loading with hot-reload ──────────────────────────────────────────

function loadConfig() {
    if (!fs.existsSync(configFile)) {
        console.warn(`[MCP FILTER] Warning: Config file '${configFile}' not found.`);
        return { upstream: '', allow: [], deny: [], restrict: {}, default: 'deny' };
    }
    const text = fs.readFileSync(configFile, 'utf8');
    const raw = parseYaml(text);
    const config = {
        upstream: raw.upstream || '',
        allow: Array.isArray(raw.allow) ? raw.allow : [],
        deny: Array.isArray(raw.deny) ? raw.deny : [],
        restrict: raw.restrict || {},
        default: raw.default || 'deny',
    };
    return config;
}

let lastMtime = 0;
let cachedConfig = loadConfig();

function getConfig() {
    try {
        if (fs.existsSync(configFile)) {
            const stat = fs.statSync(configFile);
            if (stat.mtimeMs !== lastMtime) {
                lastMtime = stat.mtimeMs;
                cachedConfig = loadConfig();
                console.log(`[MCP FILTER] Reloaded config from ${configFile}`);
            }
        }
    } catch (e) {
        // preserve cachedConfig on error
    }
    return cachedConfig;
}

// ── Glob-style wildcard matching ────────────────────────────────────────────

function globMatch(pattern, value) {
    if (pattern === '*') return true;
    if (!pattern.includes('*')) return pattern === value;
    const regex = new RegExp('^' + pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
    return regex.test(value);
}

// ── Tool call evaluation ────────────────────────────────────────────────────

function evaluateToolCall(toolName, args, config) {
    for (const pattern of config.deny) {
        if (globMatch(pattern, toolName)) {
            return { allowed: false, reason: `Tool '${toolName}' is in the deny list.` };
        }
    }

    for (const pattern of config.allow) {
        if (globMatch(pattern, toolName)) {
            return { allowed: true, reason: 'allow-list' };
        }
    }

    if (config.restrict[toolName]) {
        const rule = config.restrict[toolName];
        const fieldValue = args && args[rule.field] !== undefined ? String(args[rule.field]) : undefined;
        if (fieldValue === undefined) {
            return {
                allowed: false,
                reason: `Tool '${toolName}' requires field '${rule.field}' in arguments, but it was not provided.`
            };
        }
        for (const pattern of rule.allowed) {
            if (globMatch(pattern, fieldValue)) {
                return { allowed: true, reason: `restrict: ${rule.field}='${fieldValue}' matches '${pattern}'` };
            }
        }
        return {
            allowed: false,
            reason: `Tool '${toolName}' blocked: ${rule.field}='${fieldValue}' is not in the allowed list for this tool.`
        };
    }

    if (config.default === 'allow') {
        return { allowed: true, reason: 'default-allow' };
    }
    return {
        allowed: false,
        reason: `Tool '${toolName}' is not in the allow list and default policy is 'deny'.`
    };
}

// ── Upstream forwarding ─────────────────────────────────────────────────────

function forwardRequest(upstreamUrl, reqHeaders, bodyBuffer, res) {
    const parsed = new url.URL(upstreamUrl);
    const mod = parsed.protocol === 'https:' ? https : http;

    const fwdHeaders = Object.assign({}, reqHeaders);
    delete fwdHeaders.host;
    fwdHeaders['content-length'] = Buffer.byteLength(bodyBuffer);

    const options = {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: 'POST',
        headers: fwdHeaders,
    };

    const proxyReq = mod.request(options, (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res, { end: true });
    });

    proxyReq.on('error', (err) => {
        console.error(`[MCP FILTER] Upstream error: ${err.message}`);
        if (!res.headersSent) {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                jsonrpc: '2.0', id: null,
                error: { code: -32603, message: `Upstream error: ${err.message}` }
            }));
        }
    });

    proxyReq.end(bodyBuffer);
}

// ── MCP error response ──────────────────────────────────────────────────────

function sendMcpDenied(res, requestId, reason) {
    const body = JSON.stringify({
        jsonrpc: '2.0',
        id: requestId,
        result: {
            content: [{ type: 'text', text: `MCP ACCESS DENIED: ${reason}` }],
            isError: true,
        },
    });
    res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
}

// ── HTTP server ─────────────────────────────────────────────────────────────

const MAX_BODY = 10 * 1024 * 1024; // 10 MB

const server = http.createServer((req, res) => {
    if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'text/plain' });
        res.end('405 Method Not Allowed\n');
        return;
    }

    const chunks = [];
    let size = 0;

    req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY) {
            res.writeHead(413, { 'Content-Type': 'text/plain' });
            res.end('413 Payload Too Large\n');
            req.destroy();
            return;
        }
        chunks.push(chunk);
    });

    req.on('end', () => {
        if (res.writableEnded) return;

        const config = getConfig();
        if (!config.upstream) {
            res.writeHead(503, { 'Content-Type': 'text/plain' });
            res.end('503 Service Unavailable: no upstream configured in mcp-access-rules.yaml\n');
            return;
        }

        const bodyBuffer = Buffer.concat(chunks);
        let body;
        try {
            body = JSON.parse(bodyBuffer.toString('utf8'));
        } catch (e) {
            console.warn(`[MCP FILTER] Malformed JSON body: ${e.message}`);
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                jsonrpc: '2.0', id: null,
                error: { code: -32700, message: `Parse error: ${e.message}` }
            }));
            return;
        }

        if (body.method !== 'tools/call') {
            console.log(`[MCP FILTER] PASS-THROUGH method=${body.method || '(none)'}`);
            forwardRequest(config.upstream, req.headers, bodyBuffer, res);
            return;
        }

        const toolName = body.params && body.params.name;
        const toolArgs = body.params && body.params.arguments;

        if (!toolName) {
            console.log(`[MCP FILTER] PASS-THROUGH tools/call with no tool name`);
            forwardRequest(config.upstream, req.headers, bodyBuffer, res);
            return;
        }

        const result = evaluateToolCall(toolName, toolArgs || {}, config);

        if (result.allowed) {
            console.log(`[MCP FILTER] ALLOWED tool=${toolName} reason=${result.reason}`);
            forwardRequest(config.upstream, req.headers, bodyBuffer, res);
        } else {
            console.warn(`[MCP FILTER] DENIED tool=${toolName} reason=${result.reason}`);
            sendMcpDenied(res, body.id, result.reason);
        }
    });

    req.on('error', (err) => {
        console.error(`[MCP FILTER] Request error: ${err.message}`);
    });
});

server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
        console.error(`[MCP FILTER] Fatal: port ${PORT} is already in use (EADDRINUSE).`);
        console.error(`[MCP FILTER] Run: ss -tlnp | grep :${PORT}   to find it.`);
    } else {
        console.error(`[MCP FILTER] Fatal server error: ${err.message}`);
    }
    process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
    const config = getConfig();
    const restrictCount = Object.keys(config.restrict).length;
    console.log(`[MCP FILTER] MCP proxy running on 0.0.0.0:${PORT}`);
    console.log(`[MCP FILTER] Upstream: ${config.upstream}`);
    console.log(`[MCP FILTER] Rules: ${config.allow.length} allow, ${config.deny.length} deny, ${restrictCount} restrict, default=${config.default}`);
});

process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT',  () => { server.close(); process.exit(0); });
