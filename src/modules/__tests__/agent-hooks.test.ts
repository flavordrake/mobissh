import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import http from 'http';
import fs from 'fs';
import path from 'path';
import os from 'os';

let server: http.Server;
let baseUrl: string;
let tmpHome: string;

function post(urlPath: string, body: object): Promise<{ status: number; json: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request(`${baseUrl}${urlPath}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
    }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode!, json: JSON.parse(buf) }); }
        catch { resolve({ status: res.statusCode!, json: {} }); }
      });
    });
    req.on('error', reject);
    req.end(data);
  });
}

function get(urlPath: string): Promise<{ status: number; json: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    http.get(`${baseUrl}${urlPath}`, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try { resolve({ status: res.statusCode!, json: JSON.parse(buf) }); }
        catch { resolve({ status: res.statusCode!, json: {} }); }
      });
    }).on('error', reject);
  });
}

beforeAll(async () => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-hooks-test-'));
  process.env.HOME = tmpHome;
  process.env.AGENT_HOME = tmpHome;

  // Clear require cache so server re-reads HOME
  const serverPath = path.resolve(__dirname, '../../../server/index.js');
  delete require.cache[serverPath];

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const mod = require(serverPath) as { server: http.Server };
  server = mod.server;

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', () => { resolve(); });
  });
  const addr = server.address() as { port: number };
  baseUrl = `http://127.0.0.1:${addr.port}`;
});

afterAll(async () => {
  await new Promise<void>((resolve) => { server.close(() => { resolve(); }); });
  fs.rmSync(tmpHome, { recursive: true, force: true });
  delete process.env.AGENT_HOME;
});

beforeEach(() => {
  // Clean agent config dirs between tests
  for (const dir of ['.claude', '.codex', '.gemini', path.join('.config', 'opencode')]) {
    const p = path.join(tmpHome, dir);
    if (fs.existsSync(p)) fs.rmSync(p, { recursive: true, force: true });
  }
});

