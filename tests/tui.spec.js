/**
 * tests/tui.spec.js
 *
 * Integration tests for TUI (Terminal UI) application compatibility.
 *
 * Tracks issue #53: TUI coding agents (Claude Code CLI, opencode, code, etc.)
 * have rendering/input issues. Tests assert correct behaviour across all five
 * areas from the issue investigation checklist:
 *
 *   1. Rendering — ANSI 256-color, truecolor, SGR attributes pass through
 *   2. Rendering — box-drawing characters (used by opencode, Claude Code TUI)
 *   3. Rendering — alternate screen buffer smcup/rmcup (ESC[?1049h / ESC[?1049l)
 *   4. Terminal dimensions — valid COLUMNS/LINES reported via resize message
 *   5. Input — function keys F1–F12, navigation keys, Ctrl combos
 *   6. Key bar — navigation buttons produce correct VT sequences
 *
 * All tests use the mockSshServer fixture (see fixtures.js) which does NOT
 * require a live SSH server — the mock auto-responds with `connected`.
 */

const { test, expect, setupConnected } = require('./fixtures.js');

// ── helpers ───────────────────────────────────────────────────────────────────

/** Read all `input`-type SSH messages recorded in the WS spy. */
async function getInputMessages(page) {
  await page.waitForTimeout(100);
  const raw = await page.evaluate(() => window.__mockWsSpy || []);
  return raw
    .map((s) => { try { return JSON.parse(s); } catch (_) { return null; } })
    .filter((m) => m && m.type === 'input');
}

/** Read all `resize`-type SSH messages recorded in the WS spy. */
async function getResizeMessages(page) {
  await page.waitForTimeout(50);
  const raw = await page.evaluate(() => window.__mockWsSpy || []);
  return raw
    .map((s) => { try { return JSON.parse(s); } catch (_) { return null; } })
    .filter((m) => m && m.type === 'resize');
}

/** Dispatch a single KeyboardEvent on #imeInput. */
async function pressKey(page, keyInit) {
  await page.evaluate((init) => {
    const el = document.getElementById('imeInput');
    el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }));
  }, keyInit);
}

// ── Rendering: ANSI sequences ─────────────────────────────────────────────────

