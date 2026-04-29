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

describe('session state management', () => {
  beforeEach(() => {
    appState.sessions.clear();
    appState.activeSessionId = null;
  });

  it('currentSession returns undefined when no active session', () => {
    expect(currentSession()).toBeUndefined();
  });

  it('currentSession returns undefined for non-existent id', () => {
    appState.activeSessionId = 'does-not-exist';
    expect(currentSession()).toBeUndefined();
  });

  it('createSession adds a session to the map', () => {
    const session = createSession('test-1');
    expect(session.id).toBe('test-1');
    expect(appState.sessions.size).toBe(1);
    expect(appState.sessions.get('test-1')).toBe(session);
  });

  it('createSession initializes all fields with defaults', () => {
    const session = createSession('test-2');
    expect(session.profile).toBeNull();
    expect(session.terminal).toBeNull();
    expect(session.fitAddon).toBeNull();
    expect(session.ws).toBeNull();
    expect(session.wsConnected).toBe(false);
    expect(session.sshConnected).toBe(false);
    expect(session.reconnectTimer).toBeNull();
    expect(session.reconnectDelay).toBe(2000);
    expect(session.keepAliveTimer).toBeNull();
    expect(session.activeThemeName).toBe('dark');
  });

  it('currentSession returns the active session after creation', () => {
    const session = createSession('test-3');
    appState.activeSessionId = 'test-3';
    expect(currentSession()).toBe(session);
  });

  it('multiple sessions can coexist in the map', () => {
    createSession('s1');
    createSession('s2');
    createSession('s3');
    expect(appState.sessions.size).toBe(3);

    appState.activeSessionId = 's2';
    expect(currentSession()?.id).toBe('s2');

    appState.activeSessionId = 's1';
    expect(currentSession()?.id).toBe('s1');
  });

  it('createSession inherits current theme from appState', () => {
    appState.activeThemeName = 'nord';
    const session = createSession('themed');
    expect(session.activeThemeName).toBe('nord');
    // Reset
    appState.activeThemeName = 'dark';
  });
});
