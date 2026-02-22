'use strict';

/**
 * MobiSSH PWA — WebSocket SSH Bridge + Static File Server
 *
 * Serves the PWA frontend on HTTP and the SSH bridge on WebSocket,
 * both on the same port so only one endpoint needs to be exposed.
 *
 * Protocol (JSON messages):
 *
 *   Client → Server:
 *     { type: 'connect', host, port, username, password? }
 *     { type: 'connect', host, port, username, privateKey? }
 *     { type: 'input', data: string }
 *     { type: 'resize', cols: number, rows: number }
 *     { type: 'disconnect' }
 *     { type: 'hostkey_response', accepted: boolean }
 *
 *   Server → Client:
 *     { type: 'connected' }
 *     { type: 'output', data: string }
 *     { type: 'error', message: string }
 *     { type: 'disconnected', reason: string }
 *     { type: 'hostkey', host, port, keyType, fingerprint }
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { createHash } = require('crypto');
const WebSocket = require('ws');
const { Client } = require('ssh2');

const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';

const PUBLIC_DIR = path.resolve(__dirname, '..', 'public');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.ico':  'image/x-icon',
};

// ─── HTTP server (static files) ───────────────────────────────────────────────

const server = http.createServer((req, res) => {
  const urlPath = req.url.split('?')[0];
  const rel = path.normalize(urlPath).replace(/^(\.\.[/\\])+/, '');
  const filePath = path.join(PUBLIC_DIR, rel === '/' || rel === '' ? 'index.html' : rel);

  if (!filePath.startsWith(PUBLIC_DIR + path.sep) && filePath !== PUBLIC_DIR) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store',
      'Content-Security-Policy': [
        "default-src 'self'",
        "script-src 'self' https://cdn.jsdelivr.net",
        "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://fonts.googleapis.com",
        "font-src 'self' https://cdn.jsdelivr.net https://fonts.gstatic.com",
        "connect-src 'self' wss: ws:",
        "img-src 'self' data: blob:",
        "worker-src 'self'",
        "frame-ancestors 'none'",
      ].join('; '),
    });
    res.end(data);
  });
});

// ─── WebSocket server (SSH bridge) ────────────────────────────────────────────

const MAX_MESSAGE_SIZE = 4 * 1024 * 1024;
const WS_PING_INTERVAL_MS = 25_000;

const wss = new WebSocket.Server({ server, maxPayload: MAX_MESSAGE_SIZE });

// WebSocket-level ping/pong to keep idle connections alive through proxies/NAT.
// Any client that doesn't pong within one interval is terminated.
const wsPingInterval = setInterval(() => {
  wss.clients.forEach((client) => {
    if (client.readyState !== WebSocket.OPEN) return;
    if (client._pongPending) {
      client.terminate();
      return;
    }
    client._pongPending = true;
    client.ping();
  });
}, WS_PING_INTERVAL_MS);

wss.on('close', () => clearInterval(wsPingInterval));

// ─── SSRF prevention (issue #6) ───────────────────────────────────────────────
// Blocks RFC-1918 private, loopback, and link-local addresses by default.
// Clients may send allowPrivate:true to override (controlled by the danger zone
// setting in the frontend — only for users who explicitly opt in).

function isPrivateHost(host) {
  const h = host.trim().toLowerCase();
  // Loopback / unspecified
  if (h === 'localhost' || h === '::1' || h === '0.0.0.0') return true;
  if (h.startsWith('127.')) return true;           // 127.0.0.0/8
  // RFC-1918 ranges
  if (h.startsWith('10.')) return true;            // 10.0.0.0/8
  if (h.startsWith('192.168.')) return true;       // 192.168.0.0/16
  // 172.16.0.0/12 = 172.16.x – 172.31.x
  const m = h.match(/^172\.(\d+)\./);
  if (m && parseInt(m[1]) >= 16 && parseInt(m[1]) <= 31) return true;
  // IPv6 link-local and ULA
  if (h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd')) return true;
  return false;
}

wss.on('connection', (ws, req) => {
  ws.on('pong', () => { ws._pongPending = false; });
  const clientIP = req.socket.remoteAddress;
  console.log(`[ssh-bridge] Client connected: ${clientIP}`);

  let sshClient = null;
  let sshStream = null;
  let connecting = false;
  let pendingVerify = null; // hostVerifier callback waiting for client response (#5)

  function send(obj) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    }
  }

  function cleanup(reason) {
    pendingVerify = null; // discard any pending host-key verification (#5)
    if (sshStream) {
      try { sshStream.close(); } catch (_) {}
      sshStream = null;
    }
    if (sshClient) {
      try { sshClient.end(); } catch (_) {}
      sshClient = null;
    }
    connecting = false;
    if (reason) {
      send({ type: 'disconnected', reason });
      console.log(`[ssh-bridge] Session ended (${clientIP}): ${reason}`);
    }
  }

  function connect(cfg) {
    if (connecting || sshClient) {
      send({ type: 'error', message: 'Already connected or connecting' });
      return;
    }
    connecting = true;

    if (!cfg.host || !cfg.username) {
      send({ type: 'error', message: 'host and username are required' });
      connecting = false;
      return;
    }

    if (isPrivateHost(cfg.host) && !cfg.allowPrivate) {
      send({ type: 'error', message: 'Connections to private/loopback addresses are blocked. Enable "Allow private addresses" in Settings → Danger Zone to override.' });
      connecting = false;
      return;
    }

    sshClient = new Client();

    sshClient.on('ready', () => {
      console.log(`[ssh-bridge] SSH ready: ${cfg.username}@${cfg.host}:${cfg.port || 22}`);
      sshClient.shell(
        { term: 'xterm-256color', cols: 80, rows: 24 },
        (err, stream) => {
          if (err) {
            send({ type: 'error', message: `Shell error: ${err.message}` });
            cleanup(err.message);
            return;
          }
          sshStream = stream;
          connecting = false;
          send({ type: 'connected' });

          stream.on('data', (chunk) => {
            send({ type: 'output', data: chunk.toString('utf8') });
          });
          stream.stderr.on('data', (chunk) => {
            send({ type: 'output', data: chunk.toString('utf8') });
          });
          stream.on('close', () => {
            cleanup('SSH stream closed');
          });

          if (cfg.initialCommand) {
            stream.write(cfg.initialCommand + '\r');
          }
        }
      );
    });

    sshClient.on('error', (err) => {
      send({ type: 'error', message: err.message });
      cleanup(err.message);
    });
    sshClient.on('end', () => { cleanup('SSH connection ended'); });
    sshClient.on('close', () => { cleanup('SSH connection closed'); });

    const sshConfig = {
      host: cfg.host,
      port: parseInt(cfg.port) || 22,
      username: cfg.username,
      readyTimeout: 15000,
      keepaliveInterval: 15000,  // SSH-layer keepalive every 15s
      keepaliveCountMax: 4,       // drop after 4 unanswered (~60s)
      hostVerifier(keyBuffer, verify) {
        // Compute SHA-256 fingerprint in OpenSSH format (#5)
        const fp = createHash('sha256').update(keyBuffer).digest('base64');
        const fingerprint = `SHA256:${fp}`;

        // Parse key type from SSH wire-format: uint32 len + ASCII string
        let keyType = 'unknown';
        try {
          const typeLen = keyBuffer.readUInt32BE(0);
          keyType = keyBuffer.slice(4, 4 + typeLen).toString('ascii');
        } catch (_) {}

        // Suspend KEX until the browser client accepts or rejects the key
        pendingVerify = verify;
        send({ type: 'hostkey', host: cfg.host, port: parseInt(cfg.port) || 22, keyType, fingerprint });
      },
    };

    if (cfg.privateKey) {
      sshConfig.privateKey = cfg.privateKey;
      if (cfg.passphrase) sshConfig.passphrase = cfg.passphrase;
    } else if (cfg.password) {
      sshConfig.password = cfg.password;
    } else {
      send({ type: 'error', message: 'No authentication method provided' });
      connecting = false;
      sshClient = null;
      return;
    }

    try {
      sshClient.connect(sshConfig);
    } catch (err) {
      send({ type: 'error', message: `Connect failed: ${err.message}` });
      cleanup(err.message);
    }
  }

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) {
      send({ type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'connect':    connect(msg); break;
      case 'input':
        if (sshStream && typeof msg.data === 'string') sshStream.write(msg.data);
        break;
      case 'resize':
        if (sshStream && msg.cols && msg.rows)
          sshStream.setWindow(parseInt(msg.rows), parseInt(msg.cols), 0, 0);
        break;
      case 'disconnect': cleanup('User disconnected'); break;
      case 'ping': break; // application-layer keepalive (#29), no response needed
      case 'hostkey_response': // host key accept/reject from browser client (#5)
        if (pendingVerify) {
          const fn = pendingVerify;
          pendingVerify = null;
          fn(msg.accepted === true);
          // If rejected, ssh2 emits an error event which calls cleanup naturally
        }
        break;
      default: send({ type: 'error', message: `Unknown message type: ${msg.type}` });
    }
  });

  ws.on('close', () => {
    console.log(`[ssh-bridge] WebSocket closed: ${clientIP}`);
    cleanup(null);
  });
  ws.on('error', (err) => {
    console.error(`[ssh-bridge] WebSocket error (${clientIP}):`, err.message);
    cleanup(err.message);
  });
});

// ─── Start ────────────────────────────────────────────────────────────────────

server.listen(PORT, HOST, () => {
  console.log(`[ssh-bridge] Listening on http://${HOST}:${PORT}`);
});

process.on('SIGTERM', () => {
  console.log('[ssh-bridge] SIGTERM — shutting down');
  server.close(() => process.exit(0));
});
process.on('SIGINT', () => {
  console.log('[ssh-bridge] SIGINT — shutting down');
  server.close(() => process.exit(0));
});
