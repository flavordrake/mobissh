/**
 * Unit tests for session lifecycle state machine (#286)
 *
 * These tests express EXPECTED behavior for the lifecycle enum that will
 * replace boolean-based session state (sshConnected, wsConnected).
 * They will FAIL until the develop agent adds the state field and
 * transition logic to make them pass.
 *
 * Lifecycle states:
 *   idle -> connecting -> authenticating -> connected
 *   connected -> soft_disconnected -> reconnecting -> connected
 *   connected -> disconnected
 *   connecting -> failed
 *   idle -> closed
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

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

const { appState, currentSession, createSession } = await import('../state.js');

// The develop agent will export transitionSession from state.ts.
// For now we import it optimistically — the test will fail at import
// if it doesn't exist yet, which is the expected red baseline.
const { transitionSession } = await import('../state.js') as typeof import('../state.js') & {
  transitionSession: (id: string, to: string) => void;
};

/** All valid lifecycle states */
const LIFECYCLE_STATES = [
  'idle',
  'connecting',
  'authenticating',
  'connected',
  'soft_disconnected',
  'reconnecting',
  'disconnected',
  'failed',
  'closed',
] as const;

describe('session lifecycle state machine (#286)', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
  });

  // 1. SessionState has a `state` field
  describe('SessionState has a state field', () => {
    it('session object includes a state property', () => {
      const session = createSession('has-state');
      expect(session).toHaveProperty('state');
    });

    it('state is a string matching a known lifecycle value', () => {
      const session = createSession('state-type');
      expect(typeof session.state).toBe('string');
      expect(LIFECYCLE_STATES).toContain(session.state);
    });
  });

  // 2. createSession starts in idle
  describe('createSession starts in idle', () => {
    it('new session state is idle', () => {
      const session = createSession('fresh');
      expect(session.state).toBe('idle');
    });

    it('multiple new sessions all start in idle', () => {
      const s1 = createSession('a');
      const s2 = createSession('b');
      const s3 = createSession('c');
      expect(s1.state).toBe('idle');
      expect(s2.state).toBe('idle');
      expect(s3.state).toBe('idle');
    });
  });

  // 3. Valid transitions
  describe('valid transitions', () => {
    it('idle -> connecting', () => {
      const session = createSession('t1');
      transitionSession('t1', 'connecting');
      expect(session.state).toBe('connecting');
    });

    it('connecting -> authenticating', () => {
      const session = createSession('t2');
      transitionSession('t2', 'connecting');
      transitionSession('t2', 'authenticating');
      expect(session.state).toBe('authenticating');
    });

    it('authenticating -> connected', () => {
      const session = createSession('t3');
      transitionSession('t3', 'connecting');
      transitionSession('t3', 'authenticating');
      transitionSession('t3', 'connected');
      expect(session.state).toBe('connected');
    });

    it('connected -> soft_disconnected', () => {
      const session = createSession('t4');
      transitionSession('t4', 'connecting');
      transitionSession('t4', 'authenticating');
      transitionSession('t4', 'connected');
      transitionSession('t4', 'soft_disconnected');
      expect(session.state).toBe('soft_disconnected');
    });

    it('soft_disconnected -> reconnecting', () => {
      const session = createSession('t5');
      transitionSession('t5', 'connecting');
      transitionSession('t5', 'authenticating');
      transitionSession('t5', 'connected');
      transitionSession('t5', 'soft_disconnected');
      transitionSession('t5', 'reconnecting');
      expect(session.state).toBe('reconnecting');
    });

    it('reconnecting -> connected', () => {
      const session = createSession('t6');
      transitionSession('t6', 'connecting');
      transitionSession('t6', 'authenticating');
      transitionSession('t6', 'connected');
      transitionSession('t6', 'soft_disconnected');
      transitionSession('t6', 'reconnecting');
      transitionSession('t6', 'connected');
      expect(session.state).toBe('connected');
    });

    it('connected -> disconnected', () => {
      const session = createSession('t7');
      transitionSession('t7', 'connecting');
      transitionSession('t7', 'authenticating');
      transitionSession('t7', 'connected');
      transitionSession('t7', 'disconnected');
      expect(session.state).toBe('disconnected');
    });

    it('connecting -> failed', () => {
      const session = createSession('t8');
      transitionSession('t8', 'connecting');
      transitionSession('t8', 'failed');
      expect(session.state).toBe('failed');
    });

    it('idle -> closed', () => {
      createSession('t9');
      transitionSession('t9', 'closed');
      // Session removed from map (tested separately), but transition should not throw
    });
  });

  // 4. Invalid transitions rejected
  describe('invalid transitions rejected', () => {
    it('idle -> connected (skips connecting) throws', () => {
      createSession('inv1');
      expect(() => transitionSession('inv1', 'connected')).toThrow();
    });

    it('connected -> idle (backwards) throws', () => {
      createSession('inv2');
      transitionSession('inv2', 'connecting');
      transitionSession('inv2', 'authenticating');
      transitionSession('inv2', 'connected');
      expect(() => transitionSession('inv2', 'idle')).toThrow();
    });

    it('failed -> connected (must go through connecting) throws', () => {
      createSession('inv3');
      transitionSession('inv3', 'connecting');
      transitionSession('inv3', 'failed');
      expect(() => transitionSession('inv3', 'connected')).toThrow();
    });

    it('transition on non-existent session throws', () => {
      expect(() => transitionSession('ghost', 'connecting')).toThrow();
    });
  });

  // 5. currentSession state reflects lifecycle
  describe('currentSession state reflects lifecycle', () => {
    it('currentSession().state returns connected after transition', () => {
      createSession('reflect');
      appState.activeSessionId = 'reflect';
      transitionSession('reflect', 'connecting');
      transitionSession('reflect', 'authenticating');
      transitionSession('reflect', 'connected');
      expect(currentSession()?.state).toBe('connected');
    });

    it('currentSession().state updates through each transition', () => {
      createSession('track');
      appState.activeSessionId = 'track';

      expect(currentSession()?.state).toBe('idle');

      transitionSession('track', 'connecting');
      expect(currentSession()?.state).toBe('connecting');

      transitionSession('track', 'authenticating');
      expect(currentSession()?.state).toBe('authenticating');

      transitionSession('track', 'connected');
      expect(currentSession()?.state).toBe('connected');
    });
  });

  // 6. Session cleanup on closed
  describe('session cleanup on closed', () => {
    it('transitioning to closed removes session from map', () => {
      createSession('cleanup');
      expect(appState.sessions.has('cleanup')).toBe(true);
      transitionSession('cleanup', 'closed');
      expect(appState.sessions.has('cleanup')).toBe(false);
    });

    it('closed session is no longer returned by currentSession', () => {
      createSession('gone');
      appState.activeSessionId = 'gone';
      expect(currentSession()).toBeDefined();
      transitionSession('gone', 'closed');
      expect(currentSession()).toBeUndefined();
    });

    it('other sessions are not affected when one closes', () => {
      createSession('keep');
      createSession('remove');
      transitionSession('remove', 'closed');
      expect(appState.sessions.has('keep')).toBe(true);
      expect(appState.sessions.has('remove')).toBe(false);
      expect(appState.sessions.size).toBe(1);
    });
  });
});
