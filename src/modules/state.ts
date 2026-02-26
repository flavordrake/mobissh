/**
 * MobiSSH — Shared mutable application state
 *
 * Extracted from app.js as Phase 2 of modular refactor (#110).
 * All module-level `let` variables live here as properties of a single
 * exported object so that any future module can import and mutate state
 * without relying on shared global scope.
 */

import type { AppState } from './types.js';
import { RECONNECT } from './constants.js';

export const appState: AppState = {
  // Core terminal and connection
  terminal: null,
  fitAddon: null,
  ws: null,
  _wsConnected: false,
  sshConnected: false,
  currentProfile: null,
  reconnectTimer: null,
  reconnectDelay: RECONNECT.INITIAL_DELAY_MS,
  keepAliveTimer: null,

  // Input state
  isComposing: false,
  ctrlActive: false,

  // Vault
  vaultKey: null,
  vaultMethod: null,
  vaultIdleTimer: null,

  // UI visibility
  keyBarVisible: true,
  imeMode: true,
  tabBarVisible: true,
  hasConnected: false,
  activeThemeName: 'dark',

  // Session recording (#54)
  recording: false,
  recordingStartTime: null,
  recordingEvents: [],
};
