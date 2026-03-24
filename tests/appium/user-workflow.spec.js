/**
 * tests/appium/user-workflow.spec.js
 *
 * End-to-end user workflow test: walks through every UI view and gesture
 * as a real user would. Validates the full app experience from cold start
 * through SSH session with gesture interaction.
 *
 * NOT a frozen baseline — this is an active workflow test.
 *
 * Test matrix:
 *   1. Cold start: vault setup modal + tab navigation to all 4 panels
 *   2. Connect panel: form fields, auth type toggle, profile management
 *   3. SSH connection: host key dialog, terminal readiness, connected state
 *   4. Terminal chrome: session menu exploration, font adjust, theme cycle
 *   5. Key bar: special keys present, compose mode toggle, chevron toggle
 *   6. Settings panel: every section and toggle verified
 *   7. Keys panel: import form, empty state
 *   8. Full session with gestures: scroll + horizontal swipe + pinch
 *
 * Requires: Android emulator, Appium server, Docker test-sshd, MobiSSH server.
 */

const { execSync } = require('child_process');
const path = require('path');
const {
  test, expect,
  swipeToOlderContent, warmupSwipes,
  setupRealSSHConnection, setupVault, sendCommand,
  dismissKeyboardViaBack, exposeTerminal,
  getVisibleTerminalBounds, appiumSwipe,
  readScreen, attachScreenshot,
  switchToNative, switchToWebview,
  dismissNativeDialogs,
  BASE_URL,
} = require('./fixtures');

const FILL_SCRIPT = path.join(__dirname, '../emulator/fill-scrollback.sh');

function ensureScript() {
  execSync(
    `docker compose -f docker-compose.test.yml cp "${FILL_SCRIPT}" test-sshd:/tmp/fill-scrollback.sh`,
    { timeout: 10000 }
  );
}

function dockerExec(cmd) {
  execSync(
    `docker compose -f docker-compose.test.yml exec -T test-sshd ${cmd}`,
    { timeout: 15000, encoding: 'utf8' }
  );
}

async function getWsInputMessages(driver) {
  return driver.executeScript(`
    return (window.__mockWsSpy || [])
      .map(s => { try { return JSON.parse(s); } catch { return null; } })
      .filter(m => m && m.type === 'input');
  `, []);
}

