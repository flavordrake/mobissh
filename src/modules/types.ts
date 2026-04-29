/**
 * Shared type definitions for MobiSSH modules.
 *
 * All interfaces used across module boundaries live here. Modules import
 * types with `import type { ... } from './types.js'` so there is zero
 * runtime cost — TypeScript erases type-only imports during compilation.
 */

import type { KeyBarConfig } from './keybar-config.js';

// ── Domain types ────────────────────────────────────────────────────────────

export type ThemeName =
  | 'dark' | 'light'
  | 'solarizedDark' | 'solarizedLight'
  | 'highContrast' | 'highContrastLight'
  | 'dracula' | 'draculaLight'
  | 'nord' | 'nordLight'
  | 'gruvboxDark' | 'gruvboxLight'
  | 'monokai' | 'monokaiLight'
  | 'tokyoNight' | 'tokyoNightDay'
  | 'ocean' | 'oceanLight'
  | 'ember' | 'emberLight'
  | 'forest' | 'forestLight'
  | 'sunset' | 'sunsetLight'
  | 'synthwave' | 'synthwaveLight'
  | 'commodore' | 'commodoreLight'
  | 'terminal' | 'terminalLight'
  | 'borland' | 'borlandLight'
  | 'arcticDark' | 'arctic'
  | 'cobalt' | 'cobaltLight'
  | 'matrix' | 'matrixLight';

export interface SSHProfile {
  title: string;
  host: string;
  port: number;
  username: string;
  authType: 'password' | 'key';
  password?: string;
  privateKey?: string;
  passphrase?: string;
  initialCommand?: string;
  vaultId?: string;
  hasVaultCreds?: boolean;
  keyVaultId?: string;
  theme?: ThemeName;
  /** Visual accent color for this profile as a CSS color (hex). Used as the
   *  dot color in session menus and as the left-border accent in profile /
   *  recent-session lists. Falls back to the theme's accent when unset. */
  color?: string;
}

export type VaultMethod = 'master-pw' | 'master-pw+bio' | null;

// Vault data stored in localStorage
export interface WrappedKey {
  iv: string;   // base64 AES-GCM IV
  ct: string;   // base64 ciphertext of the DEK
}

export interface VaultMeta {
  salt: string;         // base64 PBKDF2 salt (32 bytes)
  dekPw: WrappedKey;    // DEK wrapped by password-derived KEK
  dekBio?: WrappedKey;  // DEK wrapped by biometric-derived KEK (optional)
}

export type ConnectionStatus = 'connecting' | 'connected' | 'disconnected';

// ── Files favorites (#470) ──────────────────────────────────────────────────

export interface Favorite {
  path: string;
  isFile: boolean;
  label?: string;
}

export type SessionLifecycleState =
  | 'idle'
  | 'connecting'
  | 'authenticating'
  | 'connected'
  | 'soft_disconnected'
  | 'reconnecting'
  | 'disconnected'
  | 'failed'
  | 'closed';

// ── Terminal theme ──────────────────────────────────────────────────────────

export interface TerminalTheme {
  background: string;
  foreground: string;
  cursor: string;
  selectionBackground: string;
  /** Optional ANSI palette overrides — needed for light themes where the
   *  default xterm `brightWhite` (#ffffff) is the same as the page bg, so
   *  any TUI rendering bright-white-bg highlights becomes invisible
   *  (Claude Code does this for tool-use blocks). Set the eight standard
   *  + eight bright variants you want to override; xterm uses defaults
   *  for the rest. */
  black?: string;
  red?: string;
  green?: string;
  yellow?: string;
  blue?: string;
  magenta?: string;
  cyan?: string;
  white?: string;
  brightBlack?: string;
  brightRed?: string;
  brightGreen?: string;
  brightYellow?: string;
  brightBlue?: string;
  brightMagenta?: string;
  brightCyan?: string;
  brightWhite?: string;
}

export interface AppColors {
  bgDeep: string;
  bgPanel: string;
  bgCard: string;
  bgInput: string;
  text: string;
  textDim: string;
  border: string;
  accent: string;
  accentDim: string;
}

export interface ThemeEntry {
  label: string;
  theme: TerminalTheme;
  app: AppColors;
}

// ── Session state (per-connection) ──────────────────────────────────────────

export interface ConnectionCycle {
  controller: AbortController;
  disposables: Array<{ dispose(): void }>;
}

export interface SessionState {
  id: string;
  state: SessionLifecycleState;
  profile: SSHProfile | null;
  terminal: Terminal | null;
  fitAddon: FitAddon.FitAddon | null;
  ws: WebSocket | null;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
  reconnectDelay: number;
  keepAliveTimer: ReturnType<typeof setInterval> | null;
  activeThemeName: ThemeName;
  /** Which panel this session was last in — restored on session switch (#468). */
  activePanel: 'terminal' | 'files';
  _onDataDisposable: { dispose: () => void } | null;
  _wsConsecFailures: number;
  /** Wall-clock ms when the session most recently transitioned state.
   *  Used by the visibility_resume handler to detect "stuck in flight"
   *  sessions (e.g. a reconnecting attempt whose timer was suspended by
   *  Android Chrome's background throttle) — see connection.ts. */
  _stateChangedAt: number;
  _cycle: ConnectionCycle | null;
}

