/**
 * MobiSSH — Shared mutable application state
 *
 * Extracted from app.js as Phase 2 of modular refactor (#110).
 * All module-level `let` variables live here as properties of a single
 * exported object so that any future module can import and mutate state
 * without relying on shared global scope.
 */

import type { AppState, SessionState } from './types.js';
import { RECONNECT } from './constants.js';
import { DEFAULT_KEY_BAR_CONFIG } from './keybar-config.js';

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
  const session: SessionState = {
    id,
    profile: null,
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
