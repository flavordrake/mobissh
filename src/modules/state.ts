/**
 * MobiSSH — Shared mutable application state
 *
 * Extracted from app.js as Phase 2 of modular refactor (#110).
 * All module-level `let` variables live here as properties of a single
 * exported object so that any future module can import and mutate state
 * without relying on shared global scope.
 */

import type { AppState, SessionState, SessionLifecycleState, SessionStateWithCompat } from './types.js';
import { RECONNECT } from './constants.js';
import { DEFAULT_KEY_BAR_CONFIG } from './keybar-config.js';
import { logConnect } from './connect-log.js';

/** Valid transitions for the session lifecycle state machine. */
const VALID_TRANSITIONS: Record<SessionLifecycleState, readonly SessionLifecycleState[]> = {
  idle: ['connecting', 'closed'],
  connecting: ['authenticating', 'failed', 'closed'],
  authenticating: ['connected', 'failed', 'closed'],
  connected: ['soft_disconnected', 'disconnected', 'closed'],
  soft_disconnected: ['reconnecting', 'disconnected', 'closed'],
  reconnecting: ['authenticating', 'connected', 'failed', 'closed'],
  failed: ['reconnecting', 'closed'],
  disconnected: ['reconnecting', 'closed'],
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

function abortCycle(session: SessionState): void {
  if (session._cycle) {
    session._cycle.controller.abort();
    for (const d of session._cycle.disposables) d.dispose();
    session._cycle = null;
  }
}

registerTransitionEffect('connecting', (session) => {
  abortCycle(session);
  if (session.ws) {
    nullWsHandlers(session.ws);
  }
});

registerTransitionEffect('connected', (session) => {
  clearReconnectTimer(session);
  session.reconnectDelay = RECONNECT.INITIAL_DELAY_MS;
});

registerTransitionEffect('disconnected', (session) => {
  abortCycle(session);
  cleanupWebSocket(session);
  clearKeepAlive(session);
});

registerTransitionEffect('reconnecting', (session) => {
  abortCycle(session);
  cleanupWebSocket(session);
  if (session._onDataDisposable) {
    session._onDataDisposable.dispose();
    session._onDataDisposable = null;
  }
});

registerTransitionEffect('closed', (session) => {
  abortCycle(session);
  cleanupWebSocket(session);
  if (session.terminal) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any, @typescript-eslint/no-unsafe-call, @typescript-eslint/no-unsafe-member-access
    (session.terminal as any).dispose();
  }
  clearReconnectTimer(session);
  clearKeepAlive(session);

  // Remove from recentSessions on close (#385)
  if (session.profile) {
    try {
      const raw = localStorage.getItem('recentSessions');
      if (raw) {
        const recent = JSON.parse(raw) as Array<{ host: string; port: number; username: string; profileIdx: number }>;
        const filtered = recent.filter(
          (e) => !(e.host === session.profile!.host && e.port === (session.profile!.port || 22) && e.username === session.profile!.username)
        );
        localStorage.setItem('recentSessions', JSON.stringify(filtered));
      }
    } catch { /* ignore malformed localStorage */ }
  }
});

// -- State-derived accessors --

/** Returns true only when session is in the 'connected' state. */
export function isSessionConnected(session: { state: string }): boolean {
  return session.state === 'connected';
}

/** Returns true when the WebSocket should be considered open (not idle/closed/failed/disconnected). */
export function isWsOpen(session: { state: string }): boolean {
  return !['idle', 'closed', 'failed', 'disconnected'].includes(session.state);
}

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
  // Duplicate detection: error if a session with the same profile already exists.
  // Caller (connect()) must close the old session before creating a new one.
  const parts = id.split(':');
  if (parts.length >= 3) {
    for (const [existingId, existingSession] of appState.sessions) {
      if (existingId === id) continue;
      if (existingSession.profile
        && existingSession.profile.host === parts[0]
        && String(existingSession.profile.port || 22) === parts[1]
        && existingSession.profile.username === parts[2]) {
        console.error(`[state] createSession: duplicate profile ${parts[0]}:${parts[1]}:${parts[2]} — already exists as ${existingId}. Caller must close old session first.`);
        break;
      }
    }
  }

  let _profile: SessionState['profile'] = null;
  // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
  const session: SessionStateWithCompat = Object.create(null);
  Object.defineProperties(session, {
    id: { value: id, writable: true, enumerable: true, configurable: true },
    state: { value: 'idle' as SessionLifecycleState, writable: true, enumerable: true, configurable: true },
    profile: {
      get() { return _profile; },
      set(p: SessionState['profile']) {
        _profile = p;
        if (p?.theme) session.activeThemeName = p.theme;
      },
      enumerable: true,
      configurable: true,
    },
    terminal: { value: null, writable: true, enumerable: true, configurable: true },
    fitAddon: { value: null, writable: true, enumerable: true, configurable: true },
    ws: { value: null, writable: true, enumerable: true, configurable: true },
    reconnectTimer: { value: null, writable: true, enumerable: true, configurable: true },
    reconnectDelay: { value: RECONNECT.INITIAL_DELAY_MS, writable: true, enumerable: true, configurable: true },
    keepAliveTimer: { value: null, writable: true, enumerable: true, configurable: true },
    keepAliveWorker: { value: null, writable: true, enumerable: true, configurable: true },
    activeThemeName: { value: appState.activeThemeName, writable: true, enumerable: true, configurable: true },
    activePanel: { value: 'terminal' as 'terminal' | 'files', writable: true, enumerable: true, configurable: true },
    _onDataDisposable: { value: null, writable: true, enumerable: true, configurable: true },
    _wsConsecFailures: { value: 0, writable: true, enumerable: true, configurable: true },
    _stateChangedAt: { value: Date.now(), writable: true, enumerable: true, configurable: true },
    _cycle: { value: null, writable: true, enumerable: true, configurable: true },
    // Compat getters: derive from session.state
    // Setters are no-ops to avoid throwing in strict mode when legacy code assigns
    wsConnected: {
      get() { return isWsOpen(session); },
      enumerable: true,
      configurable: true,
    },
    sshConnected: {
      get() { return isSessionConnected(session); },
      enumerable: true,
      configurable: true,
    },
  });
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
  session._stateChangedAt = Date.now();

  logConnect('state_transition', id, {
    from: previousState,
    to: targetState,
    failures: session._wsConsecFailures,
    host: session.profile?.host,
  });

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