test.describe('TUI rendering — ANSI sequences pass through without errors', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    page._jsErrors = [];
    page.on('pageerror', (err) => page._jsErrors.push(err.message));
    await setupConnected(page, mockSshServer);
  });

  test('256-color foreground (ESC[38;5;Nm) — typical prompt colour', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[38;5;200mhello\x1b[0m' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('256-color background (ESC[48;5;Nm)', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[48;5;57m background \x1b[0m' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('truecolor foreground (ESC[38;2;R;G;Bm) — used by Claude Code TUI', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[38;2;255;100;50mtruecolor text\x1b[0m' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('truecolor background (ESC[48;2;R;G;Bm)', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[48;2;30;30;50m background \x1b[0m' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('SGR attributes: bold, dim, italic, underline', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({
      type: 'output',
      data: '\x1b[1mbold\x1b[0m \x1b[2mdim\x1b[0m \x1b[3mitalic\x1b[0m \x1b[4munderline\x1b[0m',
    });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('cursor movement sequences (CUP, CUU, CUD, CUF, CUB)', async ({ page, mockSshServer }) => {
    // These are used in every TUI rendering loop
    mockSshServer.sendToPage({
      type: 'output',
      data: '\x1b[H\x1b[2J\x1b[5;10H\x1b[1A\x1b[2B\x1b[3C\x1b[4D',
    });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('erase in display (ED) and erase in line (EL)', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({
      type: 'output',
      data: '\x1b[2J\x1b[2K\x1b[1K\x1b[0K',
    });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('rapid output burst — simulate TUI full-screen redraw', async ({ page, mockSshServer }) => {
    // TUI apps redraw on resize; flood of sequences should not crash xterm.js
    const row = '\x1b[38;5;33m│\x1b[0m ' + 'x'.repeat(40) + ' \x1b[38;5;33m│\x1b[0m\r\n';
    const burst = '\x1b[H\x1b[2J' + row.repeat(20);
    mockSshServer.sendToPage({ type: 'output', data: burst });
    await page.waitForTimeout(300);
    expect(page._jsErrors).toEqual([]);
  });
});

// ── Rendering: box-drawing characters ────────────────────────────────────────

test.describe('TUI rendering — box-drawing characters', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    page._jsErrors = [];
    page.on('pageerror', (err) => page._jsErrors.push(err.message));
    await setupConnected(page, mockSshServer);
  });

  test('light box-drawing frame — used by opencode and Claude Code TUI', async ({ page, mockSshServer }) => {
    const frame =
      '┌──────────────────┐\r\n' +
      '│   TUI app frame  │\r\n' +
      '└──────────────────┘';
    mockSshServer.sendToPage({ type: 'output', data: frame });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('heavy and double box-drawing characters', async ({ page, mockSshServer }) => {
    const frame =
      '╔══════════════════╗\r\n' +
      '║   double border  ║\r\n' +
      '╠══════════════════╣\r\n' +
      '║   content area   ║\r\n' +
      '╚══════════════════╝\r\n' +
      '┣━━━━━━━━━━━━━━━━━━┫\r\n' +
      '┃   heavy border   ┃\r\n';
    mockSshServer.sendToPage({ type: 'output', data: frame });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('box-drawing with 256-color borders — typical TUI panel', async ({ page, mockSshServer }) => {
    // opencode and Claude Code render colored bordered panels
    const coloredFrame =
      '\x1b[38;5;33m┌──────────────┐\x1b[0m\r\n' +
      '\x1b[38;5;33m│\x1b[0m \x1b[1mTitle\x1b[0m         \x1b[38;5;33m│\x1b[0m\r\n' +
      '\x1b[38;5;33m├──────────────┤\x1b[0m\r\n' +
      '\x1b[38;5;33m│\x1b[0m content       \x1b[38;5;33m│\x1b[0m\r\n' +
      '\x1b[38;5;33m└──────────────┘\x1b[0m';
    mockSshServer.sendToPage({ type: 'output', data: coloredFrame });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('mixed ASCII and box-drawing in same buffer', async ({ page, mockSshServer }) => {
    // Some TUI apps mix ASCII art with real box-drawing
    const mixed =
      'regular text ┤ mixed ├ content\r\n' +
      '─────────────────────────────\r\n' +
      '│ col1 │ col2 │ col3 │\r\n' +
      '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\r\n';
    mockSshServer.sendToPage({ type: 'output', data: mixed });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });
});

// ── Alternate screen buffer (smcup / rmcup) ───────────────────────────────────

test.describe('TUI rendering — alternate screen buffer (smcup/rmcup)', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    page._jsErrors = [];
    page.on('pageerror', (err) => page._jsErrors.push(err.message));
    await setupConnected(page, mockSshServer);
  });

  test('entering alternate screen (ESC[?1049h) does not crash', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[?1049h' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
    await expect(page.locator('#terminal')).toBeVisible();
  });

  test('full TUI session: enter alt screen, draw UI, exit to main screen', async ({ page, mockSshServer }) => {
    // Simulate what Claude Code CLI / opencode do on startup
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[?1049h\x1b[2J\x1b[H' });
    await page.waitForTimeout(100);
    mockSshServer.sendToPage({
      type: 'output',
      data:
        '\x1b[1;1H\x1b[38;5;33m┌────────────────────────┐\x1b[0m\r\n' +
        '\x1b[2;1H\x1b[38;5;33m│\x1b[0m \x1b[1mClaude Code\x1b[0m            \x1b[38;5;33m│\x1b[0m\r\n' +
        '\x1b[3;1H\x1b[38;5;33m└────────────────────────┘\x1b[0m\r\n',
    });
    await page.waitForTimeout(100);
    // Exit alt screen — main screen content should be restored
    mockSshServer.sendToPage({ type: 'output', data: '\x1b[?1049l' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
    await expect(page.locator('#terminal')).toBeVisible();
  });

  test('DECSET private modes used by TUIs do not crash xterm.js', async ({ page, mockSshServer }) => {
    // Various DECSET modes used by htop, vim, nano, claude, opencode
    const modes = [
      '\x1b[?25l',   // DECTCEM: hide cursor
      '\x1b[?25h',   // DECTCEM: show cursor
      '\x1b[?7l',    // DECAWM: no auto-wrap
      '\x1b[?7h',    // DECAWM: auto-wrap
      '\x1b[?1h',    // application cursor keys (DECCKM)
      '\x1b[?1l',    // normal cursor keys
      '\x1b[?1000h', // X10 mouse reporting
      '\x1b[?1000l', // disable mouse reporting
      '\x1b[?1002h', // button event mouse tracking
      '\x1b[?1002l',
      '\x1b[?1006h', // SGR mouse mode
      '\x1b[?1006l',
      '\x1b[?2004h', // bracketed paste mode
      '\x1b[?2004l', // disable bracketed paste
    ].join('');
    mockSshServer.sendToPage({ type: 'output', data: modes });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });

  test('application keypad mode (DECKPAM/DECKPNM) does not crash', async ({ page, mockSshServer }) => {
    mockSshServer.sendToPage({ type: 'output', data: '\x1b=\x1b>' });
    await page.waitForTimeout(200);
    expect(page._jsErrors).toEqual([]);
  });
});

// ── Terminal dimensions ───────────────────────────────────────────────────────

test.describe('Terminal dimensions for TUI apps', () => {
  test('resize message sent after connect has non-zero cols and rows', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    const resizes = await getResizeMessages(page);
    expect(resizes.length).toBeGreaterThan(0);
    const r = resizes[resizes.length - 1];
    expect(r.cols).toBeGreaterThan(0);
    expect(r.rows).toBeGreaterThan(0);
  });

  test('terminal cols ≥ 40 — minimum for most TUI apps', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    const resizes = await getResizeMessages(page);
    expect(resizes.length).toBeGreaterThan(0);
    expect(resizes[resizes.length - 1].cols).toBeGreaterThanOrEqual(40);
  });

  test('terminal rows ≥ 10 — minimum for most TUI apps', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    const resizes = await getResizeMessages(page);
    expect(resizes.length).toBeGreaterThan(0);
    expect(resizes[resizes.length - 1].rows).toBeGreaterThanOrEqual(10);
  });

  test('resize message cols and rows are integers', async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    const resizes = await getResizeMessages(page);
    const r = resizes[resizes.length - 1];
    expect(Number.isInteger(r.cols)).toBe(true);
    expect(Number.isInteger(r.rows)).toBe(true);
  });
});

// ── Input: function keys F1–F12 ───────────────────────────────────────────────
//
// Function keys are used heavily by TUI apps:
//   F1 = help in htop/nano;  F5/F6 = prev/next match in less/vim;
//   F10 = quit htop;  F12 = various menus.
//
// VT sequences sourced from xterm terminfo / KEY_MAP in app.js:
//   F1–F4 use SS3 (ESC O);  F5–F12 use CSI Ps ~ (tilde format, skips 16).

test.describe('TUI input — function keys F1–F12', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await page.locator('#imeInput').focus().catch(() => {});
  });

  const fnKeys = [
    { key: 'F1',  expected: '\x1bOP'   },
    { key: 'F2',  expected: '\x1bOQ'   },
    { key: 'F3',  expected: '\x1bOR'   },
    { key: 'F4',  expected: '\x1bOS'   },
    { key: 'F5',  expected: '\x1b[15~' },
    { key: 'F6',  expected: '\x1b[17~' }, // note: 16~ is unused per terminfo
    { key: 'F7',  expected: '\x1b[18~' },
    { key: 'F8',  expected: '\x1b[19~' },
    { key: 'F9',  expected: '\x1b[20~' },
    { key: 'F10', expected: '\x1b[21~' },
    { key: 'F11', expected: '\x1b[23~' }, // note: 22~ is unused
    { key: 'F12', expected: '\x1b[24~' },
  ];

  for (const { key, expected } of fnKeys) {
    test(`${key} sends ${JSON.stringify(expected)}`, async ({ page }) => {
      await pressKey(page, { key });
      const msgs = await getInputMessages(page);
      expect(msgs.some((m) => m.data === expected)).toBe(true);
    });
  }
});

// ── Input: navigation keys ────────────────────────────────────────────────────
//
// Navigation keys used by TUI text editors (vim, nano) and pagers (less, man).
// ArrowLeft/Right complete the set (Up/Down already in ime.spec.js key bar tests).

test.describe('TUI input — navigation keys via keydown', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await page.locator('#imeInput').focus().catch(() => {});
  });

  const navKeys = [
    { key: 'ArrowLeft',  expected: '\x1b[D'  },
    { key: 'ArrowRight', expected: '\x1b[C'  },
    { key: 'Home',       expected: '\x1b[H'  },
    { key: 'End',        expected: '\x1b[F'  },
    { key: 'PageUp',     expected: '\x1b[5~' },
    { key: 'PageDown',   expected: '\x1b[6~' },
    { key: 'Delete',     expected: '\x1b[3~' },
    { key: 'Insert',     expected: '\x1b[2~' },
    { key: 'Backspace',  expected: '\x7f'    },
  ];

  for (const { key, expected } of navKeys) {
    test(`${key} → ${JSON.stringify(expected)}`, async ({ page }) => {
      await pressKey(page, { key });
      const msgs = await getInputMessages(page);
      expect(msgs.some((m) => m.data === expected)).toBe(true);
    });
  }
});

// ── Input: Ctrl combos ────────────────────────────────────────────────────────
//
// Ctrl combos via hardware keyboard (ctrlKey: true in KeyboardEvent).
// These are critical for TUI apps — each combo has a well-known purpose:
//   Ctrl+A  — move to beginning of line (readline / vim)
//   Ctrl+B  — tmux prefix (default) / back one char
//   Ctrl+D  — EOF / logout / close pane
//   Ctrl+E  — move to end of line
//   Ctrl+L  — clear screen (most shells and REPLs)
//   Ctrl+R  — reverse history search
//   Ctrl+U  — clear line before cursor
//   Ctrl+W  — delete word before cursor
//
// Note: Ctrl+C (^C) and Ctrl+Z (^Z) are tested in ime.spec.js via the
// sticky-modifier path.  These tests cover the hardware keyboard path
// (ctrlKey: true in KeyboardEvent).

test.describe('TUI input — Ctrl combos via hardware keyboard', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });
    await page.locator('#imeInput').focus().catch(() => {});
  });

  const ctrlCombos = [
    { letter: 'a', expected: '\x01', note: 'beginning of line' },
    { letter: 'b', expected: '\x02', note: 'tmux prefix / back char' },
    { letter: 'c', expected: '\x03', note: 'interrupt (SIGINT)' },
    { letter: 'd', expected: '\x04', note: 'EOF / close pane' },
    { letter: 'e', expected: '\x05', note: 'end of line' },
    { letter: 'l', expected: '\x0c', note: 'clear screen' },
    { letter: 'r', expected: '\x12', note: 'reverse history search' },
    { letter: 'u', expected: '\x15', note: 'clear line' },
    { letter: 'w', expected: '\x17', note: 'delete word' },
    { letter: 'z', expected: '\x1a', note: 'suspend (SIGTSTP)' },
  ];

  for (const { letter, expected, note } of ctrlCombos) {
    test(`Ctrl+${letter.toUpperCase()} → \\x${expected.charCodeAt(0).toString(16).padStart(2, '0')} (${note})`, async ({ page }) => {
      await pressKey(page, { key: letter, ctrlKey: true });
      const msgs = await getInputMessages(page);
      expect(msgs.some((m) => m.data === expected)).toBe(true);
    });
  }
});

