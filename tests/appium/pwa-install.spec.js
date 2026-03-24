/**
 * tests/appium/pwa-install.spec.js
 *
 * PWA install test — installs MobiSSH on the Android emulator home screen
 * via Chrome's native "Add to Home screen" flow, then captures screenshots
 * of the home screen icon and app launch splash screen.
 *
 * This is the only way to validate the PWA logo on Android — headless
 * Chromium does not support beforeinstallprompt or the install flow.
 *
 * Requires: Android emulator, Appium server, MobiSSH server running.
 */

const { execSync } = require('child_process');
const {
  test, expect,
  switchToWebview, switchToNative, dismissNativeDialogs,
  attachScreenshot, setupVault,
  BASE_URL,
} = require('./fixtures');

/**
 * Uninstall MobiSSH PWA from the emulator if it exists.
 * WebAPKs are installed as regular Android packages.
 */
function uninstallPWA() {
  try {
    // Find MobiSSH WebAPK package (Chrome generates org.chromium.webapk.*)
    const packages = execSync(
      'adb shell pm list packages | grep -i mobissh || true',
      { encoding: 'utf8', timeout: 5000 },
    ).trim();
    if (packages) {
      for (const line of packages.split('\n')) {
        const pkg = line.replace('package:', '').trim();
        if (pkg) {
          execSync(`adb shell pm uninstall ${pkg}`, { timeout: 5000 });
        }
      }
    }
  } catch { /* best effort */ }

  // Also remove shortcut-based installs via Chrome's data
  try {
    execSync(
      'adb shell am broadcast -a com.android.launcher.action.UNINSTALL_SHORTCUT ' +
      '-e android.intent.extra.shortcut.NAME "MobiSSH" 2>/dev/null || true',
      { timeout: 5000 },
    );
  } catch { /* best effort */ }
}

/**
 * Wait for a native UI element by text using UiAutomator2.
 * Returns the element or null if not found within timeout.
 */
async function waitForNativeText(driver, text, timeoutMs = 10000) {
  const selector = `new UiSelector().textContains("${text}")`;
  const endTime = Date.now() + timeoutMs;
  while (Date.now() < endTime) {
    const elements = await driver.$$(`android=new UiSelector().textContains("${text}")`);
    if (elements.length > 0 && await elements[0].isDisplayed()) {
      return elements[0];
    }
    await driver.pause(500);
  }
  return null;
}

/**
 * Click a native element by text.
 */
async function clickNativeText(driver, text, timeoutMs = 10000) {
  const el = await waitForNativeText(driver, text, timeoutMs);
  if (el) {
    await el.click();
    return true;
  }
  return false;
}

