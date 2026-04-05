/**
 * modules/bug-report.ts — One-tap bug report: screenshot + logs → GitHub issue
 *
 * Captures the current screen via html2canvas, bundles the debug log,
 * and POSTs to /api/bug-report. The server saves files and creates
 * a GitHub issue with the screenshot and log context.
 */

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

  // Collapse debug panel so it doesn't appear in the screenshot
  const debugPanel = document.getElementById('debugOverlayPanel');
  const debugFab = document.getElementById('debugFab');
  const wasVisible = debugPanel && !debugPanel.classList.contains('hidden');
  if (debugPanel) debugPanel.classList.add('hidden');
  if (debugFab) debugFab.classList.add('hidden');

  _toast('Capturing bug report...');

  // Small delay for panel to hide and toast to render
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

  // Restore debug panel
  if (wasVisible && debugPanel) debugPanel.classList.remove('hidden');
  if (debugFab) debugFab.classList.remove('hidden');

  // Collect metadata
  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-version"]');
  const version = meta?.content ?? 'unknown';

  // Prompt for title
  const title = prompt('Bug title (optional):') ?? '';

  const payload = {
    screenshot,
    logs,
    title: title || `Bug report from device`,
    userAgent: navigator.userAgent,
    url: location.href,
    version,
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
