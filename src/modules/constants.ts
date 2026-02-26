/**
 * MobiSSH — Pure constants and configuration
 *
 * Extracted from app.js as Phase 1 of modular refactor (#110).
 * Only pure data and pure functions live here — no DOM reads, no mutable state.
 */

import type { ThemeName, ThemeEntry } from './types.js';

export function getDefaultWsUrl(): string {
  // WebSocket bridge is served from the same origin as the frontend.
  // When deployed behind a reverse proxy at a subpath (e.g. /ssh), the server
  // injects <meta name="app-base-path"> so the WebSocket URL includes that prefix.
  const { protocol, host } = window.location;
  const wsProtocol = protocol === 'https:' ? 'wss:' : 'ws:';
  const basePath = document.querySelector<HTMLMetaElement>('meta[name="app-base-path"]')?.content ?? '';
  return `${wsProtocol}//${host}${basePath}`;
}

export const RECONNECT = {
  INITIAL_DELAY_MS: 2000,
  MAX_DELAY_MS: 30000,
  BACKOFF_FACTOR: 1.5,
} as const;

// Key repeat timing for key bar buttons (#89)
export const KEY_REPEAT = {
  DELAY_MS: 400,    // hold duration before first repeat (matches typical OS repeat delay)
  INTERVAL_MS: 80,  // interval between repeats (matches typical OS repeat rate)
} as const;

// ─── Terminal themes (#47) ────────────────────────────────────────────────────

export const THEMES: Record<ThemeName, ThemeEntry> = {
  dark: {
    label: 'Dark',
    theme: {
      background: '#000000',
      foreground: '#e0e0e0',
      cursor: '#00ff88',
      selectionBackground: '#00ff8844',
    },
  },
  light: {
    label: 'Light',
    theme: {
      background: '#ffffff',
      foreground: '#1a1a1a',
      cursor: '#0055cc',
      selectionBackground: '#0055cc44',
    },
  },
  solarizedDark: {
    label: 'Solarized Dark',
    theme: {
      background: '#002b36',
      foreground: '#839496',
      cursor: '#268bd2',
      selectionBackground: '#268bd244',
    },
  },
  solarizedLight: {
    label: 'Solarized Light',
    theme: {
      background: '#fdf6e3',
      foreground: '#657b83',
      cursor: '#268bd2',
      selectionBackground: '#268bd244',
    },
  },
  highContrast: {
    label: 'High Contrast',
    theme: {
      background: '#000000',
      foreground: '#ffffff',
      cursor: '#ffff00',
      selectionBackground: '#ffff0044',
    },
  },
};

export const THEME_ORDER: readonly ThemeName[] = ['dark', 'light', 'solarizedDark', 'solarizedLight', 'highContrast'];

// ANSI escape sequences for terminal colouring
export const ANSI = {
  green: (s: string): string => `\x1b[32m${s}\x1b[0m`,
  yellow: (s: string): string => `\x1b[33m${s}\x1b[0m`,
  red: (s: string): string => `\x1b[31m${s}\x1b[0m`,
  bold: (s: string): string => `\x1b[1m${s}\x1b[0m`,
  dim: (s: string): string => `\x1b[2m${s}\x1b[0m`,
};

// Terminal key map: DOM key name → VT sequence
export const KEY_MAP: Record<string, string> = {
  Enter: '\r',
  Backspace: '\x7f',
  Tab: '\t',
  Escape: '\x1b',
  ArrowUp: '\x1b[A',
  ArrowDown: '\x1b[B',
  ArrowRight: '\x1b[C',
  ArrowLeft: '\x1b[D',
  Home: '\x1b[H',
  End: '\x1b[F',
  PageUp: '\x1b[5~',
  PageDown: '\x1b[6~',
  Delete: '\x1b[3~',
  Insert: '\x1b[2~',
  F1: '\x1bOP', F2: '\x1bOQ', F3: '\x1bOR', F4: '\x1bOS',
  F5: '\x1b[15~', F6: '\x1b[17~', F7: '\x1b[18~', F8: '\x1b[19~',
  F9: '\x1b[20~', F10: '\x1b[21~', F11: '\x1b[23~', F12: '\x1b[24~',
};

export const FONT_SIZE = { MIN: 8, MAX: 32 } as const;

// HTML escaping for safe rendering of user-supplied strings
export function escHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

