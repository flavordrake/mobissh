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
      // Light themes: pure white bg/fg makes bright-white-on-bright-white
      // tool-block highlights (Claude Code) invisible. Map both `white` and
      // `brightWhite` to a slightly darker shade so highlights have contrast.
      white: '#e8e8ec',
      brightWhite: '#d8d8df',
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
      // Solarized canonical: base2 (#eee8d5) for "white", base3 (#fdf6e3)
      // for "brightWhite" — but base3 IS the page bg, so bright-white-bg
      // highlights from Claude Code become invisible. Bump brightWhite
      // a notch darker than the bg so highlights still read.
      white: '#eee8d5',
      brightWhite: '#d3c8a8',
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
  highContrastLight: {
    label: 'High Contrast Light',
    theme: {
      background: '#ffffff',
      foreground: '#000000',
      cursor: '#0000ff',
      selectionBackground: '#0000ff44',
      white: '#e0e0e0',
      brightWhite: '#c0c0c0',
    },
    app: {
      bgDeep: '#ffffff',
      bgPanel: '#f5f5f5',
      bgCard: '#eaeaea',
      bgInput: '#dfdfdf',
      text: '#000000',
      textDim: '#333333',
      border: '#888888',
      accent: '#0000cc',
      accentDim: '#000099',
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
  draculaLight: {
    label: 'Dracula Light',
    theme: {
      background: '#f8f8f2',
      foreground: '#282a36',
      cursor: '#bd93f9',
      selectionBackground: '#bd93f944',
      white: '#e8e8e0',
      brightWhite: '#d8d8d0',
    },
    app: {
      bgDeep: '#efefe8',
      bgPanel: '#f8f8f2',
      bgCard: '#f0eee0',
      bgInput: '#e6e2d2',
      text: '#282a36',
      textDim: '#6272a4',
      border: '#d8d6c8',
      accent: '#7c3aed',
      accentDim: '#5b21b6',
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
  nordLight: {
    label: 'Nord Light',
    theme: {
      background: '#eceff4',
      foreground: '#2e3440',
      cursor: '#5e81ac',
      selectionBackground: '#5e81ac33',
      white: '#dde2e8',
      brightWhite: '#c8d0d8',
    },
    app: {
      bgDeep: '#dde2e8',
      bgPanel: '#eceff4',
      bgCard: '#e5e9f0',
      bgInput: '#d8dee9',
      text: '#2e3440',
      textDim: '#4c566a',
      border: '#c8d0d8',
      accent: '#5e81ac',
      accentDim: '#4c6c95',
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
  gruvboxLight: {
    label: 'Gruvbox Light',
    theme: {
      background: '#fbf1c7',
      foreground: '#3c3836',
      cursor: '#9d0006',
      selectionBackground: '#9d000633',
      white: '#ebdbb2',
      brightWhite: '#d5c4a1',
    },
    app: {
      bgDeep: '#f2e5bc',
      bgPanel: '#fbf1c7',
      bgCard: '#ebdbb2',
      bgInput: '#d5c4a1',
      text: '#3c3836',
      textDim: '#7c6f64',
      border: '#bdae93',
      accent: '#b57614',
      accentDim: '#8f5d10',
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
  monokaiLight: {
    label: 'Monokai Light',
    theme: {
      background: '#fafafa',
      foreground: '#272822',
      cursor: '#75af00',
      selectionBackground: '#75af0033',
      white: '#e8e8e0',
      brightWhite: '#d0d0c8',
    },
    app: {
      bgDeep: '#f0f0eb',
      bgPanel: '#fafafa',
      bgCard: '#f0f0e8',
      bgInput: '#e0e0d8',
      text: '#272822',
      textDim: '#75715e',
      border: '#cccfc7',
      accent: '#75af00',
      accentDim: '#5d8b00',
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
  tokyoNightDay: {
    label: 'Tokyo Night Day',
    theme: {
      background: '#e1e2e7',
      foreground: '#3760bf',
      cursor: '#2e7de9',
      selectionBackground: '#2e7de933',
      white: '#cfd0d6',
      brightWhite: '#b8b9c0',
    },
    app: {
      bgDeep: '#d0d5e0',
      bgPanel: '#e1e2e7',
      bgCard: '#dce0ec',
      bgInput: '#c8cdda',
      text: '#3760bf',
      textDim: '#6172b0',
      border: '#b8bdcc',
      accent: '#2e7de9',
      accentDim: '#1f5fbf',
    },
  },
  ocean: {
    label: 'Ocean',
    theme: {
      background: '#050d18',
      foreground: '#b2d8f0',
      cursor: '#00bcd4',
      selectionBackground: '#00bcd444',
    },
    app: {
      bgDeep: '#030812',
      bgPanel: '#050d18',
      bgCard: '#081726',
      bgInput: '#133b5c',
      text: '#b2d8f0',
      textDim: '#5e8aab',
      border: '#133b5c',
      accent: '#00bcd4',
      accentDim: '#0097a7',
    },
  },
  oceanLight: {
    label: 'Ocean Light',
    theme: {
      background: '#e8f4fa',
      foreground: '#0d3b54',
      cursor: '#00838f',
      selectionBackground: '#00838f33',
      white: '#d0e4ee',
      brightWhite: '#b6cfdc',
    },
    app: {
      bgDeep: '#d6ecf3',
      bgPanel: '#e8f4fa',
      bgCard: '#dceaf2',
      bgInput: '#c8dde8',
      text: '#0d3b54',
      textDim: '#5e8aab',
      border: '#b6cfdc',
      accent: '#0097a7',
      accentDim: '#00768a',
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
  emberLight: {
    label: 'Ember Light',
    theme: {
      background: '#fdf2eb',
      foreground: '#5a2410',
      cursor: '#d84315',
      selectionBackground: '#d8431533',
      white: '#f5e2d3',
      brightWhite: '#e8cab2',
    },
    app: {
      bgDeep: '#f6e6d8',
      bgPanel: '#fdf2eb',
      bgCard: '#f5e2d3',
      bgInput: '#ebd2bc',
      text: '#5a2410',
      textDim: '#a07060',
      border: '#dfbfa5',
      accent: '#d84315',
      accentDim: '#a0300f',
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
  forestLight: {
    label: 'Forest Light',
    theme: {
      background: '#f0f5ec',
      foreground: '#1b3a1b',
      cursor: '#2e7d32',
      selectionBackground: '#2e7d3233',
      white: '#dfe9da',
      brightWhite: '#c5d3bd',
    },
    app: {
      bgDeep: '#e0ead8',
      bgPanel: '#f0f5ec',
      bgCard: '#e3ecdc',
      bgInput: '#d2dec8',
      text: '#1b3a1b',
      textDim: '#5d8059',
      border: '#bcccb0',
      accent: '#2e7d32',
      accentDim: '#1b5e20',
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
  sunsetLight: {
    label: 'Sunset Light',
    theme: {
      background: '#fdf3ea',
      foreground: '#4a2510',
      cursor: '#e65100',
      selectionBackground: '#e6510033',
      white: '#f4e2d4',
      brightWhite: '#e8c9b3',
    },
    app: {
      bgDeep: '#f6e3d6',
      bgPanel: '#fdf3ea',
      bgCard: '#f4e2d4',
      bgInput: '#ecd0bd',
      text: '#4a2510',
      textDim: '#a06a48',
      border: '#dfbb9d',
      accent: '#e65100',
      accentDim: '#bf360c',
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
  synthwaveLight: {
    label: 'Synthwave Light',
    theme: {
      background: '#f5ebff',
      foreground: '#3a1058',
      cursor: '#c800c8',
      selectionBackground: '#c800c833',
      white: '#e3d4f2',
      brightWhite: '#cdb6e3',
    },
    app: {
      bgDeep: '#e8d7f5',
      bgPanel: '#f5ebff',
      bgCard: '#ebdcf7',
      bgInput: '#dcc6ec',
      text: '#3a1058',
      textDim: '#7c5a9a',
      border: '#c8aae0',
      accent: '#c800c8',
      accentDim: '#9d009d',
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
  commodoreLight: {
    label: 'Commodore Light',
    theme: {
      background: '#d8d8e8',
      foreground: '#2828a0',
      cursor: '#a83a3a',
      selectionBackground: '#a83a3a33',
      white: '#c8c8d8',
      brightWhite: '#b0b0c8',
    },
    app: {
      bgDeep: '#c8c8d8',
      bgPanel: '#d8d8e8',
      bgCard: '#cccce0',
      bgInput: '#b8b8d0',
      text: '#2828a0',
      textDim: '#5a5ab0',
      border: '#a8a8c0',
      accent: '#a83a3a',
      accentDim: '#7a2828',
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
  terminalLight: {
    label: 'Terminal Light',
    theme: {
      background: '#e8edf8',
      foreground: '#192c70',
      cursor: '#9c6800',
      selectionBackground: '#9c680033',
      white: '#d2dbeb',
      brightWhite: '#b8c5dc',
    },
    app: {
      bgDeep: '#d8dfee',
      bgPanel: '#e8edf8',
      bgCard: '#dde4f1',
      bgInput: '#cbd4e6',
      text: '#192c70',
      textDim: '#5a6ba0',
      border: '#b8c5dc',
      accent: '#9c6800',
      accentDim: '#754c00',
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
  borlandLight: {
    label: 'Borland Light',
    theme: {
      background: '#fff8d8',
      foreground: '#000088',
      cursor: '#005577',
      selectionBackground: '#00aaaa55',
      white: '#f0e8c0',
      brightWhite: '#d8cfa0',
    },
    app: {
      bgDeep: '#f3eccc',
      bgPanel: '#fff8d8',
      bgCard: '#f7efcc',
      bgInput: '#ebdfb6',
      text: '#000088',
      textDim: '#5a5a98',
      border: '#cabb88',
      accent: '#0055aa',
      accentDim: '#003d77',
    },
  },
  arcticDark: {
    label: 'Arctic Dark',
    theme: {
      background: '#0a1828',
      foreground: '#a8c8e8',
      cursor: '#3399ff',
      selectionBackground: '#3399ff33',
    },
    app: {
      bgDeep: '#06101c',
      bgPanel: '#0a1828',
      bgCard: '#142640',
      bgInput: '#1d3858',
      text: '#a8c8e8',
      textDim: '#5577a0',
      border: '#1a3050',
      accent: '#3399ff',
      accentDim: '#1f7ad9',
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
  cobaltLight: {
    label: 'Cobalt Light',
    theme: {
      background: '#e6f1fb',
      foreground: '#002240',
      cursor: '#a87600',
      selectionBackground: '#a8760033',
      white: '#cfdfee',
      brightWhite: '#b5cadd',
    },
    app: {
      bgDeep: '#d4e4f4',
      bgPanel: '#e6f1fb',
      bgCard: '#daeaf6',
      bgInput: '#c5d8eb',
      text: '#002240',
      textDim: '#3e6688',
      border: '#a4bcd5',
      accent: '#a87600',
      accentDim: '#7a5400',
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
  matrixLight: {
    label: 'Matrix Light',
    theme: {
      background: '#f0fff0',
      foreground: '#003300',
      cursor: '#008822',
      selectionBackground: '#00882233',
      white: '#daefdc',
      brightWhite: '#bcd9c1',
    },
    app: {
      bgDeep: '#e0f4e2',
      bgPanel: '#f0fff0',
      bgCard: '#dff0e0',
      bgInput: '#cae0cc',
      text: '#003300',
      textDim: '#008822',
      border: '#a8c8ac',
      accent: '#006622',
      accentDim: '#004d18',
    },
  },
};

export const THEME_ORDER: readonly ThemeName[] = [
  'dark', 'light',
  'solarizedDark', 'solarizedLight',
  'highContrast', 'highContrastLight',
  'dracula', 'draculaLight',
  'nord', 'nordLight',
  'gruvboxDark', 'gruvboxLight',
  'monokai', 'monokaiLight',
  'tokyoNight', 'tokyoNightDay',
  'ocean', 'oceanLight',
  'ember', 'emberLight',
  'forest', 'forestLight',
  'sunset', 'sunsetLight',
  'synthwave', 'synthwaveLight',
  'commodore', 'commodoreLight',
  'terminal', 'terminalLight',
  'borland', 'borlandLight',
  'arcticDark', 'arctic',
  'cobalt', 'cobaltLight',
  'matrix', 'matrixLight',
];

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
  const command = toolInput?.command ?? toolInput?.file_path ?? (raw.detail as string | undefined) ?? '';
  const desc = (toolInput?.description ?? raw.description ?? '') as string;
  const cwd = (raw.cwd as string | undefined) ?? '';
  const source = cwd ? cwd.split('/').slice(-1)[0] ?? cwd : '';
  const base = desc || (command ? `${toolName}: ${command}` : toolName) || 'Approval required';
  const label = source ? `[${source}] ${base}` : base;
  const requestId = (raw.requestId as string | undefined) ?? '';
  return { toolName, command, label, source, requestId };
}

