/**
 * modules/keybar-config.ts — Key bar configuration data model and persistence.
 *
 * Defines the KeyBarConfig type, default configuration matching the current
 * hardcoded key bar buttons, and load/save/reset helpers backed by localStorage.
 */

export interface KeyBarButton {
  id: string;
  label: string;
  sequence: string;
  modifiers?: string[];
}

export interface KeyBarRow {
  id: string;
  buttons: KeyBarButton[];
}

export type KeyBarConfig = KeyBarRow[];

const STORAGE_KEY = 'keyBarConfig';

export const DEFAULT_KEY_BAR_CONFIG: KeyBarConfig = [
  {
    id: 'row-keys',
    buttons: [
      { id: 'keyEsc',   label: 'Esc',  sequence: '\x1b' },
      { id: 'keyTab',   label: '↹',    sequence: '\t' },
      { id: 'keySlash', label: '/',    sequence: '/' },
      { id: 'keyDash',  label: '-',    sequence: '-' },
      { id: 'keyPipe',  label: '|',    sequence: '|' },
      { id: 'keyCtrlC', label: '^C',   sequence: '\x03' },
      { id: 'keyCtrlZ', label: '^Z',   sequence: '\x1a' },
      { id: 'keyCtrlB', label: '^B',   sequence: '\x02' },
      { id: 'keyCtrlD', label: '^D',   sequence: '\x04' },
    ],
  },
  {
    id: 'row-nav',
    buttons: [
      { id: 'keyLeft',  label: '◀',    sequence: '\x1b[D' },
      { id: 'keyUp',    label: '▲',    sequence: '\x1b[A' },
      { id: 'keyDown',  label: '▼',    sequence: '\x1b[B' },
      { id: 'keyRight', label: '▶',    sequence: '\x1b[C' },
      { id: 'keyHome',  label: 'Home', sequence: '\x1b[H' },
      { id: 'keyEnd',   label: 'End',  sequence: '\x1b[F' },
      { id: 'keyPgUp',  label: 'PgUp', sequence: '\x1b[5~' },
      { id: 'keyPgDn',  label: 'PgDn', sequence: '\x1b[6~' },
    ],
  },
];

export function loadKeyBarConfig(): KeyBarConfig {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return DEFAULT_KEY_BAR_CONFIG;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isValidKeyBarConfig(parsed)) return DEFAULT_KEY_BAR_CONFIG;
    return parsed;
  } catch {
    return DEFAULT_KEY_BAR_CONFIG;
  }
}

export function saveKeyBarConfig(config: KeyBarConfig): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

export function resetKeyBarConfig(): void {
  localStorage.removeItem(STORAGE_KEY);
}

function isValidKeyBarConfig(value: unknown): value is KeyBarConfig {
  if (!Array.isArray(value)) return false;
  for (const row of value) {
    if (typeof row !== 'object' || row === null) return false;
    const r = row as Record<string, unknown>;
    if (typeof r['id'] !== 'string') return false;
    if (!Array.isArray(r['buttons'])) return false;
    for (const btn of r['buttons'] as unknown[]) {
      if (typeof btn !== 'object' || btn === null) return false;
      const b = btn as Record<string, unknown>;
      if (typeof b['id'] !== 'string') return false;
      if (typeof b['label'] !== 'string') return false;
      if (typeof b['sequence'] !== 'string') return false;
    }
  }
  return true;
}
