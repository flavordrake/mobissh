/**
 * Ambient declarations for globals loaded via <script> tags in index.html.
 *
 * xterm.js and xterm-addon-fit are loaded from public/vendor/ as UMD bundles,
 * exposing `Terminal` and `FitAddon` on the global scope. This file maps those
 * globals to proper TypeScript types so tsc can check usage without imports.
 *
 * PasswordCredential and WebAuthn PRF extension types are also declared here
 * since they're Chrome/platform-specific APIs not in the standard lib.
 */

import type { Terminal as XTermTerminal, ITerminalOptions, ITheme } from '@xterm/xterm';

// ── xterm.js globals ────────────────────────────────────────────────────────

declare global {
  // `new Terminal(opts)` in source code → delegates to @xterm/xterm's Terminal class
  const Terminal: typeof XTermTerminal;
  type Terminal = XTermTerminal;

  namespace FitAddon {
    class FitAddon {
      activate(terminal: Terminal): void;
      dispose(): void;
      fit(): void;
      proposeDimensions(): { cols: number; rows: number } | undefined;
    }
  }

  // ── PasswordCredential (Chrome/Android) ─────────────────────────────────

  interface PasswordCredentialData {
    id: string;
    password: string;
    name?: string;
  }

  interface PasswordCredential extends Credential {
    readonly password: string;
    readonly name: string;
  }

  // eslint-disable-next-line no-var
  var PasswordCredential: {
    new(data: PasswordCredentialData): PasswordCredential;
    prototype: PasswordCredential;
  };

  // ── WebAuthn PRF extension ──────────────────────────────────────────────

  interface AuthenticationExtensionsClientInputs {
    prf?: {
      eval?: { first: ArrayBuffer };
    } | Record<string, never>;
  }

  interface AuthenticationExtensionsClientOutputs {
    prf?: {
      enabled?: boolean;
      results?: { first: ArrayBuffer };
    };
  }

  // ── Credential Management overloads ─────────────────────────────────────

  interface CredentialRequestOptions {
    password?: boolean;
    mediation?: CredentialMediationRequirement;
  }

  // ── Screen Wake Lock ────────────────────────────────────────────────────

  interface WakeLockSentinel extends EventTarget {
    readonly released: boolean;
    readonly type: 'screen';
    release(): Promise<void>;
  }

  interface WakeLock {
    request(type: 'screen'): Promise<WakeLockSentinel>;
  }

  interface Navigator {
    readonly wakeLock: WakeLock;
  }
}

export {};
