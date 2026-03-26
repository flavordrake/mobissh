/**
 * TDD red baseline for session boolean migration (#323)
 *
 * Part B of the state machine migration removes raw boolean fields
 * (wsConnected, sshConnected) from SessionState and replaces them
 * with state-derived accessors reading from session.state.
 *
 * These tests will FAIL until the develop agent completes the migration.
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

const stateModule = await import('../state.js');
const { appState, createSession, transitionSession } = stateModule;

// Attempt to import helpers that should exist after migration.
// Cast to access functions the develop agent will add.
const _mod = stateModule as typeof stateModule & {
  isSessionConnected?: (session: { state: string }) => boolean;
  isWsOpen?: (session: { state: string }) => boolean;
};

// Read source files for structural assertions
const connectionSrc = readFileSync(resolve(__dirname, '../connection.ts'), 'utf-8');
const typeSrc = readFileSync(resolve(__dirname, '../types.ts'), 'utf-8');

// States where the WebSocket should be considered "open" (not idle/closed/failed)
const WS_OPEN_STATES = [
  'connecting',
  'authenticating',
  'connected',
  'soft_disconnected',
  'reconnecting',
] as const;

describe('session boolean migration (#323)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
  });

  // 1. Boolean fields removed from SessionState
  describe('boolean fields removed from SessionState', () => {
    it('wsConnected is not a direct stored property on new sessions', () => {
      const session = createSession('no-ws-bool');
      // After migration, wsConnected should not exist as an own property,
      // or if it exists for backward compat it should be a getter (not in own enumerable props)
      const descriptor = Object.getOwnPropertyDescriptor(session, 'wsConnected');
      // Should either not exist or be a computed getter (not a data property)
      if (descriptor) {
        expect(descriptor.get, 'wsConnected should be a getter, not a stored boolean').toBeDefined();
      } else {
        // Property doesn't exist at all — also acceptable
        expect(session).not.toHaveProperty('wsConnected');
      }
    });

    it('sshConnected is not a direct stored property on new sessions', () => {
      const session = createSession('no-ssh-bool');
      const descriptor = Object.getOwnPropertyDescriptor(session, 'sshConnected');
      if (descriptor) {
        expect(descriptor.get, 'sshConnected should be a getter, not a stored boolean').toBeDefined();
      } else {
        expect(session).not.toHaveProperty('sshConnected');
      }
    });

    it('SessionState type no longer declares wsConnected as boolean', () => {
      // The type definition should not have "wsConnected: boolean"
      // It may have a getter or be removed entirely
      const wsLine = typeSrc.match(/wsConnected\s*:\s*boolean/);
      expect(wsLine, 'types.ts should not declare wsConnected: boolean').toBeNull();
    });

    it('SessionState type no longer declares sshConnected as boolean', () => {
      const sshLine = typeSrc.match(/sshConnected\s*:\s*boolean/);
      expect(sshLine, 'types.ts should not declare sshConnected: boolean').toBeNull();
    });
  });

  // 2. State-derived accessors exist
  describe('state-derived accessors', () => {
    it('isSessionConnected is exported as a function', () => {
      expect(typeof _mod.isSessionConnected).toBe('function');
    });

    it('isWsOpen is exported as a function', () => {
      expect(typeof _mod.isWsOpen).toBe('function');
    });

    it('isSessionConnected returns true only when state is connected', () => {
      // Guard: skip if helper doesn't exist yet (separate test catches that)
      if (typeof _mod.isSessionConnected !== 'function') return;

      const session = createSession('connected-check');
      expect(_mod.isSessionConnected(session)).toBe(false);

      transitionSession('connected-check', 'connecting');
      expect(_mod.isSessionConnected(session)).toBe(false);

      transitionSession('connected-check', 'authenticating');
      expect(_mod.isSessionConnected(session)).toBe(false);

      transitionSession('connected-check', 'connected');
      expect(_mod.isSessionConnected(session)).toBe(true);
    });

    it('isWsOpen returns true for connecting/authenticating/connected/soft_disconnected/reconnecting', () => {
      if (typeof _mod.isWsOpen !== 'function') return;

      for (const targetState of WS_OPEN_STATES) {
        appState.sessions.clear();
        const session = createSession(`ws-open-${targetState}`);
        const id = `ws-open-${targetState}`;

        // Walk through valid transitions to reach the target state
        if (targetState === 'connecting') {
          transitionSession(id, 'connecting');
        } else if (targetState === 'authenticating') {
          transitionSession(id, 'connecting');
          transitionSession(id, 'authenticating');
        } else if (targetState === 'connected') {
          transitionSession(id, 'connecting');
          transitionSession(id, 'authenticating');
          transitionSession(id, 'connected');
        } else if (targetState === 'soft_disconnected') {
          transitionSession(id, 'connecting');
          transitionSession(id, 'authenticating');
          transitionSession(id, 'connected');
          transitionSession(id, 'soft_disconnected');
        } else if (targetState === 'reconnecting') {
          transitionSession(id, 'connecting');
          transitionSession(id, 'authenticating');
          transitionSession(id, 'connected');
          transitionSession(id, 'soft_disconnected');
          transitionSession(id, 'reconnecting');
        }

        expect(
          _mod.isWsOpen(session),
          `isWsOpen should be true for state "${targetState}"`,
        ).toBe(true);
      }
    });

    it('isWsOpen returns false for idle, closed, failed', () => {
      if (typeof _mod.isWsOpen !== 'function') return;

      // idle
      const idleSession = createSession('ws-not-open-idle');
      expect(_mod.isWsOpen(idleSession)).toBe(false);

      // failed
      const failedSession = createSession('ws-not-open-failed');
      transitionSession('ws-not-open-failed', 'connecting');
      transitionSession('ws-not-open-failed', 'failed');
      expect(_mod.isWsOpen(failedSession)).toBe(false);
    });
  });

  // 3. Connection code uses transitionSession instead of boolean assignments
  describe('connection code uses transitionSession', () => {
    it('connection.ts contains transitionSession calls', () => {
      expect(connectionSrc).toContain('transitionSession(');
    });

    it('connection.ts does not assign to session.wsConnected', () => {
      // Match patterns like: session.wsConnected = true/false
      const wsAssign = connectionSrc.match(/session\.wsConnected\s*=/);
      expect(wsAssign, 'connection.ts should not assign to session.wsConnected').toBeNull();
    });

    it('connection.ts does not assign to session.sshConnected', () => {
      const sshAssign = connectionSrc.match(/session\.sshConnected\s*=/);
      expect(sshAssign, 'connection.ts should not assign to session.sshConnected').toBeNull();
    });

    it('connection.ts imports transitionSession from state', () => {
      expect(connectionSrc).toMatch(/import\s+\{[^}]*transitionSession[^}]*\}\s+from\s+['"]\.\/state/);
    });
  });

  // 4. Guards use state instead of booleans
  describe('guards use state instead of booleans', () => {
    it('connection.ts does not use session?.sshConnected in guards', () => {
      // The repeated guard pattern: if (!session?.sshConnected || ...)
      const sshGuard = connectionSrc.match(/session\?\.\s*sshConnected/);
      expect(sshGuard, 'connection.ts should not check session?.sshConnected').toBeNull();
    });

    it('connection.ts does not read session.sshConnected in conditionals', () => {
      // Broader check: any read of sshConnected (not just optional chaining)
      const sshRead = connectionSrc.match(/session\.sshConnected(?!\s*\()/);
      expect(sshRead, 'connection.ts should not read session.sshConnected').toBeNull();
    });

    it('connection.ts does not read session.wsConnected in conditionals', () => {
      const wsRead = connectionSrc.match(/session\.wsConnected(?!\s*\()/);
      expect(wsRead, 'connection.ts should not read session.wsConnected').toBeNull();
    });

    it('SFTP send functions use state-based guard instead of sshConnected', () => {
      // The SFTP functions (sendSftpLs, sendSftpDownload, etc.) should check
      // state or use isSessionConnected, not session?.sshConnected
      const sftpFunctions = connectionSrc.match(
        /export function sendSftp\w+[^}]+}/gs
      );
      if (sftpFunctions) {
        for (const fn of sftpFunctions) {
          expect(fn).not.toContain('sshConnected');
        }
      }
    });
  });

  // 5. Backward compatibility: if wsConnected/sshConnected still readable, they derive from state
  describe('backward compatibility via computed getters', () => {
    it('reading wsConnected on a connecting session returns true (derived from state)', () => {
      const session = createSession('compat-ws');
      transitionSession('compat-ws', 'connecting');
      // If wsConnected still exists as a getter, it should derive from state
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const val = (session as any).wsConnected;
      if (val !== undefined) {
        expect(val).toBe(true);
      }
      // If it's undefined, that's also fine — property was fully removed
    });

    it('reading sshConnected on a connected session returns true (derived from state)', () => {
      const session = createSession('compat-ssh');
      transitionSession('compat-ssh', 'connecting');
      transitionSession('compat-ssh', 'authenticating');
      transitionSession('compat-ssh', 'connected');
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const val = (session as any).sshConnected;
      if (val !== undefined) {
        expect(val).toBe(true);
      }
    });

    it('reading sshConnected on a non-connected session returns false', () => {
      const session = createSession('compat-ssh-false');
      transitionSession('compat-ssh-false', 'connecting');
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const val = (session as any).sshConnected;
      if (val !== undefined) {
        expect(val).toBe(false);
      }
    });

    it('writing to wsConnected throws or is a no-op (not a stored property)', () => {
      const session = createSession('no-write-ws');
      const descriptor = Object.getOwnPropertyDescriptor(session, 'wsConnected');
      if (descriptor) {
        // If it's a getter without setter, assignment should throw in strict mode
        // or be silently ignored. Either way, state should not change.
        expect(descriptor.set).toBeUndefined();
      }
    });
  });
});
