/**
 * tests/bug-report-comment.spec.js
 *
 * Locks the #661 server contract for POST /api/bug-report:
 *   1. The FULL `comment` (untruncated, multi-line) is persisted into the
 *      saved *-bug-report.json — the file the orchestrator's watcher reads.
 *      This is the data-loss bug #661 fixes (the web form sent only a
 *      first-line, ~80-char title).
 *   2. The endpoint stays BACK-COMPATIBLE with the web form: a request that
 *      sends only `logs` + a truncated `title` (no `comment`) still lands the
 *      full body in the JSON's `comment` field (resolved from `logs`).
 *
 * The headless config (playwright.config.js) auto-starts the server in this
 * repo, so the uploads land in test-results/uploads/ on local disk and we can
 * read the written JSON directly.
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('./fixtures.js');

const BASE_URL = (process.env.BASE_URL || 'http://localhost:8081').replace(/\/?$/, '/');
const UPLOADS_DIR = path.join(__dirname, '..', 'test-results', 'uploads');

// A multi-line note whose later lines the old web form would have lost when it
// sliced the first line to ~80 chars for the title.
function bigNote(marker) {
  return [
    `First line that the web form would have used as the title and sliced near one hundred chars ${marker}`,
    'Second line with reproduction detail.',
    `Third line trailing marker ${marker}-END`,
  ].join('\n');
}

function findReportContaining(marker) {
  if (!fs.existsSync(UPLOADS_DIR)) return null;
  const jsons = fs
    .readdirSync(UPLOADS_DIR)
    .filter((f) => f.endsWith('-bug-report.json'));
  for (const f of jsons) {
    const raw = fs.readFileSync(path.join(UPLOADS_DIR, f), 'utf8');
    if (raw.includes(marker)) return JSON.parse(raw);
  }
  return null;
}

test.describe('POST /api/bug-report — full comment persistence (#661)', () => {
  test('native in-app payload: full comment persists in the JSON', async ({ request }) => {
    const marker = `m661native-${Date.now()}`;
    const comment = bigNote(marker);

    const res = await request.post(BASE_URL + 'api/bug-report', {
      data: {
        title: `[1.0.0+9 deadbee] First line ${marker}`,
        comment,
        logs: comment,
        version: '[1.0.0+9 deadbee]',
        source: 'native-in-app',
      },
    });
    expect(res.ok()).toBe(true);

    const meta = findReportContaining(marker);
    expect(meta, 'a bug-report.json carrying the marker must exist').not.toBeNull();
    // FULL comment survived — including the trailing line the old form lost.
    expect(meta.comment).toBe(comment);
    expect(meta.comment).toContain(`${marker}-END`);
  });

  test('web-form payload (logs only, no comment) stays back-compatible', async ({ request }) => {
    const marker = `m661web-${Date.now()}`;
    const fullText = bigNote(marker);
    // Web form shape: truncated first-line title + full text in `logs`, NO
    // `comment` field.
    const truncatedTitle = `[1.0.0] ${fullText.split('\n')[0].slice(0, 80)}`;

    const res = await request.post(BASE_URL + 'api/bug-report', {
      data: {
        title: truncatedTitle,
        logs: fullText,
        version: '[1.0.0]',
      },
    });
    expect(res.ok()).toBe(true);

    const meta = findReportContaining(`${marker}-END`);
    expect(meta, 'web-form report must persist the full body in comment').not.toBeNull();
    // Even with no `comment` field sent, the full body is recovered from logs
    // and stored in `comment` — the watcher gets the whole note.
    expect(meta.comment).toBe(fullText);
    expect(meta.comment).toContain(`${marker}-END`);
    // The title is still the (truncated) web-form title — back-compatible.
    expect(meta.title).toBe(truncatedTitle);
  });
});
