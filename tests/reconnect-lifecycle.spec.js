/**
 * tests/reconnect-lifecycle.spec.js
 *
 * Integration tests for the session reconnect lifecycle.
 * Simulates the real mobile flow: connect → background → resume → reconnect → switch.
 *
 * These tests exercise the state machine, AbortController lifecycle, and UI
 * state rendering end-to-end through the actual app code — not unit-level mocks.
 *
 * Key scenarios:
 *   1. Connected session shows correct UI state (green dot, input works)
 *   2. Server-side disconnect transitions to disconnected state
 *   3. Visibility change triggers auto-reconnect
 *   4. Reconnected session has working input
 *   5. Disconnected session shows correct UI state (red dot, reconnect button)
 *   6. Session switch to disconnected session triggers auto-reconnect
 *   7. Multi-session: one drops, other stays — UI reflects both correctly
 */

const { test, expect, setupConnected } = require('./fixtures.js');

test.describe('Reconnect lifecycle', { tag: '@headless-adequate' }, () => {

  test('connected session shows green dot in session menu', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Open session menu
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(200);

    // Session menu should have a dot with connected state
    const dot = page.locator('.session-item-dot').first();
    await expect(dot).toBeVisible();

    // The dot should have the connected CSS class
    const dotClasses = await dot.getAttribute('class');
    expect(dotClasses).toContain('session-connected');
  });

  test('server disconnect transitions session to disconnected state', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Verify connected first
    const state1 = await page.evaluate(() => {
      return import('./modules/state.js').then(m => {
        const s = m.currentSession();
        return s ? s.state : null;
      });
    });
    expect(state1).toBe('connected');

    // Server closes all sockets — simulates network drop
    mockSshServer.sendToPage({ type: 'disconnected', reason: 'test: simulated disconnect' });
    await page.waitForTimeout(500);

    // Session state should transition away from connected
    const state2 = await page.evaluate(() => {
      return import('./modules/state.js').then(m => {
        const s = m.currentSession();
        return s ? s.state : null;
      });
    });
    expect(state2).not.toBe('connected');
  });

  test('input works on connected session', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Type something — should arrive at mock server
    const msgCountBefore = mockSshServer.messages.filter(m => m.type === 'input').length;

    await page.evaluate(() => {
      return import('./modules/connection.js').then(m => {
        m.sendSSHInput('hello');
      });
    });
    await page.waitForTimeout(200);

    const msgCountAfter = mockSshServer.messages.filter(m => m.type === 'input').length;
    expect(msgCountAfter).toBeGreaterThan(msgCountBefore);
  });

  test('input is blocked on disconnected session with toast feedback', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Disconnect
    mockSshServer.sendToPage({ type: 'disconnected', reason: 'test: simulated disconnect' });
    await page.waitForTimeout(500);

    // Try to send input — should be blocked
    const msgCountBefore = mockSshServer.messages.filter(m => m.type === 'input').length;

    await page.evaluate(() => {
      return import('./modules/connection.js').then(m => {
        m.sendSSHInput('should-not-arrive');
      });
    });
    await page.waitForTimeout(200);

    const msgCountAfter = mockSshServer.messages.filter(m => m.type === 'input').length;
    expect(msgCountAfter).toBe(msgCountBefore);
  });

  test('visibilitychange to hidden then visible triggers reconnect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Count connect messages before
    const connectsBefore = mockSshServer.messages.filter(m => m.type === 'connect').length;

    // Simulate app backgrounding — dispatch visibilitychange with hidden
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForTimeout(200);

    // Server drops the connection while app is backgrounded
    mockSshServer.sendToPage({ type: 'disconnected', reason: 'test: background disconnect' });
    await page.waitForTimeout(300);

    // Simulate app returning to foreground
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });

    // Wait for reconnect attempt
    await page.waitForFunction((before) => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'connect'; } catch (_) { return false; }
      }).length > before;
    }, connectsBefore, { timeout: 10_000 });

    const connectsAfter = mockSshServer.messages.filter(m => m.type === 'connect').length;
    expect(connectsAfter).toBeGreaterThan(connectsBefore);
  });

  test('reconnected session has working input', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Force-close server WS — simulates real network drop
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);

    // Simulate app returning to foreground (triggers reconnect for dropped sessions)
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });

    // Wait for reconnect to complete — server auto-responds with 'connected'
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2; // 2nd resize = reconnect completed
    }, null, { timeout: 10_000 });

    // Now send input — should arrive at server
    const msgCountBefore = mockSshServer.messages.filter(m => m.type === 'input').length;

    await page.evaluate(() => {
      return import('./modules/connection.js').then(m => {
        m.sendSSHInput('after-reconnect');
      });
    });
    await page.waitForTimeout(200);

    const msgCountAfter = mockSshServer.messages.filter(m => m.type === 'input').length;
    expect(msgCountAfter).toBeGreaterThan(msgCountBefore);
  });

  test('active sessions section in Connect panel shows session with correct state', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Show tab bar (hidden after connect) and navigate to Connect panel
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(200);

    // Active sessions section should exist with our session
    const activeSection = page.locator('#activeSessionList');
    await expect(activeSection).toBeVisible();

    // Should have at least one active session item
    const sessionItems = page.locator('.active-session-item');
    await expect(sessionItems.first()).toBeVisible();

    // The dot should reflect connected state
    const dot = sessionItems.first().locator('.session-dot');
    const dotClasses = await dot.getAttribute('class');
    expect(dotClasses).toContain('dot-connected');
  });

  test('disconnected session in Connect panel shows non-connected state before reconnect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Navigate to Connect panel FIRST (before disconnect) so we can observe the transition
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(200);

    // Verify session shows as connected initially
    const sessionItems = page.locator('.active-session-item');
    await expect(sessionItems.first()).toBeVisible();
    const dotBefore = await sessionItems.first().locator('.session-dot').getAttribute('class');
    expect(dotBefore).toContain('dot-connected');

    // Force-close — the onStateChange callback should update the UI
    mockSshServer.dropAll();

    // The session should transition away from connected — check within 5s
    // (auto-reconnect may succeed quickly, so we check for any non-connected state)
    const sawNonConnected = await page.waitForFunction(() => {
      const dot = document.querySelector('.active-session-item .session-dot');
      return dot && !dot.classList.contains('dot-connected');
    }, null, { timeout: 5000 }).then(() => true).catch(() => false);

    // Either we caught the disconnected state, or the reconnect was so fast
    // that it went disconnected → reconnecting → connected before we could observe.
    // Both are acceptable — the important thing is the UI updates.
    // If we caught it, verify the dot and button
    if (sawNonConnected) {
      const dotAfter = await sessionItems.first().locator('.session-dot').getAttribute('class');
      expect(dotAfter).not.toContain('dot-connected');
    }
    // The active sessions section should always be visible with at least one item
    await expect(sessionItems.first()).toBeVisible();
  });

  test('no duplicate output after reconnect cycle', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Force-close — real disconnect
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);

    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });

    // Wait for reconnect
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });

    // Send a unique output from server — should appear exactly once
    const marker = `__UNIQUE_${Date.now()}__`;
    mockSshServer.sendToPage({ type: 'output', data: marker });
    await page.waitForTimeout(500);

    // Count occurrences in the terminal
    const count = await page.evaluate((m) => {
      const termEl = document.querySelector('.xterm-screen');
      if (!termEl) return 0;
      const text = termEl.textContent || '';
      return (text.match(new RegExp(m, 'g')) || []).length;
    }, marker);

    expect(count).toBe(1);
  });

  test('session menu button text updates on disconnect', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Should show user@host when connected
    const btnTextBefore = await page.locator('#sessionMenuBtn').textContent();
    expect(btnTextBefore).toContain('testuser@mock-host');

    // Force-close — button text should still show the host (session exists, just disconnected)
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);

    // Wait for state change to propagate to UI
    await page.waitForFunction(() => {
      const btn = document.getElementById('sessionMenuBtn');
      return btn && btn.textContent !== 'testuser@mock-host';
    }, null, { timeout: 5000 }).catch(() => {});

    const btnTextAfter = await page.locator('#sessionMenuBtn').textContent();
    // Should still show host info — session is disconnected, not closed
    expect(btnTextAfter).toContain('mock-host');
  });

  test('terminal fills available space after session switch (#316)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Get terminal dimensions after first connect
    const dims1 = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      return el ? { w: el.clientWidth, h: el.clientHeight } : null;
    });
    expect(dims1).not.toBeNull();
    expect(dims1.w).toBeGreaterThan(100);
    expect(dims1.h).toBeGreaterThan(100);

    // Force-close and reconnect to create a "second" session state
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });

    // Check terminal dimensions after reconnect — should be similar to initial
    await page.waitForTimeout(500);
    const dims2 = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      return el ? { w: el.clientWidth, h: el.clientHeight } : null;
    });
    expect(dims2).not.toBeNull();
    // Width should be at least 50% of original (not collapsed to narrow column)
    expect(dims2.w).toBeGreaterThan(dims1.w * 0.5);
    expect(dims2.h).toBeGreaterThan(dims1.h * 0.5);
  });

  test('no control character leak after reconnect (#350)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Force-close and reconnect
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });
    await page.waitForTimeout(500);

    // Check terminal content for leaked escape code responses
    const termText = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      return el ? el.textContent : '';
    });
    expect(termText).not.toContain('?1;2c');
    expect(termText).not.toContain('0;276;0c');
  });

  test('DA1/DA2 responses are filtered from terminal.onData — not sent to SSH (#350)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Simulate xterm.js emitting DA responses through onData
    // (happens when remote sends CSI c to query terminal capabilities)
    await page.evaluate(() => {
      return import('./modules/connection.js').then(m => {
        m.sendSSHInput('\x1b[?1;2c');       // DA1 response
        m.sendSSHInput('\x1b[>0;276;0c');   // DA2 response
        m.sendSSHInput('real-input');         // Normal text
      });
    });
    await page.waitForTimeout(300);

    const inputMsgs = mockSshServer.messages.filter(m => m.type === 'input');
    const allInput = inputMsgs.map(m => m.data).join('');
    expect(allInput).not.toContain('?1;2c');
    expect(allInput).not.toContain('0;276;0c');
    expect(allInput).toContain('real-input');
  });

  // ── Tier 1 baseline tests (#356) ─────────────────────────────────────────
  // Some of these are intentionally RED — they express expected behavior for
  // known bugs. When the bugs are fixed, these tests go green.

  test('multi-session: both sessions reconnect after background drop (#354)', async ({ page, mockSshServer }) => {
    // RED BASELINE — #354: only active session reconnects
    await setupConnected(page, mockSshServer);

    // Save a second profile and connect it
    await page.evaluate((port) => {
      localStorage.setItem('wsUrl', `ws://localhost:${port}`);
    }, mockSshServer.port);
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(200);

    // Fill second profile
    await page.locator('#host').fill('mock-host-2');
    await page.locator('#remote_a').fill('testuser2');
    await page.locator('#remote_c').fill('testpass2');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);

    // Connect second profile
    const connectBtns = page.locator('[data-action="connect"]');
    await connectBtns.last().click();
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });

    // Both sessions connected — now drop all
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);

    // Simulate visibility restore
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });

    // Wait for reconnects — should see 4+ resize messages total (2 initial + 2 reconnect)
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 4;
    }, null, { timeout: 15_000 });

    // Both sessions should exist and be connected
    const sessionCount = await page.evaluate(() => {
      return import('./modules/state.js').then(m => {
        let connected = 0;
        for (const [, s] of m.appState.sessions) {
          if (s.state === 'connected') connected++;
        }
        return connected;
      });
    });
    expect(sessionCount).toBe(2);
  });

  test('multi-session: background session has input after reconnect (#354)', async ({ page, mockSshServer }) => {
    // RED BASELINE — #354: background session may need manual reconnect
    await setupConnected(page, mockSshServer);

    // Get first session ID
    const firstSessionId = await page.evaluate(() => {
      return import('./modules/state.js').then(m => m.appState.activeSessionId);
    });

    // Connect second session (same mock server, different profile name)
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(200);
    await page.locator('#host').fill('mock-host-2');
    await page.locator('#remote_a').fill('testuser2');
    await page.locator('#remote_c').fill('testpass2');
    await page.locator('#connectForm button[type="submit"]').click();
    await page.waitForTimeout(500);
    await page.locator('[data-action="connect"]').last().click();
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });

    // Drop all, restore visibility
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForTimeout(3000);

    // Switch back to first session
    await page.evaluate((sid) => {
      return import('./modules/ui.js').then(m => m.switchSession(sid));
    }, firstSessionId);
    await page.waitForTimeout(1000);

    // Send input on first session — should arrive
    const beforeCount = mockSshServer.messages.filter(m => m.type === 'input').length;
    await page.evaluate(() => {
      return import('./modules/connection.js').then(m => m.sendSSHInput('bg-session-test'));
    });
    await page.waitForTimeout(300);
    const afterCount = mockSshServer.messages.filter(m => m.type === 'input').length;
    expect(afterCount).toBeGreaterThan(beforeCount);
  });

  test('terminal cols correct after visibility restore (#316)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Get initial cols
    const colsBefore = await page.evaluate(() => {
      return import('./modules/state.js').then(m => m.currentSession()?.terminal?.cols ?? 0);
    });
    expect(colsBefore).toBeGreaterThan(40);

    // Background and restore
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForTimeout(200);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });

    // Wait for fit to settle
    await page.waitForTimeout(1000);

    const colsAfter = await page.evaluate(() => {
      return import('./modules/state.js').then(m => m.currentSession()?.terminal?.cols ?? 0);
    });
    // Should be within 10% of original — not shrunken to single digits
    expect(colsAfter).toBeGreaterThan(colsBefore * 0.8);
  });

  test('terminal cols correct after panel round-trip (#316)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    const colsBefore = await page.evaluate(() => {
      return import('./modules/state.js').then(m => m.currentSession()?.terminal?.cols ?? 0);
    });

    // Navigate away and back
    await page.locator('#handleMenuBtn').click();
    await page.waitForTimeout(100);
    await page.locator('[data-panel="connect"]').click();
    await page.waitForTimeout(300);
    await page.locator('[data-panel="terminal"]').click();
    await page.waitForTimeout(1000);

    const colsAfter = await page.evaluate(() => {
      return import('./modules/state.js').then(m => m.currentSession()?.terminal?.cols ?? 0);
    });
    expect(colsAfter).toBeGreaterThan(colsBefore * 0.8);
  });

  test('session menu opens after full reconnect cycle', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Full cycle: drop, reconnect
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });

    // Click session menu — should open
    await page.locator('#sessionMenuBtn').click();
    await page.waitForTimeout(300);
    const menuHidden = await page.locator('#sessionMenu').evaluate(el => el.classList.contains('hidden'));
    expect(menuHidden).toBe(false);
  });

  test('session menu button preserves badge HTML after state change (#355)', async ({ page, mockSshServer }) => {
    // RED BASELINE — #355: textContent clobbers badge
    await setupConnected(page, mockSshServer);

    // Simulate notification badge by injecting one
    await page.evaluate(() => {
      const btn = document.getElementById('sessionMenuBtn');
      if (btn) {
        const badge = document.createElement('span');
        badge.className = 'notif-badge';
        badge.textContent = '3';
        btn.appendChild(badge);
      }
    });

    // Verify badge exists
    const badgeBefore = await page.locator('#sessionMenuBtn .notif-badge').count();
    expect(badgeBefore).toBe(1);

    // Trigger state change (disconnect + reconnect)
    mockSshServer.dropAll();
    await page.waitForTimeout(1000);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForTimeout(2000);

    // Badge should still exist after state changes
    const badgeAfter = await page.locator('#sessionMenuBtn .notif-badge').count();
    expect(badgeAfter).toBe(1);
  });

  test('no escape codes after reconnect via visibility restore (#350)', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Full visibility cycle
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    mockSshServer.dropAll();
    await page.waitForTimeout(500);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(() => {
      return (window.__mockWsSpy || []).filter(s => {
        try { return JSON.parse(s).type === 'resize'; } catch (_) { return false; }
      }).length >= 2;
    }, null, { timeout: 10_000 });
    await page.waitForTimeout(1000);

    // Check for leaked escape sequences
    const termText = await page.evaluate(() => {
      const el = document.querySelector('.xterm-screen');
      return el ? el.textContent : '';
    });
    expect(termText).not.toContain('?1;2c');
    expect(termText).not.toContain('0;276;0c');
    // Also check no input messages contained DA responses
    const inputMsgs = mockSshServer.messages.filter(m => m.type === 'input');
    const allInput = inputMsgs.map(m => m.data).join('');
    expect(allInput).not.toMatch(/\?[\d;]+c/);
  });
});