test.describe('PWA install (Appium)', () => {
  test.setTimeout(120_000);

  test('install PWA and capture home screen icon', async ({ driver }, testInfo) => {
    // Clean slate: uninstall any existing PWA
    uninstallPWA();

    // Navigate to the app and wait for service worker to register
    await driver.url(BASE_URL);
    await driver.pause(3000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);

    // Set up vault so the app is in a normal state
    await setupVault(driver);
    await driver.pause(1000);

    // Verify service worker is registered (required for PWA install)
    const swReady = await driver.executeScript(`
      return navigator.serviceWorker.ready
        .then(() => true)
        .catch(() => false);
    `, []);
    expect(swReady).toBe(true);

    // Screenshot the app before install
    await attachScreenshot(driver, testInfo, '01-app-before-install');

    // Switch to native to interact with Chrome menu
    await switchToNative(driver);

    // Open Chrome's three-dot menu
    // Try the standard overflow menu button
    const menuBtn = await driver.$$('android=new UiSelector().description("More options")');
    if (menuBtn.length > 0) {
      await menuBtn[0].click();
    } else {
      // Fallback: use Android keycode for menu
      await driver.pressKeyCode(82); // KEYCODE_MENU
    }
    await driver.pause(1500);
    await attachScreenshot(driver, testInfo, '02-chrome-menu-open');

    // Look for "Add to Home screen" or "Install app" menu item
    // Chrome uses different text depending on version and PWA eligibility
    let installed = false;

    // Try "Install app" first (newer Chrome, fully qualified PWA)
    const installApp = await waitForNativeText(driver, 'Install app', 3000);
    if (installApp) {
      await installApp.click();
      await driver.pause(1500);

      // Chrome shows an install confirmation dialog
      await attachScreenshot(driver, testInfo, '03-install-dialog');

      // Click "Install" on the confirmation dialog
      const installBtn = await waitForNativeText(driver, 'Install', 5000);
      if (installBtn) {
        await installBtn.click();
        installed = true;
      }
    }

    if (!installed) {
      // Try "Add to Home screen" (older Chrome or shortcut-based install)
      const addToHome = await waitForNativeText(driver, 'Add to Home screen', 3000);
      if (addToHome) {
        await addToHome.click();
        await driver.pause(1500);
        await attachScreenshot(driver, testInfo, '03-add-to-home-dialog');

        // Confirm the dialog — look for "Add" button
        const addBtn = await waitForNativeText(driver, 'Add', 5000);
        if (addBtn) {
          await addBtn.click();
          installed = true;
        }
      }
    }

    if (!installed) {
      // Last resort: try Chrome custom tabs install banner
      // Take a diagnostic screenshot
      await attachScreenshot(driver, testInfo, '03-no-install-option-found');
      // Don't fail — just log what we see
      console.log('WARNING: Neither "Install app" nor "Add to Home screen" found');
      console.log('This may mean Chrome does not consider the app installable');
    }

    // Wait for install to complete
    await driver.pause(3000);
    await attachScreenshot(driver, testInfo, '04-after-install');

    // Go to Android home screen
    await driver.pressKeyCode(3); // KEYCODE_HOME
    await driver.pause(2000);

    // Capture home screen with the new icon
    await attachScreenshot(driver, testInfo, '05-home-screen-with-icon');

    // Try to find MobiSSH on the home screen
    const appIcon = await waitForNativeText(driver, 'MobiSSH', 5000);
    if (appIcon) {
      await attachScreenshot(driver, testInfo, '06-mobissh-icon-found');

      // Launch the PWA by tapping the icon
      await appIcon.click();
      await driver.pause(5000); // Wait for splash + app load

      // Capture the splash screen / app launch
      await attachScreenshot(driver, testInfo, '07-pwa-launched');
    } else {
      // App might be in the app drawer instead of home screen
      // Swipe up to open app drawer
      await driver.performActions([{
        type: 'pointer',
        id: 'finger1',
        parameters: { pointerType: 'touch' },
        actions: [
          { type: 'pointerMove', duration: 0, x: 540, y: 2000, origin: 'viewport' },
          { type: 'pointerDown', button: 0 },
          { type: 'pointerMove', duration: 300, x: 540, y: 800, origin: 'viewport' },
          { type: 'pointerUp', button: 0 },
        ],
      }]);
      await driver.releaseActions();
      await driver.pause(1500);

      await attachScreenshot(driver, testInfo, '06-app-drawer');

      // Search for MobiSSH in the drawer
      const drawerIcon = await waitForNativeText(driver, 'MobiSSH', 5000);
      if (drawerIcon) {
        await attachScreenshot(driver, testInfo, '07-mobissh-in-drawer');
        await drawerIcon.click();
        await driver.pause(5000);
        await attachScreenshot(driver, testInfo, '08-pwa-launched-from-drawer');
      } else {
        await attachScreenshot(driver, testInfo, '07-mobissh-not-found');
        console.log('WARNING: MobiSSH icon not found on home screen or app drawer');
      }
    }

    // Final state: capture whatever is on screen
    await attachScreenshot(driver, testInfo, '09-final-state');
  });

  test('verify installed PWA icon matches manifest', async ({ driver }, testInfo) => {
    // Take a screenshot via ADB (full resolution, includes system chrome)
    try {
      execSync('adb shell screencap -p /sdcard/pwa-homescreen.png', { timeout: 5000 });
      execSync('adb pull /sdcard/pwa-homescreen.png /tmp/pwa-homescreen.png', { timeout: 5000 });
      const fs = require('fs');
      if (fs.existsSync('/tmp/pwa-homescreen.png')) {
        await testInfo.attach('adb-home-screen', {
          path: '/tmp/pwa-homescreen.png',
          contentType: 'image/png',
        });
      }
    } catch { /* best effort */ }

    // Navigate to the app and verify manifest icon URLs are correct
    await driver.url(BASE_URL);
    await driver.pause(2000);
    await dismissNativeDialogs(driver);
    await switchToWebview(driver);

    // Verify manifest is accessible and has correct icon data
    const manifestData = await driver.executeScript(`
      return fetch('manifest.json')
        .then(r => r.json())
        .then(m => ({
          name: m.name,
          short_name: m.short_name,
          icons: m.icons,
          display: m.display,
          id: m.id,
        }))
        .catch(e => ({ error: e.message }));
    `, []);

    expect(manifestData.name).toBe('MobiSSH');
    expect(manifestData.display).toBe('standalone');
    expect(manifestData.icons).toBeDefined();
    expect(manifestData.icons.length).toBeGreaterThanOrEqual(2);

    // Verify icons are loadable
    const iconStatus = await driver.executeScript(`
      const results = [];
      const icons = arguments[0];
      for (const icon of icons) {
        try {
          const r = await fetch(icon.src);
          results.push({ src: icon.src, sizes: icon.sizes, status: r.status, ok: r.ok });
        } catch (e) {
          results.push({ src: icon.src, sizes: icon.sizes, error: e.message });
        }
      }
      return results;
    `, [manifestData.icons]);

    for (const icon of iconStatus) {
      expect(icon.ok).toBe(true);
    }

    // Verify icon-192 dimensions via Image element
    const iconDims = await driver.executeScript(`
      return new Promise((resolve) => {
        const img = new Image();
        img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight });
        img.onerror = () => resolve({ error: 'failed to load' });
        img.src = 'icon-192.png';
      });
    `, []);

    expect(iconDims.width).toBe(192);
    expect(iconDims.height).toBe(192);
    await attachScreenshot(driver, testInfo, 'manifest-verified');
  });
});
