/**
 * Regression test for #364: theme should NOT change until session connects.
 *
 * connectFromProfile was applying the profile's theme immediately after
 * calling connect(), before the WebSocket completes SSH handshake.
 * Theme should only be applied when the session reaches 'connected' state.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

describe('theme deferred until connected (#364)', () => {
  it('connectFromProfile does NOT call applyTheme after connect()', () => {
    // Read profiles.ts source and verify applyTheme is not called after connect()
    const src = readFileSync(resolve(__dirname, '..', 'profiles.ts'), 'utf-8');
    const connectFromProfileMatch = src.match(
      /export\s+async\s+function\s+connectFromProfile[\s\S]*?^}/m,
    );
    expect(connectFromProfileMatch).toBeTruthy();
    const body = connectFromProfileMatch![0];

    // There should be NO _applyTheme call in connectFromProfile
    expect(body).not.toContain('_applyTheme');
    expect(body).not.toContain('applyTheme');
  });

  it('connection.ts applies theme in the connected message handler', () => {
    // Read connection.ts source and verify applyTheme is called in the 'connected' case
    const src = readFileSync(resolve(__dirname, '..', 'connection.ts'), 'utf-8');

    // Find the 'connected' case block in _openWebSocket
    const connectedCase = src.match(/case\s+'connected':[\s\S]*?break;/);
    expect(connectedCase).toBeTruthy();

    // It should apply the session's theme. The helper evolved from a direct
    // applyTheme() call to applySessionThemeIfVisible(session), which gates
    // repainting to only session-bound panels (#364 / theme-in-settings).
    expect(connectedCase![0]).toMatch(/applyTheme|applySessionThemeIfVisible/);
  });
});
