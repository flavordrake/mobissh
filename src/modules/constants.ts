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
  // Fall back to deriving the base path from window.location.pathname so the
  // correct subpath is used even when BASE_PATH is not set on the server (#144).
  const { protocol, host, pathname } = window.location;
  const wsProtocol = protocol === 'https:' ? 'wss:' : 'ws:';
  const basePath = document.querySelector<HTMLMetaElement>('meta[name="app-base-path"]')?.content
    ?? pathname.slice(0, pathname.lastIndexOf('/'));
  return `${wsProtocol}//${host}${basePath}`;
}

export const RECONNECT = {
  INITIAL_DELAY_MS: 2000,
  MAX_DELAY_MS: 30000,
  BACKOFF_FACTOR: 1.5,
} as const;

// Key repeat timing for key bar buttons (#89).
// Updated at runtime by _initKeyRepeatCalibration() in ui.ts once the OS
// repeat delay and rate have been measured from physical keydown events.
export const KEY_REPEAT: { DELAY_MS: number; INTERVAL_MS: number } = {
  DELAY_MS: 400,    // hold duration before first repeat (matches typical OS repeat delay)
  INTERVAL_MS: 80,  // interval between repeats (matches typical OS repeat rate)
};

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
    app: {
      bgDeep: '#0d0d1a',
      bgPanel: '#1a1a2e',
      bgCard: '#16213e',
      bgInput: '#0f3460',
      text: '#e0e0e0',
      textDim: '#888',
      border: '#2a2a4a',
      accent: '#00ff88',
      accentDim: '#00cc6a',
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
    app: {
      bgDeep: '#f0f0f5',
      bgPanel: '#ffffff',
      bgCard: '#fafaff',
      bgInput: '#e8eaf6',
      text: '#1a1a1a',
      textDim: '#666',
      border: '#d0d0e0',
      accent: '#0055cc',
      accentDim: '#0044aa',
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
    app: {
      bgDeep: '#001f26',
      bgPanel: '#002b36',
      bgCard: '#073642',
      bgInput: '#0a4a5e',
      text: '#839496',
      textDim: '#586e75',
      border: '#1a3540',
      accent: '#268bd2',
      accentDim: '#1a6fa8',
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
    app: {
      bgDeep: '#eee8d5',
      bgPanel: '#fdf6e3',
      bgCard: '#f8f1d8',
      bgInput: '#f0e6c8',
      text: '#657b83',
      textDim: '#93a1a1',
      border: '#d3c8a8',
      accent: '#268bd2',
      accentDim: '#1a6fa8',
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
    app: {
      bgDeep: '#000000',
      bgPanel: '#1c1c1c',
      bgCard: '#2e2e2e',
      bgInput: '#3d3d3d',
      text: '#ffffff',
      textDim: '#cccccc',
      border: '#555555',
      accent: '#ffff00',
      accentDim: '#cccc00',
    },
  },
  dracula: {
    label: 'Dracula',
    theme: {
      background: '#282a36',
      foreground: '#f8f8f2',
      cursor: '#f8f8f2',
      selectionBackground: '#44475a',
    },
    app: {
      bgDeep: '#1e1f29',
      bgPanel: '#282a36',
      bgCard: '#343746',
      bgInput: '#44475a',
      text: '#f8f8f2',
      textDim: '#6272a4',
      border: '#44475a',
      accent: '#bd93f9',
      accentDim: '#9b6fd9',
    },
  },
  nord: {
    label: 'Nord',
    theme: {
      background: '#2e3440',
      foreground: '#d8dee9',
      cursor: '#d8dee9',
      selectionBackground: '#434c5e',
    },
    app: {
      bgDeep: '#242933',
      bgPanel: '#2e3440',
      bgCard: '#3b4252',
      bgInput: '#434c5e',
      text: '#d8dee9',
      textDim: '#7b88a1',
      border: '#3b4252',
      accent: '#88c0d0',
      accentDim: '#6ba8b8',
    },
  },
  gruvboxDark: {
    label: 'Gruvbox Dark',
    theme: {
      background: '#282828',
      foreground: '#ebdbb2',
      cursor: '#ebdbb2',
      selectionBackground: '#504945',
    },
    app: {
      bgDeep: '#1d2021',
      bgPanel: '#282828',
      bgCard: '#3c3836',
      bgInput: '#504945',
      text: '#ebdbb2',
      textDim: '#928374',
      border: '#3c3836',
      accent: '#fabd2f',
      accentDim: '#d79921',
    },
  },
  monokai: {
    label: 'Monokai',
    theme: {
      background: '#272822',
      foreground: '#f8f8f2',
      cursor: '#f8f8f2',
      selectionBackground: '#49483e',
    },
    app: {
      bgDeep: '#1e1f1a',
      bgPanel: '#272822',
      bgCard: '#3e3d32',
      bgInput: '#49483e',
      text: '#f8f8f2',
      textDim: '#75715e',
      border: '#3e3d32',
      accent: '#a6e22e',
      accentDim: '#86c219',
    },
  },
  tokyoNight: {
    label: 'Tokyo Night',
    theme: {
      background: '#1a1b26',
      foreground: '#a9b1d6',
      cursor: '#c0caf5',
      selectionBackground: '#33467c',
    },
    app: {
      bgDeep: '#13141e',
      bgPanel: '#1a1b26',
      bgCard: '#24283b',
      bgInput: '#33467c',
      text: '#a9b1d6',
      textDim: '#565f89',
      border: '#24283b',
      accent: '#7aa2f7',
      accentDim: '#5d87d9',
    },
  },
  ocean: {
    label: 'Ocean',
    theme: {
      background: '#0a1929',
      foreground: '#b2d8f0',
      cursor: '#00bcd4',
      selectionBackground: '#00bcd444',
    },
    app: {
      bgDeep: '#061220',
      bgPanel: '#0a1929',
      bgCard: '#0d2137',
      bgInput: '#133b5c',
      text: '#b2d8f0',
      textDim: '#5e8aab',
      border: '#133b5c',
      accent: '#00bcd4',
      accentDim: '#0097a7',
    },
  },
  ember: {
    label: 'Ember',
    theme: {
      background: '#1a0a0a',
      foreground: '#f0c8b0',
      cursor: '#ff5722',
      selectionBackground: '#ff572244',
    },
    app: {
      bgDeep: '#120606',
      bgPanel: '#1a0a0a',
      bgCard: '#2d1212',
      bgInput: '#4a1a1a',
      text: '#f0c8b0',
      textDim: '#a07060',
      border: '#3d1515',
      accent: '#ff5722',
      accentDim: '#e64a19',
    },
  },
  forest: {
    label: 'Forest',
    theme: {
      background: '#0a1a0a',
      foreground: '#b8d8b0',
      cursor: '#4caf50',
      selectionBackground: '#4caf5044',
    },
    app: {
      bgDeep: '#061206',
      bgPanel: '#0a1a0a',
      bgCard: '#122d12',
      bgInput: '#1a4a1a',
      text: '#b8d8b0',
      textDim: '#6a9a60',
      border: '#153d15',
      accent: '#4caf50',
      accentDim: '#388e3c',
    },
  },
  sunset: {
    label: 'Sunset',
    theme: {
      background: '#1a0f1e',
      foreground: '#e8c8e0',
      cursor: '#ff9800',
      selectionBackground: '#ff980044',
    },
    app: {
      bgDeep: '#120a14',
      bgPanel: '#1a0f1e',
      bgCard: '#2d1a33',
      bgInput: '#4a2550',
      text: '#e8c8e0',
      textDim: '#9a7090',
      border: '#3d1d44',
      accent: '#ff9800',
      accentDim: '#f57c00',
    },
  },
  synthwave: {
    label: 'Synthwave',
    theme: {
      background: '#0f0a1a',
      foreground: '#e0d0f0',
      cursor: '#ff00ff',
      selectionBackground: '#ff00ff33',
    },
    app: {
      bgDeep: '#080512',
      bgPanel: '#0f0a1a',
      bgCard: '#1a1230',
      bgInput: '#2a1a4a',
      text: '#e0d0f0',
      textDim: '#8070a0',
      border: '#2a1a4a',
      accent: '#ff00ff',
      accentDim: '#cc00cc',
    },
  },
  commodore: {
    label: 'Commodore',
    theme: {
      background: '#3a3ac8',
      foreground: '#ffffff',
      cursor: '#ffff55',
      selectionBackground: '#ffffff44',
    },
    app: {
      bgDeep: '#2828a0',
      bgPanel: '#3a3ac8',
      bgCard: '#4848d8',
      bgInput: '#5858e8',
      text: '#ffffff',
      textDim: '#b0b0ff',
      border: '#5050d0',
      accent: '#ffff55',
      accentDim: '#cccc44',
    },
  },
  terminal: {
    label: 'Terminal',
    theme: {
      background: '#21388a',
      foreground: '#ffffff',
      cursor: '#ffffff',
      selectionBackground: '#ffffff44',
    },
    app: {
      bgDeep: '#192c70',
      bgPanel: '#21388a',
      bgCard: '#2a45a0',
      bgInput: '#3355b8',
      text: '#ffffff',
      textDim: '#a0b8e8',
      border: '#3050a8',
      accent: '#ffcc00',
      accentDim: '#dda800',
    },
  },
  borland: {
    label: 'Borland',
    theme: {
      background: '#0000aa',
      foreground: '#ffff55',
      cursor: '#ffffff',
      selectionBackground: '#00aaaa',
    },
    app: {
      bgDeep: '#000088',
      bgPanel: '#0000aa',
      bgCard: '#0000cc',
      bgInput: '#0000dd',
      text: '#ffff55',
      textDim: '#aaaaaa',
      border: '#0055aa',
      accent: '#55ffff',
      accentDim: '#00cccc',
    },
  },
  arctic: {
    label: 'Arctic',
    theme: {
      background: '#e8f0f8',
      foreground: '#1a3050',
      cursor: '#0066cc',
      selectionBackground: '#0066cc33',
    },
    app: {
      bgDeep: '#d0e0f0',
      bgPanel: '#e8f0f8',
      bgCard: '#f0f5fc',
      bgInput: '#d8e8f5',
      text: '#1a3050',
      textDim: '#5577a0',
      border: '#b8d0e8',
      accent: '#0066cc',
      accentDim: '#004fa0',
    },
  },
  cobalt: {
    label: 'Cobalt',
    theme: {
      background: '#002240',
      foreground: '#ffffff',
      cursor: '#ffcc00',
      selectionBackground: '#ffcc0033',
    },
    app: {
      bgDeep: '#001830',
      bgPanel: '#002240',
      bgCard: '#003366',
      bgInput: '#004488',
      text: '#ffffff',
      textDim: '#6699bb',
      border: '#004488',
      accent: '#ffcc00',
      accentDim: '#dda800',
    },
  },
  matrix: {
    label: 'Matrix',
    theme: {
      background: '#000800',
      foreground: '#00ff41',
      cursor: '#00ff41',
      selectionBackground: '#00ff4133',
    },
    app: {
      bgDeep: '#000400',
      bgPanel: '#000800',
      bgCard: '#001a00',
      bgInput: '#002800',
      text: '#00ff41',
      textDim: '#008822',
      border: '#003300',
      accent: '#00ff41',
      accentDim: '#00cc33',
    },
  },
};

export const THEME_ORDER: readonly ThemeName[] = ['dark', 'light', 'solarizedDark', 'solarizedLight', 'highContrast', 'dracula', 'nord', 'gruvboxDark', 'monokai', 'tokyoNight', 'ocean', 'ember', 'forest', 'sunset', 'synthwave', 'commodore', 'terminal', 'borland', 'arctic', 'cobalt', 'matrix'];

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

// Hardware media/volume keys that must never be intercepted (#221).
// The browser should pass these through to the OS for system volume, playback, etc.
export function isMediaKey(key: string): boolean {
  return key.startsWith('Audio') || key.startsWith('Media');
}

// HTML escaping for safe rendering of user-supplied strings
export function escHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Parse raw hook/approval JSON into a label and metadata for the approval bar. */
export function parseApprovalPayload(raw: Record<string, unknown>): {
  toolName: string; command: string; label: string; source: string; requestId: string;
} {
  const toolName = (raw.tool_name ?? raw.tool ?? '') as string;
  const toolInput = raw.tool_input as Record<string, string> | undefined;
  const command = toolInput?.command ?? toolInput?.file_path ?? (raw.detail as string) ?? '';
  const desc = (toolInput?.description ?? raw.description ?? '') as string;
  const cwd = (raw.cwd as string) ?? '';
  const source = cwd ? cwd.split('/').slice(-1)[0] ?? cwd : '';
  const base = desc || (command ? `${toolName}: ${command}` : toolName) || 'Approval required';
  const label = source ? `[${source}] ${base}` : base;
  const requestId = (raw.requestId as string) ?? '';
  return { toolName, command, label, source, requestId };
}

