/**
 * MobiSSH — Shared mutable application state
 *
 * Extracted from app.js as Phase 2 of modular refactor (#110).
 * All module-level `let` variables live here as properties of a single
 * exported object so that any future module can import and mutate state
 * without relying on shared global scope.
 */

import type { AppState, SessionState, SessionLifecycleState } from './types.js';
import { RECONNECT } from './constants.js';
import { DEFAULT_KEY_BAR_CONFIG } from './keybar-config.js';

/** Valid transitions for the session lifecycle state machine. */
const VALID_TRANSITIONS: Record<SessionLifecycleState, readonly SessionLifecycleState[]> = {
  idle: ['connecting', 'closed'],
  connecting: ['authenticating', 'failed', 'closed'],
  authenticating: ['connected', 'failed', 'closed'],
  connected: ['soft_disconnected', 'disconnected', 'closed'],
  soft_disconnected: ['reconnecting', 'disconnected', 'closed'],
  reconnecting: ['authenticating', 'connected', 'failed', 'closed'],
  failed: ['closed'],
  disconnected: ['closed'],
  closed: [],
};

export const appState: AppState = {
  // Multi-session infrastructure
  sessions: new Map<string, SessionState>(),
  activeSessionId: null,

  // Input state
  isComposing: false,
  ctrlActive: false,

  // Vault
  vaultKey: null,
  vaultMethod: null,
  vaultIdleTimer: null,

  // UI visibility
  keyBarDepth: 1,
  imeMode: false,
  tabBarVisible: true,
  hasConnected: false,
  activeThemeName: 'dark',

  // Session recording (#54)
  recording: false,
  recordingStartTime: null,
  recordingEvents: [],

  // Key bar configuration (#80)
  keyBarConfig: DEFAULT_KEY_BAR_CONFIG,
};

export function currentSession(): SessionState | undefined {
  if (!appState.activeSessionId) return undefined;
  return appState.sessions.get(appState.activeSessionId);
}

export function createSession(id: string): SessionState {
  let _profile: SessionState['profile'] = null;
  const session: SessionState = {
    id,
    state: 'idle',
    get profile() { return _profile; },
    set profile(p: SessionState['profile']) {
      _profile = p;
      if (p?.theme) session.activeThemeName = p.theme;
    },
    terminal: null,
    fitAddon: null,
    ws: null,
    wsConnected: false,
    sshConnected: false,
    reconnectTimer: null,
    reconnectDelay: RECONNECT.INITIAL_DELAY_MS,
    keepAliveTimer: null,
    keepAliveWorker: null,
    activeThemeName: appState.activeThemeName,
  };
  appState.sessions.set(id, session);
  return session;
}

/**
 * Transition a session to a new lifecycle state.
 * Throws if the session doesn't exist or the transition is invalid.
 * Removes the session from the map when transitioning to 'closed'.
 */
export function transitionSession(id: string, targetState: SessionLifecycleState): void {
  const session = appState.sessions.get(id);
  if (!session) {
    throw new Error(`Session "${id}" not found`);
  }

  const allowed = VALID_TRANSITIONS[session.state];
  if (!allowed.includes(targetState)) {
    throw new Error(
      `Invalid transition: "${session.state}" -> "${targetState}" for session "${id}"`,
    );
  }

  session.state = targetState;

  if (targetState === 'closed') {
    appState.sessions.delete(id);
  }
}
