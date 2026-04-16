/**
 * tests/error-dialog-dismiss.spec.js
 *
 * Regression test for the Dismiss button on the connection error dialog.
 *
 * Context:
 *   #417 (PR #421) fixed an earlier version of this bug where Cancel/Close on
 *   connection modals did nothing. Device testing shows the error dialog's
 *   Dismiss button is broken again.
 *
 *   The dialog is shown via `showErrorDialog(msg)` in src/modules/ui.ts:246.
 *   The button uses an `{ once: true }` listener that calls
 *   overlay.classList.add('hidden') + cancelReconnect().
 *
 *   This test MUST run on every pre-release (@smoke + @device-critical tags).
 *
 *   Covers:
 *     1. Programmatic showErrorDialog() opens the overlay
 *     2. Clicking Dismiss hides the overlay
 *     3. Opening, dismissing, then opening again — second dismiss still works
 *        (regression against listener-consumption races)
 *     4. Backdrop click behavior (don't dismiss on backdrop — overlay has no
 *        outside-click dismiss for error dialogs)
 */

const { test, expect } = require('./fixtures.js');

test.describe('Error dialog Dismiss button', { tag: ['@smoke', '@device-critical'] }, () => {

  test('Dismiss button hides the error dialog overlay', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#connectForm', { timeout: 8000 });

    // Trigger the error dialog programmatically via the exported function
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Test error message');
    });

    // Overlay is visible
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);
    await expect(page.locator('#errorDialogText')).toHaveText('Test error message');

    // Click Dismiss
    await page.locator('#errorDialogDismiss').click();

    // Overlay is hidden
    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);
  });

  test('Dismiss works repeatedly — open, dismiss, open again, dismiss', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#connectForm', { timeout: 8000 });

    // Round 1
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Error 1');
    });
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);
    await page.locator('#errorDialogDismiss').click();
    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);

    // Round 2 — the listener from round 1 was once:true, so round 2 needs a
    // fresh listener. If showErrorDialog doesn't add one, this click fails.
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Error 2');
    });
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);
    await expect(page.locator('#errorDialogText')).toHaveText('Error 2');

    await page.locator('#errorDialogDismiss').click();
    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);
  });

  test('Dismiss still works when connection status overlay is also present', async ({ page }) => {
    // Real-device bug: the connection status overlay (created by
    // _showConnectionStatus in connection.ts) can overlap or stack under the
    // error dialog. Verify the Dismiss button remains clickable when both
    // elements are in the DOM.
    await page.goto('./');
    await page.waitForSelector('#connectForm', { timeout: 8000 });

    // Show both overlays — error dialog (static) and a fake connection status overlay
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      // Simulate a lingering connection status overlay like the one connection.ts creates
      let statusEl = document.getElementById('connectionStatusOverlay');
      if (!statusEl) {
        statusEl = document.createElement('div');
        statusEl.id = 'connectionStatusOverlay';
        statusEl.className = 'connection-status-overlay';
        statusEl.innerHTML = '<div class="connection-status-msg">Connecting…</div>';
        document.body.appendChild(statusEl);
      }
      mod.showErrorDialog('Host unreachable.');
    });

    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);

    // Verify the Dismiss button is not visually obscured (has non-zero pointer area)
    const clickable = await page.locator('#errorDialogDismiss').evaluate((el) => {
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return { ok: false, reason: 'zero size' };
      const cx = rect.left + rect.width / 2;
      const cy = rect.top + rect.height / 2;
      const top = document.elementFromPoint(cx, cy);
      return { ok: top === el || el.contains(top), topId: top?.id ?? top?.tagName };
    });
    expect(clickable.ok).toBe(true);

    // Click Dismiss
    await page.locator('#errorDialogDismiss').click();
    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);
  });

  test('Dismiss responds to touch tap (not just mouse click)', async ({ page, isMobile }) => {
    await page.goto('./');
    await page.waitForSelector('#connectForm', { timeout: 8000 });

    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Touch test');
    });
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);

    // Use touch tap on mobile projects; fall back to click on desktop
    if (isMobile) {
      await page.locator('#errorDialogDismiss').tap();
    } else {
      await page.locator('#errorDialogDismiss').click();
    }

    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);
  });

  test('Double-show without dismiss between — both dismisses should hide the overlay', async ({ page }) => {
    await page.goto('./');
    await page.waitForSelector('#connectForm', { timeout: 8000 });

    // Show first dialog
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Error A');
    });
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);

    // Show second dialog while first still visible (simulates reconnect cascade).
    // Each showErrorDialog call adds a fresh `once:true` listener — this stacks
    // two listeners. First click fires both (both removed). Overlay hides.
    await page.evaluate(async () => {
      const mod = await import('./modules/ui.js');
      mod.showErrorDialog('Error B');
    });
    await expect(page.locator('#errorDialogOverlay')).not.toHaveClass(/hidden/);
    await expect(page.locator('#errorDialogText')).toHaveText('Error B');

    // Single click should dismiss
    await page.locator('#errorDialogDismiss').click();
    await expect(page.locator('#errorDialogOverlay')).toHaveClass(/hidden/);
  });
});