/** SessionState with backward-compat read-only getters for wsConnected/sshConnected. */
export type SessionStateWithCompat = SessionState & {
  readonly wsConnected: ReturnType<() => boolean>;
  readonly sshConnected: ReturnType<() => boolean>;
};

// ── Application state ───────────────────────────────────────────────────────

export interface AppState {
  // Multi-session infrastructure
  sessions: Map<string, SessionState>;
  activeSessionId: string | null;

  // Input state
  isComposing: boolean;
  ctrlActive: boolean;

  // Vault
  vaultKey: CryptoKey | null;
  vaultMethod: VaultMethod;
  vaultIdleTimer: ReturnType<typeof setTimeout> | null;

  // UI visibility
  keyBarDepth: 0 | 1 | 2 | 3;
  imeMode: boolean;
  tabBarVisible: boolean;
  hasConnected: boolean;
  activeThemeName: ThemeName;

  // Session recording (#54)
  recording: boolean;
  recordingStartTime: number | null;
  recordingEvents: [number, string, string][];

  // Key bar configuration (#80)
  keyBarConfig: KeyBarConfig;
}

// ── CSS layout constants ────────────────────────────────────────────────────

export interface RootCSS {
  tabHeight: string;
  keybarHeight: string;
}

// ── DI dependency interfaces ────────────────────────────────────────────────

export interface RecordingDeps {
  toast: (msg: string) => void;
}

export interface ProfilesDeps {
  toast: (msg: string) => void;
  navigateToConnect: () => void;
}

export interface SettingsDeps {
  toast: (msg: string) => void;
  applyFontSize: (size: number) => void;
  applyTheme: (name: string, opts?: { persist?: boolean }) => void;
}

export interface ConnectionDeps {
  toast: (msg: string) => void;
  setStatus: (state: ConnectionStatus, text: string) => void;
  focusIME: () => void;
  applyTabBarVisibility: () => void;
}

export interface UIDeps {
  keyboardVisible: () => boolean;
  ROOT_CSS: RootCSS;
  applyFontSize: (size: number) => void;
  applyTheme: (name: string, opts?: { persist?: boolean }) => void;
}

export interface IMEDeps {
  handleResize: () => void;
  applyFontSize: (size: number) => void;
}

// ── SSH bridge protocol messages ────────────────────────────────────────────

export interface SftpEntry {
  name: string;
  isDir: boolean;
  size: number;
  mtime: string;
  atime?: string;
  permissions?: number;
  uid?: number;
  gid?: number;
  isSymlink?: boolean;
}

// [SERVER_MESSAGE] -- keep in sync with server/index.js SFTP_RESULTS and connection.ts SftpMsg
export type ServerMessage =
  | { type: 'connected' }
  | { type: 'output'; data: string }
  | { type: 'error'; message: string }
  | { type: 'disconnected'; reason?: string }
  | { type: 'hostkey'; host: string; port: number; keyType: string; fingerprint: string }
  | { type: 'sftp_ls_result'; requestId: string; entries: SftpEntry[] }
  | { type: 'sftp_download_result'; requestId: string; data?: string; ok?: boolean; error?: string }
  | { type: 'sftp_download_meta'; requestId: string; size: number }
  | { type: 'sftp_download_chunk'; requestId: string; offset: number; data: string }
  | { type: 'sftp_download_chunk_bin'; requestId: string; offset: number; size: number }
  | { type: 'sftp_download_end'; requestId: string }
  | { type: 'sftp_upload_ack'; requestId: string; offset: number }
  | { type: 'sftp_upload_result'; requestId: string; ok: boolean }
  | { type: 'sftp_rename_result'; requestId: string; ok: boolean }
  | { type: 'sftp_stat_result'; requestId: string; stat: { isDir: boolean; size: number; mtime: number } }
  | { type: 'sftp_delete_result'; requestId: string; ok: boolean }
  | { type: 'sftp_realpath_result'; requestId: string; path: string }
  | { type: 'sftp_error'; requestId: string; message: string }
  | { type: 'approval_prompt'; tool?: string; detail?: string; description?: string }
  | { type: 'hook_event'; event?: string; tool?: string; detail?: string; description?: string };

export interface ConnectMessage {
  type: 'connect';
  host: string;
  port: number;
  username: string;
  password?: string;
  privateKey?: string;
  passphrase?: string;
  initialCommand?: string;
  allowPrivate?: boolean;
}

export interface ResizeMessage {
  type: 'resize';
  cols: number;
  rows: number;
}

export interface InputMessage {
  type: 'input';
  data: string;
}

export interface HostKeyResponseMessage {
  type: 'hostkey_response';
  accepted: boolean;
}

// ── Asciicast v2 recording ──────────────────────────────────────────────────

export interface AsciicastHeader {
  version: 2;
  width: number;
  height: number;
  timestamp: number;
  title: string;
}

export type AsciicastEvent = [number, 'o', string];
