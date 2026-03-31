/**
 * Tests for recent sessions persistence (#385)
 *
 * Expected behavior:
 * 1. On SSH connect, profile identity is saved to localStorage as `recentSessions`
 * 2. Recent list is capped at 5, newest first, duplicates replaced (same host+port+user)
 * 3. loadProfiles renders "Recent Sessions" section on cold start (no active sessions)
 * 4. Each recent session has a one-tap Reconnect button
 * 5. "Reconnect All" button appears when multiple recent sessions exist
 * 6. Closing a session removes it from recentSessions
 * 7. Recent sessions section disappears when active sessions exist
 *
 * These tests will FAIL until the feature is implemented.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Stub browser globals before any module imports
vi.stubGlobal('crypto', webcrypto);

const storage = new Map<string, string>();
vi.stubGlobal('localStorage', {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => { storage.set(key, value); },
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => { storage.clear(); },
  get length() { return storage.size; },
  key: (_i: number) => null as string | null,
});
vi.stubGlobal('location', { hostname: 'localhost' });

// Minimal document stub
const mockElements = new Map<string, {
  innerHTML: string;
  hidden: boolean;
  classList: { add: ReturnType<typeof vi.fn>; remove: ReturnType<typeof vi.fn>; contains: (c: string) => boolean };
  value?: string;
  dispatchEvent?: ReturnType<typeof vi.fn>;
}>();

function getOrCreateElement(id: string) {
  if (!mockElements.has(id)) {
    const classes = new Set<string>();
    mockElements.set(id, {
      innerHTML: '',
      hidden: false,
      classList: {
        add: vi.fn((...cs: string[]) => { for (const c of cs) classes.add(c); }),
        remove: vi.fn((...cs: string[]) => { for (const c of cs) classes.delete(c); }),
        contains: (c: string) => classes.has(c),
      },
      value: '',
      dispatchEvent: vi.fn(),
    });
  }
  return mockElements.get(id)!;
}

vi.stubGlobal('document', {
  getElementById: (id: string) => getOrCreateElement(id),
  querySelector: () => null,
  addEventListener: vi.fn(),
  createElement: vi.fn(() => ({
    className: '',
    textContent: '',
    innerHTML: '',
    id: '',
    appendChild: vi.fn(),
    addEventListener: vi.fn(),
    querySelector: vi.fn(),
    remove: vi.fn(),
  })),
  body: { appendChild: vi.fn() },
});

vi.stubGlobal('WebSocket', class {
  onopen: ((e?: unknown) => void) | null = null;
  onclose: ((e?: unknown) => void) | null = null;
  onmessage: ((e?: unknown) => void) | null = null;
  onerror: ((e?: unknown) => void) | null = null;
  readyState = 1;
  url: string;
  close = vi.fn();
  send = vi.fn();
  addEventListener = vi.fn();
  removeEventListener = vi.fn();
  static OPEN = 1;
  static CLOSED = 3;
  static CLOSING = 2;
  constructor(url: string) { this.url = url; }
});
vi.stubGlobal('Worker', class { onmessage = null; postMessage = vi.fn(); terminate = vi.fn(); });
vi.stubGlobal('navigator', { wakeLock: undefined });
vi.stubGlobal('window', {
  addEventListener: vi.fn(),
  location: { protocol: 'http:', host: 'localhost:8081', pathname: '/' },
});
vi.stubGlobal('CSS', { escape: (s: string) => s });
vi.stubGlobal('confirm', () => true);
vi.stubGlobal('requestAnimationFrame', (cb: () => void) => { cb(); return 0; });

const { appState, createSession, transitionSession } = await import('../state.js');

// Resolve source file paths for structural tests
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const modulesDir = resolve(__dirname, '..');

// ── Structural type for a recent session entry ──────────────────────────────

interface RecentSessionEntry {
  host: string;
  port: number;
  username: string;
  profileIdx: number;
}

const RECENT_SESSIONS_KEY = 'recentSessions';
const MAX_RECENT = 5;

// ── Helper: read source files for structural tests ──────────────────────────

function readSource(filename: string): string {
  return readFileSync(resolve(modulesDir, filename), 'utf-8');
}

// ── Helper: seed recent sessions in localStorage ────────────────────────────

function seedRecentSessions(entries: RecentSessionEntry[]): void {
  storage.set(RECENT_SESSIONS_KEY, JSON.stringify(entries));
}

// ── Helper: get recent sessions from localStorage ───────────────────────────

function getRecentSessions(): RecentSessionEntry[] {
  const raw = storage.get(RECENT_SESSIONS_KEY);
  if (!raw) return [];
  return JSON.parse(raw) as RecentSessionEntry[];
}

// ── Helper: seed profiles ───────────────────────────────────────────────────

function seedProfiles(profiles: Array<{ name: string; host: string; port: number; username: string; authType: string }>): void {
  storage.set('sshProfiles', JSON.stringify(profiles));
}

describe('recent sessions persistence (#385)', () => {
  beforeEach(() => {
    storage.clear();
    appState.sessions.clear();
    appState.activeSessionId = null;
    mockElements.clear();
  });

  // ── 1. On connect, profile identity is saved to recentSessions ──────────

  describe('save on connect', () => {
    it('connection.ts or profiles.ts writes to recentSessions localStorage key', () => {
      // Structural: the codebase must write to the recentSessions key
      const connectionSrc = readSource('connection.ts');
      const profilesSrc = readSource('profiles.ts');
      const combined = connectionSrc + profilesSrc;
      expect(combined).toContain(RECENT_SESSIONS_KEY);
    });

    it('recentSessions value is a JSON array of objects with host, port, username, profileIdx', () => {
      // After a successful connect, recentSessions should exist in localStorage
      // This is a behavioral test — it will fail until the feature writes this key
      // For now, we verify that reading the key after a simulated connect returns valid data.

      // Simulate what the code SHOULD do:
      // After connect() succeeds, something like:
      //   saveRecentSession({ host, port, username, profileIdx })
      // For the red baseline, simply check that the key exists after we
      // import and invoke whatever function should persist it.
      const raw = storage.get(RECENT_SESSIONS_KEY);
      // On cold start with no prior connections, this should be null — that's fine.
      // But after a connect, it should be a JSON array. We'll test the function directly
      // once it exists. For now, verify the structural expectation.
      const connectionSrc = readSource('connection.ts');
      const stateSrc = readSource('state.ts');
      const combined = connectionSrc + stateSrc;
      // The implementation should call a function that saves to recentSessions
      // when a session transitions to 'connected'
      expect(combined).toMatch(/recentSession/i);
    });
  });

  // ── 2. Recent sessions list is capped ───────────────────────────────────

  describe('capping and deduplication', () => {
    it('recentSessions is capped at 5 entries', () => {
      // Structural: the code should enforce a max of 5 entries
      const connectionSrc = readSource('connection.ts');
      const profilesSrc = readSource('profiles.ts');
      const stateSrc = readSource('state.ts');
      const combined = connectionSrc + profilesSrc + stateSrc;
      // Look for a cap/limit/max pattern with the number 5
      const hasCapLogic = /(?:MAX_RECENT|maxRecent|\.slice\s*\(\s*0\s*,\s*5|\.splice\s*\(\s*5)/.test(combined)
        || combined.includes('5') && combined.includes(RECENT_SESSIONS_KEY);
      expect(hasCapLogic).toBe(true);
    });

    it('duplicate entries (same host+port+username) are replaced, not added', () => {
      // Structural: dedup logic must exist
      const connectionSrc = readSource('connection.ts');
      const profilesSrc = readSource('profiles.ts');
      const combined = connectionSrc + profilesSrc;
      // Should find a findIndex or filter that matches on host+port+username
      // near the recentSessions logic
      const hasDedup = /(?:findIndex|filter|some).*host.*port.*username/.test(combined)
        || /recentSession.*(?:findIndex|filter|some)/.test(combined);
      expect(hasDedup).toBe(true);
    });

    it('newest entry is first in the array', () => {
      // Structural: unshift or prepend pattern
      const connectionSrc = readSource('connection.ts');
      const profilesSrc = readSource('profiles.ts');
      const combined = connectionSrc + profilesSrc;
      const hasNewestFirst = /unshift|(?:\[\s*new.*,\s*\.\.\.)|(?:splice\s*\(\s*0\s*,\s*0)/.test(combined)
        && combined.includes(RECENT_SESSIONS_KEY);
      expect(hasNewestFirst).toBe(true);
    });
  });

  // ── 3. loadProfiles renders recent sessions on cold start ───────────────

  describe('render on cold start', () => {
    it('loadProfiles checks for recentSessions when appState.sessions.size === 0', () => {
      const profilesSrc = readSource('profiles.ts');
      // loadProfiles should reference recentSessions
      expect(profilesSrc).toContain(RECENT_SESSIONS_KEY);
    });

    it('renders "Recent Sessions" section heading in the Connect panel', () => {
      // Seed recent sessions but NO active sessions
      seedRecentSessions([
        { host: 'server1.example.com', port: 22, username: 'admin', profileIdx: 0 },
      ]);
      seedProfiles([
        { name: 'Server 1', host: 'server1.example.com', port: 22, username: 'admin', authType: 'password' },
      ]);

      // Import and call loadProfiles
      // loadProfiles is synchronous, so we can call it directly
      // This will fail until the feature adds the recent sessions rendering
      const profileListEl = getOrCreateElement('profileList');
      const sessionListEl = getOrCreateElement('activeSessionList');

      // Dynamic import to get the latest module with our stubs
      // eslint-disable-next-line @typescript-eslint/no-floating-promises
      import('../profiles.js').then((mod) => {
        mod.loadProfiles();
        const allHTML = profileListEl.innerHTML + sessionListEl.innerHTML;
        expect(allHTML).toContain('Recent Sessions');
      });
    });

    it('loadProfiles source contains "Recent Sessions" text', () => {
      const profilesSrc = readSource('profiles.ts');
      expect(profilesSrc).toContain('Recent Sessions');
    });
  });

  // ── 4. Each recent session has a Reconnect button ───────────────────────

  describe('reconnect button per entry', () => {
    it('rendered recent session HTML includes a reconnect action', () => {
      const profilesSrc = readSource('profiles.ts');
      // The rendered HTML for recent sessions should include a reconnect button/action
      const hasReconnectBtn = /recent.*reconnect|reconnect.*recent/is.test(profilesSrc)
        || (profilesSrc.includes(RECENT_SESSIONS_KEY) && profilesSrc.includes('reconnect'));
      expect(hasReconnectBtn).toBe(true);
    });

    it('reconnect action includes data attributes for session identity', () => {
      const profilesSrc = readSource('profiles.ts');
      // The reconnect button should have data attributes for host/port/username or profileIdx
      const hasDataAttrs = /data-(?:action|idx|profile|host|session)/.test(profilesSrc)
        && profilesSrc.includes(RECENT_SESSIONS_KEY);
      expect(hasDataAttrs).toBe(true);
    });
  });

  // ── 5. "Reconnect All" button when multiple recent sessions ─────────────

  describe('reconnect all button', () => {
    it('profiles.ts contains "Reconnect All" or "reconnect-all" when recentSessions exist', () => {
      const profilesSrc = readSource('profiles.ts');
      // Should have both recentSessions logic AND a reconnect-all action
      const hasReconnectAll = profilesSrc.includes(RECENT_SESSIONS_KEY)
        && /reconnect.all|reconnect-all/i.test(profilesSrc);
      expect(hasReconnectAll).toBe(true);
    });

    it('"Reconnect All" only appears when there are 2+ recent sessions', () => {
      const profilesSrc = readSource('profiles.ts');
      // The reconnect-all button should be conditional on multiple entries
      // Look for a length check near the reconnect-all rendering
      const hasLengthGuard = /(?:length|size)\s*[>]=?\s*[12].*reconnect.all|reconnect.all.*(?:length|size)\s*[>]=?\s*[12]/is.test(profilesSrc);
      expect(hasLengthGuard).toBe(true);
    });
  });

  // ── 6. Closing a session removes it from recentSessions ─────────────────

  describe('close removes from recent', () => {
    it('closeSession or closed transition effect references recentSessions', () => {
      const uiSrc = readSource('ui.ts');
      const stateSrc = readSource('state.ts');
      const combined = uiSrc + stateSrc;
      // Closing a session should also remove it from recentSessions in localStorage
      expect(combined).toContain(RECENT_SESSIONS_KEY);
    });

    it('closing a session updates localStorage recentSessions', () => {
      // Seed recent sessions
      seedRecentSessions([
        { host: 'server1.example.com', port: 22, username: 'admin', profileIdx: 0 },
        { host: 'server2.example.com', port: 22, username: 'root', profileIdx: 1 },
      ]);

      // Create and then close a session matching server1
      const session = createSession('test-close');
      session.profile = { name: 'Server 1', host: 'server1.example.com', port: 22, username: 'admin', authType: 'password' as const };
      appState.activeSessionId = 'test-close';
      transitionSession('test-close', 'connecting');
      transitionSession('test-close', 'authenticating');
      transitionSession('test-close', 'connected');

      // Close the session via state machine
      transitionSession('test-close', 'closed');

      // After closing, the recent sessions should no longer include server1
      const remaining = getRecentSessions();
      const hasServer1 = remaining.some((e) => e.host === 'server1.example.com' && e.username === 'admin');
      expect(hasServer1).toBe(false);
    });
  });

  // ── 7. Recent sessions section disappears when active sessions exist ────

  describe('hidden when active sessions exist', () => {
    it('recent sessions section is not rendered when appState.sessions has entries', () => {
      // Seed both recent sessions and create an active session
      seedRecentSessions([
        { host: 'server1.example.com', port: 22, username: 'admin', profileIdx: 0 },
      ]);
      seedProfiles([
        { name: 'Server 1', host: 'server1.example.com', port: 22, username: 'admin', authType: 'password' },
      ]);

      // Create an active session
      const session = createSession('active-sess');
      session.profile = { name: 'Server 1', host: 'server1.example.com', port: 22, username: 'admin', authType: 'password' as const };
      appState.activeSessionId = 'active-sess';

      // Structural test: loadProfiles should conditionally skip recent when sessions exist
      const profilesSrc = readSource('profiles.ts');
      // The code should check sessions.size or allSessions.length before rendering recent
      const hasConditional = /sessions\.size\s*===?\s*0|allSessions\.length\s*===?\s*0/i.test(profilesSrc)
        && profilesSrc.includes(RECENT_SESSIONS_KEY);
      expect(hasConditional).toBe(true);
    });

    it('loadProfiles source guards recent rendering on zero active sessions', () => {
      const profilesSrc = readSource('profiles.ts');
      // The recent sessions block should be wrapped in a condition that checks
      // for no active sessions
      const hasGuard = /(?:allSessions\.length|sessions\.size)\s*(?:===?\s*0|<\s*1)/.test(profilesSrc)
        && profilesSrc.includes('Recent');
      expect(hasGuard).toBe(true);
    });
  });
});
