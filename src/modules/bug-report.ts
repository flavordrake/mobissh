/**
 * modules/bug-report.ts — One-tap bug report: screenshot + logs → GitHub issue
 *
 * Captures the current screen via html2canvas, bundles the debug log,
 * and POSTs to /api/bug-report. The server saves files and creates
 * a GitHub issue with the screenshot and log context.
 */

import { getConnectLogForBugReport } from './connect-log.js';
import { getGestureLogForBugReport } from './gesture-log.js';

declare const html2canvas: (element: HTMLElement, options?: Record<string, unknown>) => Promise<HTMLCanvasElement>;

let _getDebugLines: (() => string[]) | null = null;
let _toast: (msg: string) => void = () => {};

export function initBugReport(deps: { getDebugLines: () => string[]; toast: (msg: string) => void }): void {
  _getDebugLines = deps.getDebugLines;
  _toast = deps.toast;

  const reportBtn = document.getElementById('debugReportBtn');
  if (reportBtn) {
    reportBtn.addEventListener('click', () => {
      void submitBugReport();
    });
    reportBtn.addEventListener('mousedown', (ev) => { ev.preventDefault(); });
  }
}

async function submitBugReport(): Promise<void> {
  // Collect logs BEFORE hiding debug panel (so the log includes recent context)
  const lines = _getDebugLines ? _getDebugLines() : [];
  const logs = lines.join('\n');

  // Capture the screen as-is — the debug panel and FAB are legitimate
  // UI elements; hiding them removes context the user may want to verify
  // (e.g., "is the new toggle style applied?"). User can collapse the
  // panel manually before tapping Report if they want a clean shot.
  _toast('Capturing bug report...');

  // Small delay for toast to render
  await new Promise((r) => { setTimeout(r, 300); });

  // Capture screenshot (without debug overlay)
  let screenshot = '';
  try {
    const app = document.getElementById('app');
    if (app && typeof html2canvas === 'function') {
      const canvas = await html2canvas(app, {
        scale: window.devicePixelRatio || 1,
        useCORS: true,
        logging: false,
        backgroundColor: '#0d0d1a',
      });
      screenshot = canvas.toDataURL('image/png');
    }
  } catch (err) {
    console.warn('[bug-report] screenshot failed:', err);
  }

  // Collect metadata
  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  const version = meta?.content ?? 'unknown';

  // Prompt for title
  const title = prompt('Bug title (optional):') ?? '';

  const payload = {
    screenshot,
    logs,
    title: title || 'Bug report from device',
    userAgent: navigator.userAgent,
    url: location.href,
    version,
    // Last 24h of structured connect events (WS open/close, SSH ready,
    // reconnect attempts, diagnostic probes, network/visibility changes).
    // Critical context for connect/reconnect bug reports.
    connectLog: getConnectLogForBugReport(),
    // Last 24h of gesture events (swipe / pinch / long-press / drag-select).
    // For diagnosing "swipes stopped working" bug reports.
    gestureLog: getGestureLogForBugReport(),
  };

  try {
    const res = await fetch('api/bug-report', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json() as { ok: boolean; issueUrl?: string | null };
    if (data.issueUrl) {
      _toast(`Bug filed: ${data.issueUrl}`);
      console.log(`[bug-report] issue created: ${data.issueUrl}`);
    } else {
      _toast('Bug report saved (issue creation pending)');
      console.log('[bug-report] saved locally, gh unavailable');
    }
  } catch (err) {
    console.error('[bug-report] upload failed:', err);
    _toast('Bug report failed — check network');
  }
}
