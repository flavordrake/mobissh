/**
 * TDD red baseline for duplicate session entries in switch menu (#391)
 *
 * Root cause hypothesis: connect() always creates a new sessionId via
 * Date.now(), never checking if a session already exists for the same
 * host+port+username profile. After reconnect failures or repeated
 * connect calls, stale sessions linger in appState.sessions while new
 * ones are added, producing duplicate entries in the session menu.
 *
 * Tests marked "STRUCTURAL" inspect source code for the missing guard.
 * Tests marked "BEHAVIORAL" exercise the state to verify the invariant.
 *
 * All tests should FAIL on current main and PASS when #391 is fixed.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// Stub browser globals before importing modules
vi.stubGlobal('localStorage', {
  getItem: () => null,
  setItem: () => {},
  removeItem: () => {},
  clear: () => {},
  length: 0,
  key: () => null,
});
vi.stubGlobal('location', { hostname: 'localhost' });

const { appState, createSession, transitionSession } = await import('../state.js');

const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');

/** Extract a function body from source, handling type annotations in params. */
function extractFnBody(src: string, fnName: string): string {
  const fnStart = src.indexOf(fnName);
  if (fnStart === -1) return '';
  const sigEnd = src.indexOf('{', src.indexOf(')', fnStart));
  if (sigEnd === -1) return '';
  let depth = 0, fnEnd = sigEnd;
  for (let i = sigEnd; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}') depth--;
    if (depth === 0) { fnEnd = i + 1; break; }
  }
  return src.slice(fnStart, fnEnd);
}

/** Create a profile-like object for testing. */
function makeProfile(host = 'raserver.tailbe5094.ts.net', port = 22, username = 'user') {
  return { name: 'test', host, port, username, authType: 'password' as const };
}

