/**
 * Red baseline for issue #499 — Forwards panel UI gating.
 *
 * Covers:
 *   A9  loadCapabilities() resolving with local:true makes the Forwards panel
 *       reachable; local:false keeps it hidden. Observable from both
 *       appState.capabilities.portForward.local AND the DOM.
 *   C1  Panel hidden when capabilities haven't loaded yet
 *   C2  Panel hidden when portForward.local === false
 *   C3  Panel visible when portForward.local === true (focusable, menuitem role)
 *   C4  Active forwards render one row each; Remove invokes closeLocalForward
 *   C5  "Add forward" calls openLocalForward(srcPort, dstHost, dstPort);
 *       fwd_local_error keeps the form open with an inline error
 *   C6  SSH reconnect clears forwards and does NOT auto-restore
 *
 * Pre-implementation: forwards.ts module is missing. Tests fail on import
 * or on a missing DOM element (`#sessionForwardsBtn`, `#panel-forwards`,
 * etc.) — acceptable red baseline.
 *
 * Implementation must follow the Terminal submenu pattern at
 * src/modules/ui.ts:895 (sessionTerminalSubmenuBtn / sessionTerminalSubmenu).
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
// JSDOM provides a real Document/Element so .classList / aria-* / focus work
// the way the panel-gating code will use them. vitest's `environment: 'node'`
// would otherwise omit `document` entirely.
import { JSDOM } from 'jsdom';
import type { Capabilities, LocalForward } from '../types.js';

const HTML_PATH = resolve(__dirname, '../../../public/index.html');

function loadIndexHtmlIntoDom(): JSDOM {
  const html = readFileSync(HTML_PATH, 'utf-8');
  return new JSDOM(html, { url: 'http://localhost:8081/' });
}

describe('forwards panel gating (#499)', () => {
  let dom: JSDOM;
  let storage: Map<string, string>;

  beforeEach(() => {
    dom = loadIndexHtmlIntoDom();
    vi.stubGlobal('document', dom.window.document);
    vi.stubGlobal('window', dom.window);

    storage = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => storage.get(k) ?? null,
      setItem: (k: string, v: string) => { storage.set(k, v); },
      removeItem: (k: string) => { storage.delete(k); },
      clear: () => { storage.clear(); },
      length: 0,
      key: () => null,
    });
    vi.stubGlobal('location', dom.window.location);
    vi.stubGlobal('fetch', vi.fn());

    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // ── HTML scaffold ────────────────────────────────────────────────────────
  // The Forwards panel must exist in index.html as a peer of the existing
  // Terminal submenu so the DOM is present before capabilities load. Gating
  // is then done via `.hidden`, not by inserting/removing the markup.

  describe('HTML scaffold', () => {
    const html = readFileSync(HTML_PATH, 'utf-8');

    it('declares a sessionForwardsSubmenuBtn inside #sessionMenu', () => {
      // Mirrors sessionTerminalSubmenuBtn (ui.ts:899). Same role + aria
      // pattern so screen-reader behavior matches the existing submenu.
      expect(html).toContain('sessionForwardsSubmenuBtn');
      expect(html).toMatch(/sessionForwardsSubmenuBtn[^>]*role="menuitem"/);
      expect(html).toMatch(/sessionForwardsSubmenuBtn[^>]*aria-expanded="false"/);
    });

    it('declares a sessionForwardsSubmenu container with .hidden by default', () => {
      // Default-hidden so C1 (capabilities not loaded) holds without JS running.
      expect(html).toContain('sessionForwardsSubmenu');
      expect(html).toMatch(/id="sessionForwardsSubmenu"[^>]*class="[^"]*\bhidden\b/);
    });

    it('Forwards submenu button is hidden by default (#hidden class)', () => {
      // C1 again — the menuitem itself must also start hidden so it doesn't
      // flash on screen during boot before capabilities arrive.
      expect(html).toMatch(/id="sessionForwardsSubmenuBtn"[^>]*class="[^"]*\bhidden\b/);
    });
  });

  // ── Runtime gating ───────────────────────────────────────────────────────

  describe('initForwardsPanel(): gates on capabilities', () => {
    function makeCaps(local: boolean): Capabilities {
      return {
        version: 1,
        bridge: { version: 't', hash: 'h' },
        portForward: { local, remote: false, dynamic: false },
      };
    }

    it('C1: panel stays hidden before capabilities load', async () => {
      const { initForwardsPanel } = await import('../forwards.js');
      initForwardsPanel();
      const btn = document.getElementById('sessionForwardsSubmenuBtn');
      const panel = document.getElementById('sessionForwardsSubmenu');
      expect(btn).not.toBeNull();
      expect(panel).not.toBeNull();
      expect(btn!.classList.contains('hidden')).toBe(true);
      expect(panel!.classList.contains('hidden')).toBe(true);
    });

    it('C2 / A9: panel stays hidden when portForward.local === false', async () => {
      const { initForwardsPanel, applyCapabilities } = await import('../forwards.js');
      initForwardsPanel();
      applyCapabilities(makeCaps(false));
      const btn = document.getElementById('sessionForwardsSubmenuBtn')!;
      expect(btn.classList.contains('hidden')).toBe(true);
    });

    it('C3 / A9: panel becomes visible + focusable when portForward.local === true', async () => {
      const { initForwardsPanel, applyCapabilities } = await import('../forwards.js');
      initForwardsPanel();
      applyCapabilities(makeCaps(true));

      const btn = document.getElementById('sessionForwardsSubmenuBtn')!;
      expect(btn.classList.contains('hidden')).toBe(false);
      expect(btn.getAttribute('role')).toBe('menuitem');
      // Focusable by virtue of being a real <button> with no tabindex=-1
      expect(btn.getAttribute('tabindex')).not.toBe('-1');
    });

    it('A9: state slice mirrors the DOM gating (appState.capabilities.portForward.local)', async () => {
      const { applyCapabilities, getCapabilities } = await import('../forwards.js');
      applyCapabilities(makeCaps(true));
      expect(getCapabilities()?.portForward.local).toBe(true);
      applyCapabilities(makeCaps(false));
      expect(getCapabilities()?.portForward.local).toBe(false);
    });
  });

  // ── Row rendering + actions ──────────────────────────────────────────────

  describe('renderForwards(): rows + add/remove actions', () => {
    function makeForward(id: string, srcPort: number, dstHost: string, dstPort: number): LocalForward {
      return {
        id, srcPort, dstHost, dstPort,
        listenAddr: '127.0.0.1',
        state: 'active',
        openedAt: Date.now(),
      };
    }

    it('C4: two active forwards render as two rows showing srcPort → dstHost:dstPort', async () => {
      const { initForwardsPanel, applyCapabilities, renderForwards } = await import('../forwards.js');
      initForwardsPanel();
      applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });

      renderForwards([
        makeForward('F1', 8080, 'host-a', 80),
        makeForward('F2', 9090, 'host-b', 443),
      ]);

      const panel = document.getElementById('sessionForwardsSubmenu')!;
      const rows = panel.querySelectorAll('[data-forward-id]');
      expect(rows.length).toBe(2);

      // Row text contains "srcPort → dstHost:dstPort"
      expect(panel.textContent).toContain('8080');
      expect(panel.textContent).toContain('host-a:80');
      expect(panel.textContent).toContain('9090');
      expect(panel.textContent).toContain('host-b:443');
    });

    it('C4b: Remove button invokes closeLocalForward with the row id', async () => {
      const mod = await import('../forwards.js');
      const closeSpy = vi.spyOn(mod, 'closeLocalForward').mockImplementation(() => Promise.resolve());

      mod.initForwardsPanel(mod);
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      mod.renderForwards([makeForward('F1', 8080, 'host-a', 80)]);

      const removeBtn = document.querySelector('[data-forward-id="F1"] [data-action="remove-forward"]') as HTMLButtonElement | null;
      expect(removeBtn).not.toBeNull();
      removeBtn!.click();

      expect(closeSpy).toHaveBeenCalledWith('F1');
    });

    it('C5: "Add forward" submission calls openLocalForward(srcPort, dstHost, dstPort)', async () => {
      const mod = await import('../forwards.js');
      const openSpy = vi.spyOn(mod, 'openLocalForward').mockImplementation(() => Promise.resolve({
        id: 'F1', srcPort: 8080, dstHost: 'example', dstPort: 80,
        listenAddr: '127.0.0.1', state: 'active', openedAt: Date.now(),
      }));

      mod.initForwardsPanel(mod);
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });

      const addBtn = document.querySelector('[data-action="add-forward"]') as HTMLButtonElement | null;
      expect(addBtn, 'add-forward control must exist in the panel').not.toBeNull();
      addBtn!.click();

      // Form appears
      const srcPortInput = document.querySelector('[data-add-forward-field="srcPort"]') as HTMLInputElement | null;
      const dstHostInput = document.querySelector('[data-add-forward-field="dstHost"]') as HTMLInputElement | null;
      const dstPortInput = document.querySelector('[data-add-forward-field="dstPort"]') as HTMLInputElement | null;
      const confirmBtn = document.querySelector('[data-action="confirm-add-forward"]') as HTMLButtonElement | null;
      expect(srcPortInput).not.toBeNull();
      expect(dstHostInput).not.toBeNull();
      expect(dstPortInput).not.toBeNull();
      expect(confirmBtn).not.toBeNull();

      srcPortInput!.value = '8080';
      dstHostInput!.value = 'example';
      dstPortInput!.value = '80';
      confirmBtn!.click();

      // openLocalForward is called with parsed numeric ports
      expect(openSpy).toHaveBeenCalledWith(8080, 'example', 80);
    });

    it('C5b: fwd_local_error from openLocalForward keeps form open with inline error', async () => {
      const mod = await import('../forwards.js');
      vi.spyOn(mod, 'openLocalForward').mockImplementation(() =>
        Promise.reject(Object.assign(new Error('bind failed: EADDRINUSE'), { code: 'eaddrinuse' }))
      );

      mod.initForwardsPanel(mod);
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });

      (document.querySelector('[data-action="add-forward"]') as HTMLButtonElement).click();
      (document.querySelector('[data-add-forward-field="srcPort"]') as HTMLInputElement).value = '8080';
      (document.querySelector('[data-add-forward-field="dstHost"]') as HTMLInputElement).value = 'example';
      (document.querySelector('[data-add-forward-field="dstPort"]') as HTMLInputElement).value = '80';
      (document.querySelector('[data-action="confirm-add-forward"]') as HTMLButtonElement).click();

      // Wait for the rejection to flow through
      await new Promise((r) => setTimeout(r, 0));

      // Form is still open
      const form = document.querySelector('[data-add-forward-form]');
      expect(form, 'add-forward form must stay mounted after fwd_local_error').not.toBeNull();
      expect(form!.classList.contains('hidden')).toBe(false);

      // Inline error shown
      const err = document.querySelector('[data-add-forward-error]');
      expect(err).not.toBeNull();
      expect(err!.textContent).toMatch(/eaddrinuse|EADDRINUSE|bind/i);

      // No row appeared
      expect(document.querySelector('[data-forward-id]')).toBeNull();
    });
  });

  // ── Reconnect behaviour ──────────────────────────────────────────────────

  describe('C6: SSH reconnect does NOT auto-restore forwards', () => {
    it('on disconnect: forwards are cleared from appState.forwards', async () => {
      const mod = await import('../forwards.js');
      mod.initForwardsPanel();
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      // Seed one active forward via the public client-side message handler
      mod.handleServerForwardMessage({
        type: 'fwd_local_ready', id: 'F1', srcPort: 8080, listenAddr: '127.0.0.1',
      });

      // Simulate SSH disconnect — the module exports a hook for the
      // connection lifecycle to call when the session leaves 'connected'.
      mod.onSshDisconnected();

      const list = mod.listForwards();
      expect(list.length).toBe(0);
    });

    it('after reconnect: panel is empty (no auto-restore)', async () => {
      const mod = await import('../forwards.js');
      mod.initForwardsPanel();
      mod.applyCapabilities({
        version: 1, bridge: { version: 't', hash: 'h' },
        portForward: { local: true, remote: false, dynamic: false },
      });
      mod.handleServerForwardMessage({
        type: 'fwd_local_ready', id: 'F1', srcPort: 8080, listenAddr: '127.0.0.1',
      });
      mod.onSshDisconnected();
      mod.onSshReconnected();

      // No fwd_local_listen replays after reconnect
      expect(mod.listForwards().length).toBe(0);
      const rows = document.querySelectorAll('[data-forward-id]');
      expect(rows.length).toBe(0);
    });
  });
});
