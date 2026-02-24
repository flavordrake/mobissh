/**
 * MobiSSH — Shared mutable application state
 *
 * Extracted from app.js as Phase 2 of modular refactor (#110).
 * All module-level `let` variables live here as properties of a single
 * exported object so that any future module can import and mutate state
 * without relying on shared global scope.
 */

import { RECONNECT } from './constants.js';

export const appState = {
  // Core terminal and connection
  terminal: null,
  fitAddon: null,
  ws: null,
  _wsConnected: false,       // WebSocket open (tracked for future use)
  sshConnected: false,        // SSH session established
  currentProfile: null,
  reconnectTimer: null,
  reconnectDelay: RECONNECT.INITIAL_DELAY_MS,
  keepAliveTimer: null,       // application-layer WS keepalive (#29)

  // Input state
  isComposing: false,         // IME composition in progress
  ctrlActive: false,          // sticky Ctrl modifier

  // Vault
  vaultKey: null,             // AES-GCM CryptoKey, null when locked
  vaultMethod: null,          // 'passwordcred' | 'webauthn-prf' | null

  // UI visibility
  keyBarVisible: true,        // key bar show/hide state (#1)
  imeMode: true,              // true = IME/swipe, false = direct char entry (#2)
  tabBarVisible: true,        // visible on cold start (#36); auto-hides after first connect
  hasConnected: false,        // true after first successful SSH session (#36)
  activeThemeName: 'dark',    // current terminal theme key (#47)

  // Selection overlay (#55)
  _syncOverlayMetrics: null,  // set by initIMEInput
  _selectionActive: false,    // true while mobile text selection overlay is active

  // Session recording (#54)
  recording: false,           // true while a recording is in progress
  recordingStartTime: null,   // Date.now() at recording start (ms)
  recordingEvents: [],        // asciicast v2 output events: [elapsed_s, 'o', data]
};