describe('Duplicate session entries in switch menu (#391)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
  });

  // ── 1. STRUCTURAL: connect() checks for existing sessions before creating ──

  describe('connect() guards against duplicate sessions', () => {
    it('connect() searches appState.sessions for a matching profile before createSession', () => {
      // connect() must look for an existing session with matching host+port+username
      // before creating a new one. Without this, every call creates a duplicate.
      const connectBody = extractFnBody(connectionSrc, 'async function connect');
      expect(connectBody.length).toBeGreaterThan(50);

      const hasExistingCheck = connectBody.match(/sessions\.(entries|values|forEach|find|get)/) ||
        connectBody.match(/for\s*\(\s*(?:const|let)\s+\[?\w+(?:,\s*\w+)?\]?\s+of\s+.*sessions/) ||
        connectBody.match(/findExistingSession/) ||
        connectBody.match(/existingSession/) ||
        connectBody.match(/duplicat/i);

      expect(hasExistingCheck).toBeTruthy();
    });

    it('connect() closes or reuses the old session when a duplicate profile is detected', () => {
      // When connect() finds an existing session for the same profile, it must either:
      // (a) close the old session via transitionSession(oldId, 'closed'), or
      // (b) reuse the old session (skip createSession)
      const connectBody = extractFnBody(connectionSrc, 'async function connect');
      expect(connectBody.length).toBeGreaterThan(50);

      const closesOld = connectBody.match(/transitionSession\s*\([^,]+,\s*['"]closed['"]\)/) ||
        connectBody.match(/closeSession\s*\(/) ||
        connectBody.match(/sessions\.delete\s*\(/);
      const reusesOld = connectBody.match(/return\s+reconnect\s*\(/) ||
        connectBody.match(/existing.*session/i);

      expect(closesOld || reusesOld).toBeTruthy();
    });
  });

  // ── 2. BEHAVIORAL: appState.sessions never has two entries for same profile ──

  describe('appState.sessions uniqueness invariant', () => {
    it('creating two sessions with identical profiles violates uniqueness', () => {
      // This test demonstrates the bug: nothing prevents two sessions with
      // the same host+port+username from coexisting in appState.sessions.
      // The fix must ensure this cannot happen.
      const profile = makeProfile();
      const s1 = createSession('raserver:22:user:1000');
      s1.profile = profile;
      transitionSession('raserver:22:user:1000', 'connecting');
      transitionSession('raserver:22:user:1000', 'authenticating');
      transitionSession('raserver:22:user:1000', 'connected');
      transitionSession('raserver:22:user:1000', 'soft_disconnected');

      const s2 = createSession('raserver:22:user:2000');
      s2.profile = { ...profile };
      transitionSession('raserver:22:user:2000', 'connecting');
      transitionSession('raserver:22:user:2000', 'authenticating');
      transitionSession('raserver:22:user:2000', 'connected');

      // Invariant: for a given host+port+username, at most one session entry
      const profileKeys = Array.from(appState.sessions.values())
        .filter((s) => s.profile)
        .map((s) => `${s.profile!.host}:${String(s.profile!.port)}:${s.profile!.username}`);

      const unique = new Set(profileKeys);
      expect(unique.size).toBe(profileKeys.length);
    });

    it('a disconnected session for the same profile is closed before creating a new one', () => {
      // Simulate: session exists in soft_disconnected state, user connects again
      // via the Connect panel (calling connect() with the same profile).
      // The old session should be cleaned up.
      const profile = makeProfile();
      const oldSession = createSession('raserver:22:user:old');
      oldSession.profile = profile;
      transitionSession('raserver:22:user:old', 'connecting');
      transitionSession('raserver:22:user:old', 'authenticating');
      transitionSession('raserver:22:user:old', 'connected');
      transitionSession('raserver:22:user:old', 'soft_disconnected');

      // Simulate what connect() does: create a new session for the same profile
      const newSession = createSession('raserver:22:user:new');
      newSession.profile = { ...profile };

      // After connect() runs, the old disconnected session must be gone
      const matchingSessions = Array.from(appState.sessions.values())
        .filter((s) => s.profile?.host === profile.host
          && s.profile?.port === profile.port
          && s.profile?.username === profile.username);

      // Should be exactly 1, not 2
      expect(matchingSessions.length).toBe(1);
    });
  });

  // ── 3. STRUCTURAL: connect() sessionId generation includes dedup logic ──

  describe('connect() sessionId dedup', () => {
    it('connect() does not unconditionally use Date.now() for every new session', () => {
      // Currently connect() always does:
      //   const sessionId = `${host}:${port}:${username}:${Date.now()}`
      // This guarantees a unique (duplicate) session on every call.
      // After the fix, it should either:
      // (a) reuse the existing sessionId, or
      // (b) close the old session first, or
      // (c) use a stable sessionId (without Date.now()) so the same profile
      //     maps to the same session key.
      const connectBody = extractFnBody(connectionSrc, 'async function connect');
      expect(connectBody.length).toBeGreaterThan(50);

      // The sessionId line should not be a simple Date.now() concatenation
      // without any guard. Check that there's conditional logic around it.
      const sessionIdLine = connectBody.match(/const sessionId\s*=\s*`[^`]*Date\.now\(\)[^`]*`/);
      if (sessionIdLine) {
        // If Date.now() is still used, it must be inside a conditional
        // (i.e., only when no existing session matches)
        const lineIdx = connectBody.indexOf(sessionIdLine[0]);
        const preceding200 = connectBody.slice(Math.max(0, lineIdx - 200), lineIdx);
        const hasGuard = preceding200.includes('if') || preceding200.includes('else');
        expect(hasGuard).toBe(true);
      }
      // If Date.now() is removed entirely, that's also a valid fix — test passes
    });
  });

  // ── 4. BEHAVIORAL: renderSessionList output has no duplicate labels ──

  describe('session list has no duplicate entries for same host', () => {
    it('session menu entries are unique by host+port+username', () => {
      // Simulate the visible bug: two sessions for same server in appState.
      // renderSessionList reads from appState.sessions.values(), so if
      // duplicates exist in the map, they appear in the menu.
      const profile = makeProfile();

      const s1 = createSession('dup:22:user:1111');
      s1.profile = profile;
      transitionSession('dup:22:user:1111', 'connecting');
      transitionSession('dup:22:user:1111', 'authenticating');
      transitionSession('dup:22:user:1111', 'connected');

      const s2 = createSession('dup:22:user:2222');
      s2.profile = { ...profile };
      transitionSession('dup:22:user:2222', 'connecting');
      transitionSession('dup:22:user:2222', 'authenticating');
      transitionSession('dup:22:user:2222', 'connected');

      // Build labels the same way renderSessionList does
      const labels = Array.from(appState.sessions.values())
        .filter((s) => s.profile)
        .map((s) => `${s.profile!.username}@${s.profile!.host}`);

      const uniqueLabels = new Set(labels);
      // Each label should appear exactly once
      expect(uniqueLabels.size).toBe(labels.length);
    });
  });

  // ── 5. STRUCTURAL: connect() or createSession enforces profile uniqueness ──

  describe('profile uniqueness enforcement', () => {
    it('either connect() or createSession prevents duplicate profiles in appState.sessions', () => {
      // The fix may be in connect() (check before calling createSession)
      // or in createSession itself (evict old session with same profile).
      // Either way, the invariant must hold.
      const connectBody = extractFnBody(connectionSrc, 'async function connect');

      // Look for any dedup logic: iteration over sessions, profile comparison,
      // or a helper function that checks for existing sessions.
      const hasDedupInConnect =
        connectBody.match(/sessions\.(entries|values|forEach|find|get|has)\b/) ||
        connectBody.match(/for\s*\(\s*(?:const|let)\s+\[?\w+(?:,\s*\w+)?\]?\s+of\s+.*sessions/) ||
        connectBody.match(/existing|duplicate|matching/i);

      expect(hasDedupInConnect).toBeTruthy();
    });
  });
});