// ── Key bar navigation buttons for TUI ───────────────────────────────────────
//
// The key bar provides touch-friendly buttons for navigation sequences that
// TUI apps require but that aren't easily typed on an on-screen keyboard.
// Tests cover the buttons added for issue #53 that weren't in ime.spec.js.

test.describe('Key bar navigation buttons for TUI apps', () => {
  test.beforeEach(async ({ page, mockSshServer }) => {
    await setupConnected(page, mockSshServer);
    await page.evaluate(() => { window.__mockWsSpy = []; });
  });

  test('Left arrow button sends \\x1b[D', async ({ page }) => {
    await page.locator('#keyLeft').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[D')).toBe(true);
  });

  test('Right arrow button sends \\x1b[C', async ({ page }) => {
    await page.locator('#keyRight').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[C')).toBe(true);
  });

  test('Home button sends \\x1b[H', async ({ page }) => {
    await page.locator('#keyHome').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[H')).toBe(true);
  });

  test('End button sends \\x1b[F', async ({ page }) => {
    await page.locator('#keyEnd').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[F')).toBe(true);
  });

  test('PageUp button sends \\x1b[5~', async ({ page }) => {
    await page.locator('#keyPgUp').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[5~')).toBe(true);
  });

  test('PageDown button sends \\x1b[6~', async ({ page }) => {
    await page.locator('#keyPgDn').click();
    const msgs = await getInputMessages(page);
    expect(msgs.some((m) => m.data === '\x1b[6~')).toBe(true);
  });
});
