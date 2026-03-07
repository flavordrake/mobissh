# Testing Best Practices — MobiSSH

## Test Pyramid
```
 Unit (Vitest)     — fast, isolated, run every cycle
 Browser (Playwright headless) — slower, real browser, run before PR
 Device (Appium/emulator)      — slowest, real hardware, human-gated
```

## Test Gate Commands
```bash
npx tsc --noEmit                  # TypeScript type check (~5s)
npx eslint src/ public/ server/ tests/  # Lint (~3s)
npx vitest run                    # Unit tests (~2s)
npx playwright test --config=playwright.config.js --grep-invert="Production endpoint"  # Headless (~60s)
```
Run in this order. Fast gates first — fail fast.

## Vitest Unit Tests
Location: `src/modules/__tests__/*.test.ts`

### Pattern
```typescript
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { webcrypto } from 'node:crypto';

// Stub browser globals for Node environment
vi.stubGlobal('crypto', webcrypto);
vi.stubGlobal('localStorage', localStorageMock);

// Dynamic import AFTER stubs (module-level code runs immediately)
const vault = await import('../vault.js');

describe('feature area', () => {
  beforeEach(() => {
    // Reset state between tests
    storage.clear();
    appState.vaultKey = null;
  });

  it('does the expected thing', async () => {
    await vault.createVault('testpass', false);
    expect(vault.vaultExists()).toBe(true);
  });
});
```

### Rules
- Stub globals BEFORE dynamic imports
- Reset all shared state in `beforeEach`
- Test behavior, not implementation details
- No network calls — mock WebSocket/fetch

## Playwright Browser Tests
Location: `tests/*.spec.js`
Config: `playwright.config.js`

### Projects
| Name | Device | Browser |
|---|---|---|
| `pixel-7` | Pixel 7 viewport | Chromium |
| `iphone-14` | iPhone 14 viewport | WebKit |
| `chromium` | Desktop Chrome | Chromium |

### Fixtures (`tests/fixtures.js`)
```javascript
const test = base.extend({
  page: async ({ page }, use) => {
    // Auto-dismiss vault setup by pre-seeding localStorage
    await page.addInitScript(() => {
      if (!localStorage.getItem('vaultMeta')) {
        localStorage.setItem('vaultMeta', JSON.stringify({ /* seed data */ }));
      }
    });
    await use(page);
  },
  mockSshServer: async ({}, use) => {
    // Lightweight WS server simulating SSH bridge protocol
    const wss = new WebSocketServer({ port });
    await use(mockServer);
    wss.close();
  },
});
```
Always use the custom `test` from fixtures, not bare `@playwright/test`.

### Test Pattern
```javascript
const { test, expect, setupConnected } = require('./fixtures.js');

test.describe('Feature area (#issueNumber)', () => {
  test('specific behavior under test', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);

    // Act
    await page.locator('#someButton').click();

    // Assert
    await expect(page.locator('#result')).toBeVisible();
    await expect(page.locator('#result')).toHaveText('expected');
  });
});
```

### Common Pitfalls
- **Never use `force: true`** — if a click needs force, the element isn't properly visible
- **Never use extended timeouts** (`timeout: 30000`) — fix the underlying timing issue
- **Never use `waitForSelector` with `.hidden` class** — use `locator.waitFor({ state: 'hidden' })`
- **Never modify frozen baselines** (`*-baseline.spec.*`) — semgrep blocks this
- **Always block service workers** in test config (`serviceWorkers: 'block'`)
- **Always use `setupConnected()`** when testing connected-state features
- **Use `page.addInitScript()`** to seed localStorage/state before navigation

### Writing New Tests
1. Add to existing spec file if it's the same feature area
2. Use the test describe block format: `'Feature area (#issueNumber)'`
3. Reference the fixtures — don't duplicate mock server setup
4. Test all three projects (pixel-7, iphone-14, chromium) by default
5. If a test is mobile-only, use `test.skip` with project name check

### When Tests Fail
1. Read the error message carefully — is it your code or a pre-existing issue?
2. Check if the selector changed — DOM structure may have been modified
3. Check viewport — mobile tests have different layout than desktop
4. Check async timing — use `expect().toBeVisible()` not raw `waitForSelector`
5. If a test fails on WebKit but passes on Chromium, it's likely a real cross-browser issue

## Semgrep Rules
Custom rules in `.semgrep/rules.yml` and `.semgrep/playwright-traps.yml`:
- `duplicate-event-listener` — catches doubled addEventListener calls
- `plaintext-secret-storage` — blocks localStorage of passwords/secrets
- `no-waitForSelector-hidden-class` — catches broken hidden-class waits
- `frozen-baseline-test` — prevents modification of baseline test files

## Test Coverage Expectations
- New features: add both unit test (if logic-heavy) and Playwright test
- Bug fixes: add a regression test that reproduces the bug
- CSS-only changes: Playwright test verifying visibility/layout, no unit test needed
- Server changes: unit test for logic, Playwright test for WS protocol behavior