describe('agent hooks API', () => {
  describe('/api/detect-agents', () => {
    it('reports agents as not installed when config dirs missing', async () => {
      const { json } = await get('/api/detect-agents');
      const agents = json.agents as Array<{ id: string; installed: boolean; hookActive: boolean }>;
      for (const a of agents) {
        expect(a.installed).toBe(false);
        expect(a.hookActive).toBe(false);
      }
    });

    it('detects codex as installed with hook active', async () => {
      const codexDir = path.join(tmpHome, '.codex');
      fs.mkdirSync(codexDir, { recursive: true });
      fs.writeFileSync(path.join(codexDir, 'config.toml'), 'notify = ["bash", "-c", "test"]\n');
      const { json } = await get('/api/detect-agents');
      const codex = (json.agents as Array<{ id: string; installed: boolean; hookActive: boolean }>).find(a => a.id === 'codex')!;
      expect(codex.installed).toBe(true);
      expect(codex.hookActive).toBe(true);
    });

    it('detects gemini as installed with hook active', async () => {
      const geminiDir = path.join(tmpHome, '.gemini');
      fs.mkdirSync(geminiDir, { recursive: true });
      fs.writeFileSync(path.join(geminiDir, 'settings.json'), JSON.stringify({
        hooks: [{ type: 'BeforeTool', toolName: 'ask_user', command: ['bash', '-c', 'test'] }],
      }));
      const { json } = await get('/api/detect-agents');
      const gemini = (json.agents as Array<{ id: string; installed: boolean; hookActive: boolean }>).find(a => a.id === 'gemini')!;
      expect(gemini.installed).toBe(true);
      expect(gemini.hookActive).toBe(true);
    });

    it('detects opencode as installed with hook active when plugin file exists', async () => {
      const opencodeDir = path.join(tmpHome, '.config', 'opencode');
      fs.mkdirSync(path.join(opencodeDir, 'plugins'), { recursive: true });
      fs.writeFileSync(path.join(opencodeDir, 'opencode.json'), '{}');
      fs.writeFileSync(path.join(opencodeDir, 'plugins', 'mobissh-notify.js'), 'export default function plugin() {}');
      const { json } = await get('/api/detect-agents');
      const opencode = (json.agents as Array<{ id: string; installed: boolean; hookActive: boolean }>).find(a => a.id === 'opencode')!;
      expect(opencode.installed).toBe(true);
      expect(opencode.hookActive).toBe(true);
    });

    it('detects opencode as installed but hook inactive when plugin file missing', async () => {
      const opencodeDir = path.join(tmpHome, '.config', 'opencode');
      fs.mkdirSync(opencodeDir, { recursive: true });
      fs.writeFileSync(path.join(opencodeDir, 'opencode.json'), '{}');
      const { json } = await get('/api/detect-agents');
      const opencode = (json.agents as Array<{ id: string; installed: boolean; hookActive: boolean }>).find(a => a.id === 'opencode')!;
      expect(opencode.installed).toBe(true);
      expect(opencode.hookActive).toBe(false);
    });
  });

  describe('/api/install-hook', () => {
    it('installs codex hook in config.toml', async () => {
      fs.mkdirSync(path.join(tmpHome, '.codex'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.codex', 'config.toml'), '# existing config\n');
      const { status, json } = await post('/api/install-hook', { agent: 'codex' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      const content = fs.readFileSync(path.join(tmpHome, '.codex', 'config.toml'), 'utf8');
      expect(content).toContain('notify = ');
      expect(content).toContain('notify-bell.sh');
    });

    it('codex install is idempotent', async () => {
      fs.mkdirSync(path.join(tmpHome, '.codex'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.codex', 'config.toml'), '');
      await post('/api/install-hook', { agent: 'codex' });
      await post('/api/install-hook', { agent: 'codex' });
      const content = fs.readFileSync(path.join(tmpHome, '.codex', 'config.toml'), 'utf8');
      const matches = content.match(/^notify\s*=/gm);
      expect(matches).toHaveLength(1);
    });

    it('installs gemini hook in settings.json', async () => {
      fs.mkdirSync(path.join(tmpHome, '.gemini'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.gemini', 'settings.json'), '{}');
      const { status, json } = await post('/api/install-hook', { agent: 'gemini' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      const settings = JSON.parse(fs.readFileSync(path.join(tmpHome, '.gemini', 'settings.json'), 'utf8'));
      expect(settings.hooks).toHaveLength(1);
      expect(settings.hooks[0].type).toBe('BeforeTool');
      expect(settings.hooks[0].toolName).toBe('ask_user');
    });

    it('gemini install is idempotent', async () => {
      fs.mkdirSync(path.join(tmpHome, '.gemini'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.gemini', 'settings.json'), '{}');
      await post('/api/install-hook', { agent: 'gemini' });
      await post('/api/install-hook', { agent: 'gemini' });
      const settings = JSON.parse(fs.readFileSync(path.join(tmpHome, '.gemini', 'settings.json'), 'utf8'));
      expect(settings.hooks).toHaveLength(1);
    });

    it('installs opencode plugin file', async () => {
      const opencodeDir = path.join(tmpHome, '.config', 'opencode');
      fs.mkdirSync(opencodeDir, { recursive: true });
      fs.writeFileSync(path.join(opencodeDir, 'opencode.json'), '{}');
      const { status, json } = await post('/api/install-hook', { agent: 'opencode' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      const pluginPath = path.join(opencodeDir, 'plugins', 'mobissh-notify.js');
      expect(fs.existsSync(pluginPath)).toBe(true);
      const content = fs.readFileSync(pluginPath, 'utf8');
      expect(content).toContain('notify-bell.sh');
      expect(content).toContain('question');
    });

    it('opencode install is idempotent', async () => {
      const opencodeDir = path.join(tmpHome, '.config', 'opencode');
      fs.mkdirSync(opencodeDir, { recursive: true });
      fs.writeFileSync(path.join(opencodeDir, 'opencode.json'), '{}');
      await post('/api/install-hook', { agent: 'opencode' });
      const { status, json } = await post('/api/install-hook', { agent: 'opencode' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      const pluginPath = path.join(opencodeDir, 'plugins', 'mobissh-notify.js');
      expect(fs.existsSync(pluginPath)).toBe(true);
    });

    it('rejects unsupported agent', async () => {
      const { status, json } = await post('/api/install-hook', { agent: 'unknown' });
      expect(status).toBe(400);
      expect(json.error).toBe('Unsupported agent');
    });

    it('writes shared notify-bell.sh script', async () => {
      await post('/api/install-hook', { agent: 'codex' });
      const scriptPath = path.join(tmpHome, '.claude', 'hooks', 'notify-bell.sh');
      expect(fs.existsSync(scriptPath)).toBe(true);
      const stat = fs.statSync(scriptPath);
      expect(stat.mode & 0o111).toBeGreaterThan(0); // executable
    });
  });

  describe('/api/uninstall-hook', () => {
    it('removes codex hook from config.toml', async () => {
      fs.mkdirSync(path.join(tmpHome, '.codex'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.codex', 'config.toml'), '# header\nnotify = ["bash", "-c", "test"]\nother = true\n');
      const { status, json } = await post('/api/uninstall-hook', { agent: 'codex' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      const content = fs.readFileSync(path.join(tmpHome, '.codex', 'config.toml'), 'utf8');
      expect(content).not.toContain('notify');
      expect(content).toContain('other = true');
    });

    it('removes gemini hook from settings.json preserving other hooks', async () => {
      fs.mkdirSync(path.join(tmpHome, '.gemini'), { recursive: true });
      const existing = {
        hooks: [
          { type: 'BeforeTool', toolName: 'ask_user', command: ['test'] },
          { type: 'AfterTool', toolName: 'other', command: ['keep'] },
        ],
        otherSetting: true,
      };
      fs.writeFileSync(path.join(tmpHome, '.gemini', 'settings.json'), JSON.stringify(existing));
      const { status } = await post('/api/uninstall-hook', { agent: 'gemini' });
      expect(status).toBe(200);
      const settings = JSON.parse(fs.readFileSync(path.join(tmpHome, '.gemini', 'settings.json'), 'utf8'));
      expect(settings.hooks).toHaveLength(1);
      expect(settings.hooks[0].toolName).toBe('other');
      expect(settings.otherSetting).toBe(true);
    });

    it('removes gemini hooks key when empty', async () => {
      fs.mkdirSync(path.join(tmpHome, '.gemini'), { recursive: true });
      fs.writeFileSync(path.join(tmpHome, '.gemini', 'settings.json'), JSON.stringify({
        hooks: [{ type: 'BeforeTool', toolName: 'ask_user', command: ['test'] }],
      }));
      await post('/api/uninstall-hook', { agent: 'gemini' });
      const settings = JSON.parse(fs.readFileSync(path.join(tmpHome, '.gemini', 'settings.json'), 'utf8'));
      expect(settings.hooks).toBeUndefined();
    });

    it('removes opencode plugin file', async () => {
      const pluginsDir = path.join(tmpHome, '.config', 'opencode', 'plugins');
      fs.mkdirSync(pluginsDir, { recursive: true });
      const pluginPath = path.join(pluginsDir, 'mobissh-notify.js');
      fs.writeFileSync(pluginPath, 'export default function plugin() {}');
      const { status, json } = await post('/api/uninstall-hook', { agent: 'opencode' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
      expect(fs.existsSync(pluginPath)).toBe(false);
    });

    it('opencode uninstall is a no-op when plugin file does not exist', async () => {
      const { status, json } = await post('/api/uninstall-hook', { agent: 'opencode' });
      expect(status).toBe(200);
      expect(json.ok).toBe(true);
    });
  });
});
