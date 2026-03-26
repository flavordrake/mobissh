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

// -- Side-effect registration --

type TransitionEffectCallback = (session: SessionState, previousState: SessionLifecycleState) => void;
type StateChangeCallback = (session: SessionState, newState: SessionLifecycleState, oldState: SessionLifecycleState) => void;

const transitionEffects = new Map<SessionLifecycleState, TransitionEffectCallback[]>();
const stateChangeSubscribers: StateChangeCallback[] = [];

/** Register a callback that fires when any session enters the given state. */
export function registerTransitionEffect(state: SessionLifecycleState, callback: TransitionEffectCallback): void {
  const list = transitionEffects.get(state);
  if (list) {
    list.push(callback);
  } else {
    transitionEffects.set(state, [callback]);
  }
}

/** Subscribe to all state transitions. Callback receives (session, newState, oldState). */
export function onStateChange(callback: StateChangeCallback): void {
  stateChangeSubscribers.push(callback);
}

// -- Helpers for built-in effects --

/** Null all WS event handlers on a WebSocket. */
function nullWsHandlers(ws: WebSocket): void {
  ws.onmessage = null;
  ws.onerror = null;
  ws.onclose = null;
  ws.onopen = null;
}

/** Full WS cleanup: null handlers, close, set session.ws to null. */
function cleanupWebSocket(session: SessionState): void {
  if (session.ws) {
    nullWsHandlers(session.ws);
    session.ws.close();
    session.ws = null;
  }
}

/** Clear keepAliveTimer and set to null. */
function clearKeepAlive(session: SessionState): void {
  if (session.keepAliveTimer != null) {
    clearInterval(session.keepAliveTimer);
    session.keepAliveTimer = null;
  }
}

/** Clear reconnectTimer and set to null. */
function clearReconnectTimer(session: SessionState): void {
  if (session.reconnectTimer != null) {
    clearTimeout(session.reconnectTimer);
    session.reconnectTimer = null;
  }
}

// -- Built-in side-effects --

registerTransitionEffect('connecting', (session) => {
  if (session.ws) {
    nullWsHandlers(session.ws);
  }
});

registerTransitionEffect('connected', (session) => {
  clearReconnectTimer(session);
  session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
});

registerTransitionEffect('disconnected', (session) => {
  cleanupWebSocket(session);
  clearKeepAlive(session);
});

registerTransitionEffect('reconnecting', (session) => {
  cleanupWebSocket(session);
  if (session._onDataDisposable) {
    session._onDataDisposable.dispose();
  }
});

registerTransitionEffect('closed', (session) => {
  cleanupWebSocket(session);
  if (session.terminal) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (session.terminal as any).dispose();
  }
  clearReconnectTimer(session);
  clearKeepAlive(session);
});

// -- State and session management --

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
    _onDataDisposable: null,
  };
  appState.sessions.set(id, session);
  return session;
}

/**
 * Transition a session to a new lifecycle state.
 * Throws if the session doesn't exist or the transition is invalid.
 * Fires registered transition effects and state change subscribers.
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

  const previousState = session.state;
  session.state = targetState;

  // Fire onEnter effects for the target state
  const effects = transitionEffects.get(targetState);
  if (effects) {
    for (const effect of effects) {
      effect(session, previousState);
    }
  }

  // Notify state change subscribers
  for (const subscriber of stateChangeSubscribers) {
    subscriber(session, targetState, previousState);
  }

  if (targetState === 'closed') {
    appState.sessions.delete(id);
  }
}