async function performPinch(driver, centerX, centerY, startGap, endGap) {
  const steps = 10;
  const halfStart = Math.round(startGap / 2);
  const halfEnd = Math.round(endGap / 2);

  const finger1Actions = [
    { type: 'pointerMove', duration: 0, x: centerX - halfStart, y: centerY, origin: 'viewport' },
    { type: 'pointerDown', button: 0 },
    { type: 'pause', duration: 100 },
  ];
  const finger2Actions = [
    { type: 'pointerMove', duration: 0, x: centerX + halfStart, y: centerY, origin: 'viewport' },
    { type: 'pointerDown', button: 0 },
    { type: 'pause', duration: 100 },
  ];

  for (let i = 1; i <= steps; i++) {
    const f = i / steps;
    const offset = Math.round(halfStart + (halfEnd - halfStart) * f);
    finger1Actions.push({
      type: 'pointerMove', duration: 50,
      x: centerX - offset, y: centerY, origin: 'viewport',
    });
    finger2Actions.push({
      type: 'pointerMove', duration: 50,
      x: centerX + offset, y: centerY, origin: 'viewport',
    });
  }

  finger1Actions.push({ type: 'pointerUp', button: 0 });
  finger2Actions.push({ type: 'pointerUp', button: 0 });

  await switchToNative(driver);
  await driver.performActions([
    { type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' }, actions: finger1Actions },
    { type: 'pointer', id: 'finger2', parameters: { pointerType: 'touch' }, actions: finger2Actions },
  ]);
  await driver.releaseActions();
  await switchToWebview(driver);
  await driver.pause(1000);
}

async function getFontSize(driver) {
  return driver.executeScript(
    'return window.__testTerminal?.options.fontSize ?? 14', []);
}

/** Click a tab and verify the expected panel becomes active. */
async function navigateToPanel(driver, panelName) {
  await driver.executeScript(
    `document.querySelector('[data-panel="${panelName}"]')?.click()`, []);
  await driver.pause(500);
  const isActive = await driver.executeScript(`
    const panel = document.getElementById('panel-${panelName}');
    return panel && panel.classList.contains('active');
  `, []);
  return isActive;
}

test.describe('User workflow (Appium)', () => {
  test.setTimeout(180_000);

  test.beforeEach(async ({ driver }) => {
    await driver.executeScript('localStorage.clear()', []);
    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);
  });

  test('cold start: vault setup and panel navigation', async ({ driver }, testInfo) => {
    // On cold start with no localStorage, vault setup modal should appear
    const vaultModalVisible = await driver.executeScript(`
      const overlay = document.getElementById('vaultSetupOverlay');
      return overlay && !overlay.classList.contains('hidden');
    `, []);
    expect(vaultModalVisible).toBe(true);
    await attachScreenshot(driver, testInfo, 'vault-setup-modal');

    // Verify vault modal elements
    const hasPasswordField = await driver.executeScript(
      "return !!document.getElementById('vaultNewPw')", []);
    const hasConfirmField = await driver.executeScript(
      "return !!document.getElementById('vaultConfirmPw')", []);
    const hasCreateBtn = await driver.executeScript(
      "return !!document.getElementById('vaultSetupCreate')", []);
    expect(hasPasswordField).toBe(true);
    expect(hasConfirmField).toBe(true);
    expect(hasCreateBtn).toBe(true);

    // Create vault
    await setupVault(driver);

    // Vault modal should be dismissed
    const vaultDismissed = await driver.executeScript(`
      const overlay = document.getElementById('vaultSetupOverlay');
      return !overlay || overlay.classList.contains('hidden');
    `, []);
    expect(vaultDismissed).toBe(true);

    // Tab bar should be visible with 5 tabs
    const tabCount = await driver.executeScript(
      "return document.querySelectorAll('#tabBar .tab').length", []);
    expect(tabCount).toBe(5);

    // Navigate to each panel and verify it activates
    for (const panel of ['files', 'terminal', 'connect', 'keys', 'settings']) {
      const isActive = await navigateToPanel(driver, panel);
      expect(isActive).toBe(true);
    }
    await attachScreenshot(driver, testInfo, 'settings-panel-visible');

    // Navigate back to terminal
    const terminalActive = await navigateToPanel(driver, 'terminal');
    expect(terminalActive).toBe(true);
  });

  test('connect panel: form fields and auth type toggle', async ({ driver }, testInfo) => {
    await setupVault(driver);
    await navigateToPanel(driver, 'connect');
    await attachScreenshot(driver, testInfo, 'connect-panel');

    // Verify all form fields exist
    const formFields = await driver.executeScript(`
      return {
        profileName: !!document.getElementById('profileName'),
        host: !!document.getElementById('host'),
        port: !!document.getElementById('port'),
        username: !!document.getElementById('remote_a'),
        authType: !!document.getElementById('authType'),
        password: !!document.getElementById('remote_c'),
        initialCommand: !!document.getElementById('initialCommand'),
        submitBtn: !!document.querySelector('#connectForm button[type="submit"]'),
      };
    `, []);
    expect(formFields.profileName).toBe(true);
    expect(formFields.host).toBe(true);
    expect(formFields.port).toBe(true);
    expect(formFields.username).toBe(true);
    expect(formFields.authType).toBe(true);
    expect(formFields.password).toBe(true);
    expect(formFields.initialCommand).toBe(true);
    expect(formFields.submitBtn).toBe(true);

    // Password group visible by default, key group hidden (via .hidden class)
    const passwordVisible = await driver.executeScript(`
      const pg = document.getElementById('passwordGroup');
      return pg && !pg.classList.contains('hidden');
    `, []);
    expect(passwordVisible).toBe(true);

    const keyHidden = await driver.executeScript(`
      const kg = document.getElementById('keyGroup');
      return kg && kg.classList.contains('hidden');
    `, []);
    expect(keyHidden).toBe(true);

    // Switch auth type to "key"
    await driver.executeScript(`
      const sel = document.getElementById('authType');
      if (sel) {
        sel.value = 'key';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      }
    `, []);
    await driver.pause(500);

    // Key group should now be visible
    const keyVisible = await driver.executeScript(`
      const kg = document.getElementById('keyGroup');
      return kg && !kg.classList.contains('hidden');
    `, []);
    expect(keyVisible).toBe(true);

    // Verify key group fields
    const keyFields = await driver.executeScript(`
      return {
        privateKey: !!document.getElementById('privateKey'),
        passphrase: !!document.getElementById('remote_pp'),
      };
    `, []);
    expect(keyFields.privateKey).toBe(true);
    expect(keyFields.passphrase).toBe(true);
    await attachScreenshot(driver, testInfo, 'connect-key-auth');

    // Switch back to password
    await driver.executeScript(`
      const sel = document.getElementById('authType');
      if (sel) {
        sel.value = 'password';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      }
    `, []);
    await driver.pause(300);

    // Verify profile list area exists (empty state)
    const profileListExists = await driver.executeScript(
      "return !!document.getElementById('profileList')", []);
    expect(profileListExists).toBe(true);
  });

  test('SSH connection: host key dialog and terminal readiness', async ({ driver }, testInfo) => {
    await setupVault(driver);

    // setupRealSSHConnection navigates to connect panel, fills form, connects,
    // then switches to terminal panel and waits for .xterm-screen
    await setupRealSSHConnection(driver);
    await attachScreenshot(driver, testInfo, 'ssh-connected');

    // Terminal should be active panel
    const terminalActive = await driver.executeScript(`
      const panel = document.getElementById('panel-terminal');
      return panel && panel.classList.contains('active');
    `, []);
    expect(terminalActive).toBe(true);

    // xterm screen should exist
    const xtermExists = await driver.executeScript(
      "return !!document.querySelector('.xterm-screen')", []);
    expect(xtermExists).toBe(true);

    // Session menu button should show connected state (user@host text)
    const sessionBtnText = await driver.executeScript(
      "return document.getElementById('sessionMenuBtn')?.textContent || ''", []);
    expect(sessionBtnText).not.toBe('MobiSSH');
    expect(sessionBtnText.length).toBeGreaterThan(0);

    // WS spy should have captured a resize message (proves SSH connected)
    const hasResize = await driver.executeScript(`
      return (window.__mockWsSpy || []).some(s => {
        try { return JSON.parse(s).type === 'resize'; } catch { return false; }
      });
    `, []);
    expect(hasResize).toBe(true);

    // Verify we can send a command and get output
    await exposeTerminal(driver);
    await sendCommand(driver, 'echo WORKFLOW_TEST_OK');
    await driver.pause(3000);

    // Try both viewport and base reads since terminal buffer position varies
    const screenContent = await readScreen(driver, true);
    const screenContentAlt = await readScreen(driver, false);
    const combined = screenContent + '\n' + screenContentAlt;
    expect(combined).toContain('WORKFLOW_TEST_OK');
    await attachScreenshot(driver, testInfo, 'ssh-command-output');
  });

  test('terminal chrome: session menu and font adjustment', async ({ driver }, testInfo) => {
    await setupVault(driver);
    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Session menu should be hidden initially
    const menuHidden = await driver.executeScript(`
      const menu = document.getElementById('sessionMenu');
      return menu && menu.classList.contains('hidden');
    `, []);
    expect(menuHidden).toBe(true);

    // Open session menu by clicking the session button
    await driver.executeScript(
      "document.getElementById('sessionMenuBtn')?.click()", []);
    await driver.pause(500);

    const menuVisible = await driver.executeScript(`
      const menu = document.getElementById('sessionMenu');
      return menu && !menu.classList.contains('hidden');
    `, []);
    expect(menuVisible).toBe(true);
    await attachScreenshot(driver, testInfo, 'session-menu-open');

    // Verify all session menu items exist
    const menuItems = await driver.executeScript(`
      return {
        fontDec: !!document.getElementById('fontDecBtn'),
        fontInc: !!document.getElementById('fontIncBtn'),
        fontLabel: !!document.getElementById('fontSizeLabel'),
        reset: !!document.getElementById('sessionResetBtn'),
        clear: !!document.getElementById('sessionClearBtn'),
        theme: !!document.getElementById('sessionThemeBtn'),
        reconnect: !!document.getElementById('sessionReconnectBtn'),
        navBar: !!document.getElementById('sessionNavBarBtn'),
        disconnect: !!document.getElementById('sessionDisconnectBtn'),
      };
    `, []);
    expect(menuItems.fontDec).toBe(true);
    expect(menuItems.fontInc).toBe(true);
    expect(menuItems.fontLabel).toBe(true);
    expect(menuItems.reset).toBe(true);
    expect(menuItems.clear).toBe(true);
    expect(menuItems.theme).toBe(true);
    expect(menuItems.reconnect).toBe(true);
    expect(menuItems.navBar).toBe(true);
    expect(menuItems.disconnect).toBe(true);

    // Test font increase
    const fontBefore = await getFontSize(driver);
    await driver.executeScript(
      "document.getElementById('fontIncBtn')?.click()", []);
    await driver.pause(300);
    const fontAfterInc = await getFontSize(driver);
    expect(fontAfterInc).toBeGreaterThan(fontBefore);

    // Test font decrease
    await driver.executeScript(
      "document.getElementById('fontDecBtn')?.click()", []);
    await driver.pause(300);
    const fontAfterDec = await getFontSize(driver);
    expect(fontAfterDec).toBeLessThan(fontAfterInc);

    // Read font size label
    const labelText = await driver.executeScript(
      "return document.getElementById('fontSizeLabel')?.textContent || ''", []);
    expect(labelText).toMatch(/\d+px/);

    // Test theme cycle
    const themeBefore = await driver.executeScript(
      "return document.getElementById('sessionThemeBtn')?.textContent || ''", []);
    await driver.executeScript(
      "document.getElementById('sessionThemeBtn')?.click()", []);
    await driver.pause(300);
    const themeAfter = await driver.executeScript(
      "return document.getElementById('sessionThemeBtn')?.textContent || ''", []);
    expect(themeAfter).not.toBe(themeBefore);
    await attachScreenshot(driver, testInfo, 'theme-changed');

    // Close menu via backdrop
    await driver.executeScript(
      "document.getElementById('menuBackdrop')?.click()", []);
    await driver.pause(300);
    const menuClosedAgain = await driver.executeScript(`
      const menu = document.getElementById('sessionMenu');
      return menu && menu.classList.contains('hidden');
    `, []);
    expect(menuClosedAgain).toBe(true);
  });

  test('terminal chrome: key bar and compose mode', async ({ driver }, testInfo) => {
    await setupVault(driver);
    await navigateToPanel(driver, 'terminal');
    await attachScreenshot(driver, testInfo, 'terminal-with-keybar');

    // Key bar should exist with expected buttons (depth-1 row IDs use M suffix)
    const keyBarElements = await driver.executeScript(`
      return {
        keyBar: !!document.getElementById('key-bar'),
        esc: !!document.getElementById('keyEscM2'),
        ctrl: !!document.getElementById('keyCtrl'),
        tab: !!document.getElementById('keyTab'),
        slash: !!document.getElementById('keySlash'),
        pipe: !!document.getElementById('keyPipe'),
        dash: !!document.getElementById('keyDash'),
        up: !!document.getElementById('keyUpM'),
        down: !!document.getElementById('keyDownM'),
        left: !!document.getElementById('keyLeftM'),
        right: !!document.getElementById('keyRightM'),
        home: !!document.getElementById('keyHomeM'),
        end: !!document.getElementById('keyEndM'),
        pgUp: !!document.getElementById('keyPgUpM'),
        pgDn: !!document.getElementById('keyPgDnM'),
        composeBtn: !!document.getElementById('composeModeBtn'),
      };
    `, []);
    expect(keyBarElements.keyBar).toBe(true);
    expect(keyBarElements.esc).toBe(true);
    expect(keyBarElements.ctrl).toBe(true);
    expect(keyBarElements.tab).toBe(true);
    expect(keyBarElements.slash).toBe(true);
    expect(keyBarElements.pipe).toBe(true);
    expect(keyBarElements.dash).toBe(true);
    expect(keyBarElements.up).toBe(true);
    expect(keyBarElements.down).toBe(true);
    expect(keyBarElements.left).toBe(true);
    expect(keyBarElements.right).toBe(true);
    expect(keyBarElements.home).toBe(true);
    expect(keyBarElements.end).toBe(true);
    expect(keyBarElements.pgUp).toBe(true);
    expect(keyBarElements.pgDn).toBe(true);
    expect(keyBarElements.composeBtn).toBe(true);

    // Compose mode toggle: clicking should toggle the class
    const composeBefore = await driver.executeScript(`
      return document.getElementById('composeModeBtn')?.classList.contains('compose-active') || false;
    `, []);
    await driver.executeScript(
      "document.getElementById('composeModeBtn')?.click()", []);
    await driver.pause(300);
    const composeAfter = await driver.executeScript(`
      return document.getElementById('composeModeBtn')?.classList.contains('compose-active') || false;
    `, []);
    expect(composeAfter).not.toBe(composeBefore);

    // Toggle back
    await driver.executeScript(
      "document.getElementById('composeModeBtn')?.click()", []);
    await driver.pause(300);
    const composeReverted = await driver.executeScript(`
      return document.getElementById('composeModeBtn')?.classList.contains('compose-active') || false;
    `, []);
    expect(composeReverted).toBe(composeBefore);

    // Key bar should be visible
    const keyBarVisible = await driver.executeScript(`
      const kb = document.getElementById('key-bar');
      return kb && !kb.classList.contains('hidden');
    `, []);
    expect(keyBarVisible).toBe(true);
  });

  test('settings panel: all sections and toggles', async ({ driver }, testInfo) => {
    await setupVault(driver);
    await navigateToPanel(driver, 'settings');
    await attachScreenshot(driver, testInfo, 'settings-full');

    // WebSocket URL section
    const wsElements = await driver.executeScript(`
      return {
        wsUrl: !!document.getElementById('wsUrl'),
        saveBtn: !!document.getElementById('saveSettingsBtn'),
        warnInsecure: !!document.getElementById('wsWarnInsecure'),
        warnHostMismatch: !!document.getElementById('wsWarnHostMismatch'),
      };
    `, []);
    expect(wsElements.wsUrl).toBe(true);
    expect(wsElements.saveBtn).toBe(true);
    expect(wsElements.warnInsecure).toBe(true);
    expect(wsElements.warnHostMismatch).toBe(true);

    // Font size slider
    const fontSlider = await driver.executeScript(`
      const slider = document.getElementById('fontSize');
      const label = document.getElementById('fontSizeValue');
      return {
        exists: !!slider,
        min: slider?.min,
        max: slider?.max,
        value: slider?.value,
        label: label?.textContent,
      };
    `, []);
    expect(fontSlider.exists).toBe(true);
    expect(fontSlider.min).toBe('8');
    expect(fontSlider.max).toBe('32');
    expect(fontSlider.label).toMatch(/\d+px/);

    // Theme select
    const themeSelect = await driver.executeScript(`
      const sel = document.getElementById('termThemeSelect');
      if (!sel) return null;
      return {
        exists: true,
        optionCount: sel.options.length,
        options: Array.from(sel.options).map(o => o.value),
      };
    `, []);
    expect(themeSelect).not.toBeNull();
    expect(themeSelect.optionCount).toBe(10);
    expect(themeSelect.options).toContain('dark');
    expect(themeSelect.options).toContain('light');
    expect(themeSelect.options).toContain('highContrast');
    expect(themeSelect.options).toContain('dracula');
    expect(themeSelect.options).toContain('nord');

    // Font select
    const fontSelect = await driver.executeScript(`
      const sel = document.getElementById('termFontSelect');
      if (!sel) return null;
      return {
        exists: true,
        optionCount: sel.options.length,
        options: Array.from(sel.options).map(o => o.value),
      };
    `, []);
    expect(fontSelect).not.toBeNull();
    expect(fontSelect.optionCount).toBe(3);
    expect(fontSelect.options).toContain('monospace');

    // Key bar dock setting
    const dockLeft = await driver.executeScript(
      "return !!document.getElementById('keyControlsDockLeft')", []);
    expect(dockLeft).toBe(true);

    // Gesture toggles
    const gestureToggles = await driver.executeScript(`
      return {
        naturalVertical: !!document.getElementById('naturalVerticalScroll'),
        naturalHorizontal: !!document.getElementById('naturalHorizontalScroll'),
        pinchZoom: !!document.getElementById('enablePinchZoom'),
      };
    `, []);
    expect(gestureToggles.naturalVertical).toBe(true);
    expect(gestureToggles.naturalHorizontal).toBe(true);
    expect(gestureToggles.pinchZoom).toBe(true);

    // Natural vertical scroll should be checked by default
    const naturalChecked = await driver.executeScript(
      "return document.getElementById('naturalVerticalScroll')?.checked", []);
    expect(naturalChecked).toBe(true);

    // Vault section
    const vaultSection = await driver.executeScript(`
      return {
        status: document.getElementById('vaultStatus')?.textContent || '',
        lockBtn: !!document.getElementById('vaultLockBtn'),
        changePwBtn: !!document.getElementById('vaultChangePwBtn'),
        resetBtn: !!document.getElementById('vaultResetBtn'),
      };
    `, []);
    expect(vaultSection.status).toBeTruthy();
    expect(vaultSection.lockBtn).toBe(true);
    expect(vaultSection.changePwBtn).toBe(true);
    expect(vaultSection.resetBtn).toBe(true);

    // Advanced section
    const advancedSection = await driver.executeScript(`
      const section = document.querySelector('.advanced-section');
      return {
        exists: !!section,
        debugOverlay: section ? !!section.querySelector('#debugOverlay') : false,
      };
    `, []);
    expect(advancedSection.exists).toBe(true);
    expect(advancedSection.debugOverlay).toBe(true);

    // Danger zone
    const dangerZone = await driver.executeScript(`
      const zone = document.querySelector('.danger-zone');
      return {
        exists: !!zone,
        allowWs: zone ? !!zone.querySelector('#dangerAllowWs') : false,
        allowPrivate: zone ? !!zone.querySelector('#allowPrivateHosts') : false,
        resetApp: zone ? !!zone.querySelector('#resetAppBtn') : false,
      };
    `, []);
    expect(dangerZone.exists).toBe(true);
    expect(dangerZone.allowWs).toBe(true);
    expect(dangerZone.allowPrivate).toBe(true);
    expect(dangerZone.resetApp).toBe(true);
    await attachScreenshot(driver, testInfo, 'settings-danger-zone');

    // Version info
    const versionInfo = await driver.executeScript(
      "return document.getElementById('versionInfo')?.textContent || ''", []);
    expect(versionInfo).toMatch(/MobiSSH/);
  });

  test('keys panel: import form and empty state', async ({ driver }, testInfo) => {
    await setupVault(driver);
    await navigateToPanel(driver, 'keys');
    await attachScreenshot(driver, testInfo, 'keys-panel');

    // Verify import form elements
    const keyFormElements = await driver.executeScript(`
      return {
        keyName: !!document.getElementById('keyName'),
        keyData: !!document.getElementById('keyData'),
        importBtn: !!document.getElementById('importKeyBtn'),
        keyList: !!document.getElementById('keyList'),
      };
    `, []);
    expect(keyFormElements.keyName).toBe(true);
    expect(keyFormElements.keyData).toBe(true);
    expect(keyFormElements.importBtn).toBe(true);
    expect(keyFormElements.keyList).toBe(true);

    // Key data textarea should have 6 rows
    const keyDataRows = await driver.executeScript(
      "return document.getElementById('keyData')?.getAttribute('rows')", []);
    expect(keyDataRows).toBe('6');

    // Empty state hint should be visible (no keys stored)
    const emptyHint = await driver.executeScript(`
      const list = document.getElementById('keyList');
      const hint = list?.querySelector('.empty-hint');
      return hint ? hint.textContent.trim() : '';
    `, []);
    expect(emptyHint).toContain('No keys');
  });

  test('full workflow: connect, navigate, gestures', async ({ driver }, testInfo) => {
    await setupVault(driver);

    // Enable pinch-to-zoom for gesture testing
    await driver.executeScript(
      "localStorage.setItem('enablePinchZoom', 'true')", []);

    await setupRealSSHConnection(driver);
    await exposeTerminal(driver);

    // Start tmux with scrollback
    try { dockerExec('su -c "tmux kill-server" testuser'); } catch { /* ok */ }
    await sendCommand(driver, 'tmux');
    await driver.pause(2000);

    ensureScript();
    dockerExec('su -c "tmux send-keys \'sh /tmp/fill-scrollback.sh\' Enter" testuser');
    await driver.pause(5000);

    // Add a second tmux window for horizontal swipe
    dockerExec('su -c "tmux new-window" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux send-keys \'echo WINDOW_TWO\' Enter" testuser');
    await driver.pause(500);
    dockerExec('su -c "tmux select-window -t 0" testuser');
    await driver.pause(500);

    await dismissKeyboardViaBack(driver);
    await driver.pause(500);
    await attachScreenshot(driver, testInfo, 'workflow-tmux-ready');

    const bounds = await getVisibleTerminalBounds(driver);
    expect(bounds).not.toBeNull();
    await warmupSwipes(driver, bounds);

    // 1. Vertical scroll to older content
    const bottomContent = await readScreen(driver);
    for (let i = 0; i < 3; i++) {
      await swipeToOlderContent(driver, bounds);
      await driver.pause(500);
    }
    await driver.pause(1500);

    const olderContent = await readScreen(driver, false);
    expect(olderContent).not.toBe(bottomContent);
    await attachScreenshot(driver, testInfo, 'workflow-scrolled-older');

    // 2. Horizontal swipe right (next tmux window)
    await driver.executeScript('window.__mockWsSpy = []', []);
    const margin = (bounds.right - bounds.left) * 0.15;
    const centerY = Math.round((bounds.top + bounds.bottom) / 2);
    await appiumSwipe(driver,
      bounds.left + margin, centerY,
      bounds.right - margin, centerY,
      15, 40);
    await driver.pause(1000);

    let msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02n')).toBe(true);
    await attachScreenshot(driver, testInfo, 'workflow-hswipe-right');

    // 3. Horizontal swipe left (prev tmux window)
    await driver.executeScript('window.__mockWsSpy = []', []);
    await appiumSwipe(driver,
      bounds.right - margin, centerY,
      bounds.left + margin, centerY,
      15, 40);
    await driver.pause(1000);

    msgs = await getWsInputMessages(driver);
    expect(msgs.some(m => m.data === '\x02p')).toBe(true);
    await attachScreenshot(driver, testInfo, 'workflow-hswipe-left');

    // 4. Pinch-to-zoom
    const fontBefore = await getFontSize(driver);
    await performPinch(driver, bounds.centerX, centerY, 100, 350);
    const fontAfterOpen = await getFontSize(driver);
    expect(fontAfterOpen).toBeGreaterThan(fontBefore);
    await attachScreenshot(driver, testInfo, 'workflow-pinch-open');

    await performPinch(driver, bounds.centerX, centerY, 350, 100);
    const fontAfterClose = await getFontSize(driver);
    expect(fontAfterClose).toBeLessThan(fontAfterOpen);
    await attachScreenshot(driver, testInfo, 'workflow-pinch-close');

    // 5. Navigate away from terminal to settings and back
    await navigateToPanel(driver, 'settings');
    const settingsActive = await driver.executeScript(`
      const panel = document.getElementById('panel-settings');
      return panel && panel.classList.contains('active');
    `, []);
    expect(settingsActive).toBe(true);
    await attachScreenshot(driver, testInfo, 'workflow-settings-mid-session');

    // Navigate to connect panel — saved profile should exist
    await navigateToPanel(driver, 'connect');
    const profileExists = await driver.executeScript(`
      const list = document.getElementById('profileList');
      const items = list?.querySelectorAll('.profile-item');
      return items ? items.length : 0;
    `, []);
    expect(profileExists).toBeGreaterThan(0);
    await attachScreenshot(driver, testInfo, 'workflow-connect-with-profile');

    // Navigate back to terminal — session should still be active
    await navigateToPanel(driver, 'terminal');
    const stillConnected = await driver.executeScript(`
      const btn = document.getElementById('sessionMenuBtn');
      return btn && btn.textContent !== 'MobiSSH';
    `, []);
    expect(stillConnected).toBe(true);
    await attachScreenshot(driver, testInfo, 'workflow-back-to-terminal');
  });
});
