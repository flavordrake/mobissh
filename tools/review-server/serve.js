#!/usr/bin/env node
/**
 * tools/review-server/serve.js — Test review server
 *
 * Serves emulator recordings, video frames, test screenshots, and reports
 * for mobile review. Server-rendered pages, no client-side SPA.
 *
 * Usage: node tools/review-server/serve.js [--port 9090]
 * Auto-started by scripts/run-emulator-tests.sh and scripts/run-appium-tests.sh
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const PORT = Number(process.env.REVIEW_PORT || process.argv.includes('--port')
  ? process.argv[process.argv.indexOf('--port') + 1]
  : 9090);

const REPO = path.resolve(__dirname, '../..');

// Directories to scan for artifacts
const ARTIFACT_DIRS = {
  emulator: path.join(REPO, 'test-results/emulator'),
  appium: path.join(REPO, 'test-results-appium'),
  headless: path.join(REPO, 'test-results'),
  history: path.join(REPO, 'test-history'),
  reports: {
    emulator: path.join(REPO, 'playwright-report-emulator'),
    appium: path.join(REPO, 'playwright-report-appium'),
    headless: path.join(REPO, 'playwright-report'),
  },
};

// Upload directory for device screenshots/videos
const UPLOAD_DIR = path.join(REPO, 'test-results/uploads');

const MIME = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.svg': 'image/svg+xml',
  '.zip': 'application/zip',
};

function html(title, body) {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} - MobiSSH Review</title>
<style>
  :root { --bg: #1a1b26; --fg: #c0caf5; --accent: #00ff87; --dim: #565f89; --card: #24283b; --err: #f7768e; --warn: #e0af68; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--fg); padding: 1rem; }
  h1 { color: var(--accent); margin-bottom: 1rem; font-size: 1.4rem; }
  h2 { color: var(--accent); margin: 1.5rem 0 0.5rem; font-size: 1.1rem; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  nav { display: flex; gap: 0.3rem; margin: 0 0 1rem; flex-wrap: wrap; }
  nav a { padding: 0.25rem 0.5rem; background: var(--card); border-radius: 3px; font-size: 0.85rem; }
  nav a.active { background: var(--accent); color: var(--bg); font-weight: bold; }
  .card { background: var(--card); border-radius: 6px; padding: 1rem; margin-bottom: 1rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
  .thumb { width: 100%; border-radius: 4px; cursor: pointer; }
  .thumb:hover { outline: 2px solid var(--accent); }
  video { width: 100%; border-radius: 4px; }
  .pass { color: var(--accent); } .fail { color: var(--err); } .skip { color: var(--warn); }
  .meta { color: var(--dim); font-size: 0.85rem; margin-top: 0.3rem; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid var(--card); }
  th { color: var(--dim); font-size: 0.85rem; text-transform: uppercase; }
  .empty { color: var(--dim); font-style: italic; padding: 2rem; text-align: center; }
  .ts { color: var(--dim); font-size: 0.8rem; margin-left: 0.4rem; }
  .fail-row { background: #2d1117; }
  .fail-row td { border-bottom-color: #f8514933; }
  .seek-btn { cursor: pointer; color: var(--accent); font-size: 0.8rem; text-decoration: none;
    padding: 2px 6px; border-radius: 3px; background: #1a2a1a; white-space: nowrap; }
  .seek-btn:hover { background: #253a25; }
  .issue-btn { background: none; border: 1px solid var(--err); color: var(--err); cursor: pointer;
    padding: 2px 8px; border-radius: 3px; font-size: 0.8rem; }
  .issue-btn:hover { background: var(--err); color: var(--bg); }
  .inline-form { display: inline; }
  .filter-tabs { display: flex; gap: 0.3rem; margin-bottom: 0.8rem; }
  .filter-btn { padding: 0.3rem 0.7rem; background: var(--card); border: 1px solid var(--dim);
    color: var(--fg); border-radius: 4px; cursor: pointer; font-size: 0.85rem; }
  .filter-btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); font-weight: bold; }
</style>
</head>
<body>
<nav>
  <a href="/">Dashboard</a>
  <a href="/emulator">Emulator</a>
  <a href="/appium">Appium</a>
  <a href="/frames">Frames</a>
  <a href="/recordings">Recordings</a>
  <a href="/golden">Golden</a>
  <a href="/issues">Issues</a>
  <a href="/upload">Upload</a>
  <a href="/uploads">Uploads</a>
</nav>
${body}
</body>
</html>`;
}

function fileTimestamp(filepath) {
  try {
    const stat = fs.statSync(filepath);
    const ms = (stat.birthtimeMs && stat.birthtimeMs !== stat.mtimeMs)
      ? stat.birthtimeMs : stat.mtimeMs;
    const d = new Date(ms);
    // "Fri Mar 14 20:17"
    const wday = d.toLocaleDateString('en-US', { weekday: 'short' });
    const mon = d.toLocaleDateString('en-US', { month: 'short' });
    const day = d.getDate();
    const time = d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: false });
    return `${wday} ${mon} ${day} ${time}`;
  } catch { return ''; }
}

/** Render a de-emphasized timestamp span for any file link */
function ts(filepath) {
  const t = fileTimestamp(filepath);
  return t ? `<span class="ts">${t}</span>` : '';
}

function listFiles(dir, ext) {
  try {
    return fs.readdirSync(dir)
      .filter(f => !ext || ext.some(e => f.endsWith(e)))
      .sort((a, b) => {
        try { return fs.statSync(path.join(dir, b)).mtimeMs - fs.statSync(path.join(dir, a)).mtimeMs; }
        catch { return 0; }
      });
  } catch { return []; }
}

function parseSuiteResults(reportPath) {
  try {
    const data = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
    const suites = data.suites || [];
    const runStart = data.stats?.startTime || '';
    const tests = [];
    function walk(suite) {
      const suiteName = suite.title || '';
      for (const spec of (suite.specs || [])) {
        for (const test of (spec.tests || [])) {
          const result = test.results?.[0];
          const startTime = result?.startTime || '';
          let videoOffset = null;
          if (runStart && startTime) {
            try {
              videoOffset = (new Date(startTime) - new Date(runStart)) / 1000;
              if (videoOffset < 0) videoOffset = 0;
            } catch {}
          }
          tests.push({
            title: spec.title,
            suite: suiteName,
            status: result?.status || 'unknown',
            duration: result?.duration || 0,
            startTime,
            videoOffset,
            error: result?.error?.message || '',
          });
        }
      }
      for (const child of (suite.suites || [])) walk(child);
    }
    suites.forEach(walk);
    return tests;
  } catch { return []; }
}

// Routes

function dashboardPage() {
  const sections = [];

  // Emulator results
  const emuReport = path.join(ARTIFACT_DIRS.emulator, 'report.json');
  const emuTests = parseSuiteResults(emuReport);
  const emuRecording = path.join(ARTIFACT_DIRS.emulator, 'recording.mp4');
  const emuFrames = listFiles(path.join(ARTIFACT_DIRS.emulator, 'frames'), ['.png']);

  // Count per-test screenshots from Playwright's outputDir
  let perTestScreenshotCount = 0;
  try {
    const ssDir = path.join(REPO, 'test-results/playwright-emulator');
    if (fs.existsSync(ssDir)) {
      for (const d of fs.readdirSync(ssDir)) {
        try {
          if (!fs.statSync(path.join(ssDir, d)).isDirectory()) continue;
          perTestScreenshotCount += fs.readdirSync(path.join(ssDir, d)).filter(f => f.endsWith('.png')).length;
        } catch { /* skip */ }
      }
    }
  } catch { /* ignore */ }

  sections.push(`<div class="card">
    <h2>Emulator (CDP)</h2>
    ${emuTests.length ? `<p>${emuTests.filter(t=>t.status==='passed').length} pass, ${emuTests.filter(t=>t.status==='failed').length} fail, ${emuTests.filter(t=>t.status==='skipped').length} skip</p>` : '<p class="empty">No results</p>'}
    ${fs.existsSync(emuRecording) ? `<p><a href="/file/test-results/emulator/recording.mp4">Recording</a> ${ts(emuRecording)}</p>` : ''}
    ${emuFrames.length ? `<p><a href="/frames">${emuFrames.length} frames</a></p>` : ''}
    ${perTestScreenshotCount ? `<p><a href="/emulator">${perTestScreenshotCount} screenshots</a></p>` : ''}
    <p class="meta">Report: ${fs.existsSync(emuReport) ? `<a href="/emulator">view</a> ${ts(emuReport)}` : 'none'}</p>
  </div>`);

  // Appium results
  const appiumReport = path.join(ARTIFACT_DIRS.appium, 'results.json');
  const appiumTests = parseSuiteResults(appiumReport);
  sections.push(`<div class="card">
    <h2>Appium</h2>
    ${appiumTests.length ? `<p>${appiumTests.filter(t=>t.status==='passed').length} pass, ${appiumTests.filter(t=>t.status==='failed').length} fail</p>` : '<p class="empty">No results yet</p>'}
    <p class="meta">Report: ${fs.existsSync(appiumReport) ? `<a href="/appium">view</a> ${ts(appiumReport)}` : 'none'}</p>
  </div>`);

  // Test history
  const historyDir = path.join(ARTIFACT_DIRS.history, 'appium');
  const runs = listFiles(historyDir);
  sections.push(`<div class="card">
    <h2>History</h2>
    ${runs.length ? runs.slice(0, 5).map(r => `<p><a href="/history/${r}">${r}</a></p>`).join('') : '<p class="empty">No archived runs</p>'}
  </div>`);

  // Action buttons
  const hasResults = fs.existsSync(path.join(ARTIFACT_DIRS.emulator, 'report.json'));
  const actions = hasResults ? `<div class="card" style="display:flex;gap:1rem;flex-wrap:wrap;">
    <form method="POST" action="/mark-golden"><button type="submit" style="padding:0.6rem 1.5rem;background:var(--accent);color:var(--bg);border:none;border-radius:4px;font-weight:bold;cursor:pointer;">Mark Golden</button></form>
    <a href="/file-issue" style="padding:0.6rem 1.5rem;background:var(--err);color:var(--bg);border-radius:4px;font-weight:bold;display:inline-block;">File Issue</a>
  </div>` : '';

  return html('Dashboard', `<h1>MobiSSH Test Review</h1>${actions}${sections.join('')}`);
}

function emulatorPage() {
  const emuReport = path.join(ARTIFACT_DIRS.emulator, 'report.json');
  const tests = parseSuiteResults(emuReport);
  const passed = tests.filter(t => t.status === 'passed').length;
  const failed = tests.filter(t => t.status === 'failed').length;
  const skipped = tests.filter(t => t.status === 'skipped').length;

  function fmtOffset(s) {
    if (s == null) return '';
    const m = Math.floor(s / 60), sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, '0')}`;
  }

  const rows = tests.map((t, i) => {
    const icon = t.status === 'passed' ? '+' : t.status === 'failed' ? 'x' : '-';
    const seekBtn = t.videoOffset != null
      ? `<a class="seek-btn" data-seek="${t.videoOffset.toFixed(1)}" title="Seek video">▶ ${fmtOffset(t.videoOffset)}</a>`
      : '';
    const issueBtn = `<form method="POST" action="/file-test-issue" class="inline-form">
      <input type="hidden" name="index" value="${i}">
      <button type="submit" class="issue-btn" title="File issue for this test">⚑</button>
    </form>`;
    const rowClass = t.status === 'failed' ? ' class="fail-row"' : '';
    return `<tr${rowClass}><td class="${t.status}">${icon}</td><td>${t.title}</td><td>${(t.duration/1000).toFixed(1)}s</td><td>${seekBtn}</td><td>${issueBtn}</td></tr>`;
  }).join('');

  const recording = fs.existsSync(path.join(ARTIFACT_DIRS.emulator, 'recording.mp4'));
  const workflowReport = fs.existsSync(path.join(ARTIFACT_DIRS.emulator, 'workflow-report.html'));

  const actionsEmu = `<div class="card" style="display:flex;gap:1rem;flex-wrap:wrap;align-items:center;">
    <form method="POST" action="/mark-golden"><button type="submit" style="padding:0.6rem 1.5rem;background:var(--accent);color:var(--bg);border:none;border-radius:4px;font-weight:bold;cursor:pointer;">Mark Golden</button></form>
    <a href="/file-issue" style="padding:0.6rem 1.5rem;background:var(--err);color:var(--bg);border-radius:4px;font-weight:bold;display:inline-block;">File Issue (all)</a>
  </div>`;

  const filterTabs = `<div class="filter-tabs">
    <button class="filter-btn active" data-filter="all">All (${tests.length})</button>
    <button class="filter-btn" data-filter="failed">Failed (${failed})</button>
    <button class="filter-btn" data-filter="passed">Passed (${passed})</button>
    ${skipped ? `<button class="filter-btn" data-filter="skipped">Skipped (${skipped})</button>` : ''}
  </div>`;

  // Scan for per-test screenshots in Playwright's outputDir (test-results/playwright-emulator/)
  // Playwright creates subdirs named after test + project, each containing PNGs and traces.
  const testScreenshots = [];
  const playwrightEmuDir = path.join(REPO, 'test-results/playwright-emulator');
  try {
    if (fs.existsSync(playwrightEmuDir)) {
      const dirs = fs.readdirSync(playwrightEmuDir).filter(d => {
        try { return fs.statSync(path.join(playwrightEmuDir, d)).isDirectory(); }
        catch { return false; }
      });
      for (const d of dirs) {
        const pngs = fs.readdirSync(path.join(playwrightEmuDir, d)).filter(f => f.endsWith('.png'));
        if (pngs.length) {
          testScreenshots.push({ dir: d, label: d.replace(/-android-emulator$/, '').replace(/-/g, ' '), files: pngs });
        }
      }
    }
  } catch { /* ignore scan errors */ }

  const screenshotSection = testScreenshots.length ? `<div class="card">
    <h2>Per-Test Screenshots (${testScreenshots.reduce((n, g) => n + g.files.length, 0)})</h2>
    ${testScreenshots.map(g => `
      <h3>${g.label}</h3>
      <div class="grid">
        ${g.files.map(f => `<div><a href="/file/test-results/playwright-emulator/${g.dir}/${f}"><img class="thumb" src="/file/test-results/playwright-emulator/${g.dir}/${f}" alt="${f}" loading="lazy"></a><div class="meta">${f}</div></div>`).join('')}
      </div>
    `).join('')}
  </div>` : '';

  return html('Emulator Results', `
    <h1>Emulator Results</h1>
    ${actionsEmu}
    ${recording ? `<div class="card"><h2>Recording ${ts(path.join(ARTIFACT_DIRS.emulator, 'recording.mp4'))}</h2><video id="recording" controls><source src="/file/test-results/emulator/recording.mp4" type="video/mp4"></video></div>` : ''}
    ${workflowReport ? `<p><a href="/file/test-results/emulator/workflow-report.html">Workflow Report</a> ${ts(path.join(ARTIFACT_DIRS.emulator, 'workflow-report.html'))}</p>` : ''}
    <div class="card">
      <h2>Tests</h2>
      ${filterTabs}
      ${rows ? `<table id="test-table"><tr><th></th><th>Test</th><th>Time</th><th>Video</th><th></th></tr>${rows}</table>` : '<p class="empty">No results</p>'}
    </div>
    ${screenshotSection}
    <script>
    // Filter tabs
    document.querySelectorAll('.filter-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const f = btn.dataset.filter;
        document.querySelectorAll('#test-table tr').forEach((row, i) => {
          if (i === 0) return; // header
          if (f === 'all') { row.style.display = ''; return; }
          const hasClass = row.classList.contains('fail-row');
          if (f === 'failed') row.style.display = hasClass ? '' : 'none';
          else if (f === 'passed') row.style.display = !hasClass && !row.querySelector('.skip') ? '' : 'none';
          else if (f === 'skipped') row.style.display = row.querySelector('.skipped') ? '' : 'none';
        });
      });
    });
    // Seek video
    document.querySelectorAll('.seek-btn').forEach(el => {
      el.addEventListener('click', (e) => {
        e.preventDefault();
        const video = document.getElementById('recording');
        if (!video) return;
        video.scrollIntoView({ behavior: 'smooth', block: 'start' });
        setTimeout(() => { video.currentTime = parseFloat(el.dataset.seek); video.play().catch(()=>{}); }, 400);
      });
    });
    </script>
  `);
}

function appiumPage() {
  const appiumReport = path.join(ARTIFACT_DIRS.appium, 'results.json');
  const tests = parseSuiteResults(appiumReport);
  const rows = tests.map(t =>
    `<tr><td class="${t.status}">${t.status === 'passed' ? '+' : t.status === 'failed' ? 'x' : '-'}</td><td>${t.title}</td><td>${(t.duration/1000).toFixed(1)}s</td></tr>`
  ).join('');

  // Check for recordings in history
  const historyDir = path.join(ARTIFACT_DIRS.history, 'appium');
  const runs = listFiles(historyDir).slice(0, 5);

  return html('Appium Results', `
    <h1>Appium Results</h1>
    <div class="card">
      <h2>Tests</h2>
      ${rows ? `<table><tr><th></th><th>Test</th><th>Time</th></tr>${rows}</table>` : '<p class="empty">No Appium results. Run <code>scripts/run-appium-tests.sh</code></p>'}
    </div>
    ${runs.length ? `<div class="card"><h2>Recent Runs</h2>${runs.map(r => `<p><a href="/history/${r}">${r}</a></p>`).join('')}</div>` : ''}
  `);
}

function framesPage() {
  const framesDir = path.join(ARTIFACT_DIRS.emulator, 'frames');
  const frames = listFiles(framesDir, ['.png']);

  if (!frames.length) return html('Frames', '<h1>Video Frames</h1><p class="empty">No frames extracted. Run emulator tests first.</p>');

  const actionsFrames = `<div class="card" style="display:flex;gap:1rem;flex-wrap:wrap;">
    <form method="POST" action="/mark-golden"><button type="submit" style="padding:0.6rem 1.5rem;background:var(--accent);color:var(--bg);border:none;border-radius:4px;font-weight:bold;cursor:pointer;">Mark Golden</button></form>
    <a href="/file-issue" style="padding:0.6rem 1.5rem;background:var(--err);color:var(--bg);border-radius:4px;font-weight:bold;display:inline-block;">File Issue</a>
  </div>`;

  // Group by test name (filename pattern: testname-N-phase.png)
  const groups = {};
  for (const f of frames) {
    const match = f.match(/^(.+?)-\d+-/);
    const group = match ? match[1] : 'other';
    (groups[group] = groups[group] || []).push(f);
  }

  const sections = Object.entries(groups).map(([name, files]) => `
    <div class="card">
      <h2>${name.replace(/-/g, ' ')}</h2>
      <div class="grid">
        ${files.map(f => `<div><a href="/file/test-results/emulator/frames/${f}"><img class="thumb" src="/file/test-results/emulator/frames/${f}" alt="${f}" loading="lazy"></a><div class="meta">${f} ${ts(path.join(framesDir, f))}</div></div>`).join('')}
      </div>
    </div>
  `).join('');

  return html('Frames', `<h1>Video Frames (${frames.length})</h1>${actionsFrames}${sections}`);
}

function recordingsPage() {
  const recordings = [];

  // Emulator recording
  const emuRec = path.join(ARTIFACT_DIRS.emulator, 'recording.mp4');
  if (fs.existsSync(emuRec)) {
    recordings.push({ name: 'Emulator (latest)', path: '/file/test-results/emulator/recording.mp4', abs: emuRec, type: 'video/mp4' });
  }

  // Appium recordings from history
  const historyDir = path.join(ARTIFACT_DIRS.history, 'appium');
  for (const run of listFiles(historyDir).slice(0, 10)) {
    const runDir = path.join(historyDir, run);
    for (const f of listFiles(runDir, ['.webm', '.mp4'])) {
      recordings.push({ name: `${run}/${f}`, path: `/file/test-history/appium/${run}/${f}`, abs: path.join(runDir, f), type: f.endsWith('.webm') ? 'video/webm' : 'video/mp4' });
    }
  }

  if (!recordings.length) return html('Recordings', '<h1>Recordings</h1><p class="empty">No recordings found.</p>');

  const cards = recordings.map(r => `
    <div class="card">
      <h2>${r.name} ${ts(r.abs)}</h2>
      <video controls><source src="${r.path}" type="${r.type}"></video>
    </div>
  `).join('');

  return html('Recordings', `<h1>Recordings (${recordings.length})</h1>${cards}`);
}

function historyRunPage(run) {
  const runDir = path.join(ARTIFACT_DIRS.history, 'appium', run);
  if (!fs.existsSync(runDir)) return html('Not Found', '<h1>Run not found</h1>');

  const files = listFiles(runDir);
  const videos = files.filter(f => f.endsWith('.webm') || f.endsWith('.mp4'));
  const images = files.filter(f => f.endsWith('.png') || f.endsWith('.jpg'));
  const htmlFiles = files.filter(f => f.endsWith('.html'));
  const others = files.filter(f => !videos.includes(f) && !images.includes(f) && !htmlFiles.includes(f));

  let body = `<h1>Run: ${run}</h1>`;

  if (videos.length) {
    body += videos.map(v => `<div class="card"><h2>${v} ${ts(path.join(runDir, v))}</h2><video controls><source src="/file/test-history/appium/${run}/${v}" type="${v.endsWith('.webm') ? 'video/webm' : 'video/mp4'}"></video></div>`).join('');
  }
  if (images.length) {
    body += `<div class="card"><h2>Screenshots</h2><div class="grid">${images.map(f => `<div><a href="/file/test-history/appium/${run}/${f}"><img class="thumb" src="/file/test-history/appium/${run}/${f}" loading="lazy"></a><div class="meta">${f} ${ts(path.join(runDir, f))}</div></div>`).join('')}</div></div>`;
  }
  if (htmlFiles.length) {
    body += `<div class="card"><h2>Reports</h2>${htmlFiles.map(f => `<p><a href="/file/test-history/appium/${run}/${f}">${f}</a> ${ts(path.join(runDir, f))}</p>`).join('')}</div>`;
  }
  if (others.length) {
    body += `<div class="card"><h2>Other</h2>${others.map(f => `<p><a href="/file/test-history/appium/${run}/${f}">${f}</a> ${ts(path.join(runDir, f))}</p>`).join('')}</div>`;
  }

  return html(`Run ${run}`, body);
}

// Static file serving (sandboxed to repo)
function serveFile(urlPath, res) {
  // /file/test-results/emulator/recording.mp4 -> test-results/emulator/recording.mp4
  const relPath = urlPath.replace(/^\/file\//, '');
  const absPath = path.resolve(REPO, relPath);

  // Security: must be within repo
  if (!absPath.startsWith(REPO + '/')) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  if (!fs.existsSync(absPath)) {
    res.writeHead(404); res.end('Not found'); return;
  }

  const ext = path.extname(absPath);
  const mime = MIME[ext] || 'application/octet-stream';

  // Stream large files (video)
  const stat = fs.statSync(absPath);
  const range = res.req?.headers?.range;

  if (range && (ext === '.mp4' || ext === '.webm')) {
    const parts = range.replace(/bytes=/, '').split('-');
    const start = parseInt(parts[0], 10);
    const end = parts[1] ? parseInt(parts[1], 10) : stat.size - 1;
    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${stat.size}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': end - start + 1,
      'Content-Type': mime,
    });
    fs.createReadStream(absPath, { start, end }).pipe(res);
  } else {
    res.writeHead(200, { 'Content-Type': mime, 'Content-Length': stat.size });
    fs.createReadStream(absPath).pipe(res);
  }
}

function uploadPage() {
  return html('Upload', `
    <h1>Upload Screenshot / Video</h1>
    <div class="card">
      <form method="POST" action="/upload" enctype="multipart/form-data">
        <label>Description (becomes filename):<br>
          <input type="text" name="description" placeholder="e.g. keyboard-covers-input-field" style="width:100%;padding:0.5rem;margin:0.5rem 0;background:var(--bg);color:var(--fg);border:1px solid var(--dim);border-radius:4px;">
        </label><br>
        <label>File:<br>
          <input type="file" name="file" accept="image/*,video/*" style="margin:0.5rem 0;">
        </label><br>
        <button type="submit" style="margin-top:1rem;padding:0.6rem 1.5rem;background:var(--accent);color:var(--bg);border:none;border-radius:4px;font-weight:bold;cursor:pointer;">Upload</button>
      </form>
    </div>
  `);
}

function uploadsPage() {
  fs.mkdirSync(UPLOAD_DIR, { recursive: true });
  const files = listFiles(UPLOAD_DIR, ['.png', '.jpg', '.jpeg', '.webp', '.mp4', '.webm']);

  if (!files.length) return html('Uploads', '<h1>Uploads</h1><p class="empty">No uploads yet.</p>');

  const images = files.filter(f => /\.(png|jpg|jpeg|webp)$/i.test(f));
  const videos = files.filter(f => /\.(mp4|webm)$/i.test(f));

  let body = `<h1>Uploads (${files.length})</h1>`;

  if (videos.length) {
    body += `<div class="card"><h2>Videos</h2>${videos.map(v => `<div style="margin-bottom:1rem"><h2 style="font-size:0.9rem">${v} ${ts(path.join(UPLOAD_DIR, v))}</h2><video controls style="max-width:100%"><source src="/file/test-results/uploads/${v}"></video></div>`).join('')}</div>`;
  }
  if (images.length) {
    body += `<div class="card"><h2>Screenshots</h2><div class="grid">${images.map(f => `<div><a href="/file/test-results/uploads/${f}"><img class="thumb" src="/file/test-results/uploads/${f}" loading="lazy"></a><div class="meta">${f} ${ts(path.join(UPLOAD_DIR, f))}</div></div>`).join('')}</div></div>`;
  }

  return html('Uploads', body);
}

function slugify(str) {
  return str.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').substring(0, 80);
}

function handleUpload(req, res) {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const contentType = req.headers['content-type'] || '';
    const boundary = contentType.split('boundary=')[1];
    if (!boundary) { res.writeHead(400); res.end('Missing boundary'); return; }

    const parts = parseMultipart(body, boundary);
    const descPart = parts.find(p => p.name === 'description');
    const filePart = parts.find(p => p.name === 'file' && p.filename);

    if (!filePart) { res.writeHead(400); res.end('No file'); return; }

    const desc = descPart ? descPart.data.toString('utf8').trim() : '';
    const ext = path.extname(filePart.filename) || '.png';
    const ts = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
    const slug = desc ? slugify(desc) : 'upload';
    const filename = `${ts}-${slug}${ext}`;

    fs.mkdirSync(UPLOAD_DIR, { recursive: true });
    fs.writeFileSync(path.join(UPLOAD_DIR, filename), filePart.data);

    res.writeHead(303, { Location: `/uploads#${filename}` });
    res.end();
  });
}

function parseMultipart(buf, boundary) {
  const sep = Buffer.from(`--${boundary}`);
  const parts = [];
  let pos = 0;

  while (pos < buf.length) {
    const start = buf.indexOf(sep, pos);
    if (start === -1) break;
    const afterSep = start + sep.length;
    if (buf[afterSep] === 0x2d && buf[afterSep + 1] === 0x2d) break; // --boundary--

    const headerEnd = buf.indexOf('\r\n\r\n', afterSep);
    if (headerEnd === -1) break;

    const headers = buf.slice(afterSep + 2, headerEnd).toString('utf8');
    const dataStart = headerEnd + 4;
    const nextBoundary = buf.indexOf(sep, dataStart);
    const dataEnd = nextBoundary === -1 ? buf.length : nextBoundary - 2; // -2 for \r\n

    const nameMatch = headers.match(/name="([^"]+)"/);
    const filenameMatch = headers.match(/filename="([^"]+)"/);

    parts.push({
      name: nameMatch ? nameMatch[1] : null,
      filename: filenameMatch ? filenameMatch[1] : null,
      data: buf.slice(dataStart, dataEnd),
    });
    pos = nextBoundary === -1 ? buf.length : nextBoundary;
  }
  return parts;
}

// ── Archive actions ──────────────────────────────────────────────────────────

const GOLDEN_DIR = path.join(REPO, 'test-history/golden');
const ISSUES_DIR = path.join(REPO, 'test-history/issues');

/** Compact ISO-8601 timestamp for archive directory names. */
function archiveTimestamp() {
  const d = new Date();
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  const tz = -d.getTimezoneOffset();
  const tzSign = tz >= 0 ? '+' : '-';
  const tzH = pad(Math.floor(Math.abs(tz) / 60));
  const tzM = pad(Math.abs(tz) % 60);
  return `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}T${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}${tzSign}${tzH}${tzM}`;
}

/** Git HEAD short hash. */
function gitHash() {
  try { return execSync('git rev-parse --short HEAD', { cwd: REPO, encoding: 'utf8' }).trim(); }
  catch { return 'unknown'; }
}

/** Copy the current emulator test run into a destination directory. Returns the dir path. */
function archiveRun(destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  const src = ARTIFACT_DIRS.emulator;

  // Copy recording
  const rec = path.join(src, 'recording.mp4');
  if (fs.existsSync(rec)) fs.copyFileSync(rec, path.join(destDir, 'recording.mp4'));

  // Copy report.json (readable, not gzipped)
  const report = path.join(src, 'report.json');
  if (fs.existsSync(report)) fs.copyFileSync(report, path.join(destDir, 'report.json'));

  // Copy workflow report
  const workflow = path.join(src, 'workflow-report.html');
  if (fs.existsSync(workflow)) fs.copyFileSync(workflow, path.join(destDir, 'workflow-report.html'));

  // Copy frames directory
  const framesDir = path.join(src, 'frames');
  if (fs.existsSync(framesDir)) {
    const framesDest = path.join(destDir, 'frames');
    fs.mkdirSync(framesDest, { recursive: true });
    for (const f of fs.readdirSync(framesDir)) {
      fs.copyFileSync(path.join(framesDir, f), path.join(framesDest, f));
    }
  }

  // Copy per-test screenshot directories from test-results/
  const testResults = ARTIFACT_DIRS.headless;
  if (fs.existsSync(testResults)) {
    for (const d of fs.readdirSync(testResults)) {
      const full = path.join(testResults, d);
      if (!fs.statSync(full).isDirectory()) continue;
      if (d === 'emulator' || d === 'uploads' || d === '.playwright-artifacts-0') continue;
      const screenshots = fs.readdirSync(full).filter(f => f.endsWith('.png'));
      if (screenshots.length) {
        const sd = path.join(destDir, 'screenshots', d);
        fs.mkdirSync(sd, { recursive: true });
        for (const f of screenshots) {
          fs.copyFileSync(path.join(full, f), path.join(sd, f));
        }
      }
    }
  }

  // Write metadata
  const tests = parseSuiteResults(report);
  const meta = {
    timestamp: new Date().toISOString(),
    git: gitHash(),
    pass: tests.filter(t => t.status === 'passed').length,
    fail: tests.filter(t => t.status === 'failed').length,
    skip: tests.filter(t => t.status === 'skipped').length,
    total: tests.length,
  };
  fs.writeFileSync(path.join(destDir, 'meta.json'), JSON.stringify(meta, null, 2));

  return meta;
}

/** Generate a readable test summary (markdown) from report.json. */
function readableTestSummary(reportPath) {
  const tests = parseSuiteResults(reportPath);
  if (!tests.length) return 'No test results found.';

  const pass = tests.filter(t => t.status === 'passed');
  const fail = tests.filter(t => t.status === 'failed');
  const skip = tests.filter(t => t.status === 'skipped');

  const lines = [`**${pass.length} pass, ${fail.length} fail, ${skip.length} skip** (${tests.length} total)\n`];

  if (fail.length) {
    lines.push('### Failed');
    for (const t of fail) lines.push(`- ${t.title} (${(t.duration/1000).toFixed(1)}s)`);
    lines.push('');
  }
  if (pass.length) {
    lines.push('<details><summary>Passed</summary>\n');
    for (const t of pass) lines.push(`- ${t.title} (${(t.duration/1000).toFixed(1)}s)`);
    lines.push('</details>');
  }

  return lines.join('\n');
}

function handleMarkGolden(req, res) {
  const ts = archiveTimestamp();
  const hash = gitHash();
  const dirName = `${ts}-${hash}`;
  const destDir = path.join(GOLDEN_DIR, dirName);

  const src = path.join(ARTIFACT_DIRS.emulator, 'report.json');
  if (!fs.existsSync(src)) {
    res.writeHead(400, { 'Content-Type': 'text/html' });
    res.end(html('Error', '<h1>No test results</h1><p>Run emulator tests first.</p><p><a href="/">Back</a></p>'));
    return;
  }

  const meta = archiveRun(destDir);

  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(html('Golden Marked', `
    <h1>Golden baseline saved</h1>
    <div class="card">
      <p><strong>Directory:</strong> test-history/golden/${dirName}</p>
      <p><strong>Git:</strong> ${hash}</p>
      <p><strong>Results:</strong> ${meta.pass} pass, ${meta.fail} fail, ${meta.skip} skip</p>
      <p><a href="/golden">View all golden runs</a></p>
    </div>
  `));
}

function handleFileIssue(req, res) {
  // Parse form body for title and description
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const params = new URLSearchParams(body);
    const title = params.get('title') || '';
    const description = params.get('description') || '';

    if (!title.trim()) {
      res.writeHead(400, { 'Content-Type': 'text/html' });
      res.end(html('Error', '<h1>Title required</h1><p><a href="javascript:history.back()">Back</a></p>'));
      return;
    }

    const reportPath = path.join(ARTIFACT_DIRS.emulator, 'report.json');
    if (!fs.existsSync(reportPath)) {
      res.writeHead(400, { 'Content-Type': 'text/html' });
      res.end(html('Error', '<h1>No test results</h1><p>Run emulator tests first.</p><p><a href="/">Back</a></p>'));
      return;
    }

    // Archive the run
    const ts = archiveTimestamp();
    const hash = gitHash();
    const dirName = `${ts}-${hash}`;
    const destDir = path.join(ISSUES_DIR, dirName);
    const meta = archiveRun(destDir);

    // Build issue body
    const testSummary = readableTestSummary(reportPath);
    const issueBody = [
      description ? `${description}\n` : '',
      `## Test Run`,
      `- **Git:** ${hash}`,
      `- **Date:** ${new Date().toISOString()}`,
      `- **Archived:** \`test-history/issues/${dirName}/\``,
      '',
      '## Results',
      testSummary,
      '',
      '## Artifacts',
      `- Recording: \`test-history/issues/${dirName}/recording.mp4\``,
      `- Report: \`test-history/issues/${dirName}/report.json\``,
      meta.fail > 0 ? `- Screenshots: \`test-history/issues/${dirName}/screenshots/\`` : '',
      meta.fail > 0 ? `- Frames: \`test-history/issues/${dirName}/frames/\`` : '',
    ].filter(Boolean).join('\n');

    // Write body to temp file and file the issue
    const bodyFile = path.join('/tmp/mobissh', `issue-testrun-${ts}.md`);
    fs.mkdirSync(path.dirname(bodyFile), { recursive: true });
    fs.writeFileSync(bodyFile, issueBody);

    // Save the dir name so we can link it in the response
    fs.writeFileSync(path.join(destDir, 'issue-body.md'), issueBody);

    let issueUrl = '';
    let ghError = '';
    try {
      issueUrl = execSync(
        `scripts/gh-file-issue.sh --title "${title.replace(/"/g, '\\"')}" --label bug --body-file "${bodyFile}"`,
        { cwd: REPO, encoding: 'utf8', timeout: 30000 }
      ).trim();
    } catch (e) {
      ghError = e.stderr || e.message || 'Unknown error filing issue';
    }

    if (issueUrl) {
      // Write issue URL into the archive for reference
      fs.writeFileSync(path.join(destDir, 'issue-url.txt'), issueUrl);
    }

    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html('Issue Filed', `
      <h1>${issueUrl ? 'Issue filed' : 'Issue filing failed'}</h1>
      <div class="card">
        ${issueUrl
          ? `<p><a href="${issueUrl}">${issueUrl}</a></p>`
          : `<p class="fail">Error: ${ghError}</p><p>Archive saved anyway at <code>test-history/issues/${dirName}/</code></p>`
        }
        <p><strong>Archive:</strong> test-history/issues/${dirName}</p>
        <p><strong>Results:</strong> ${meta.pass} pass, ${meta.fail} fail, ${meta.skip} skip</p>
      </div>
      <div class="card">
        <h2>Issue body</h2>
        <pre style="white-space:pre-wrap;font-size:0.85rem;color:var(--dim)">${issueBody.replace(/</g, '&lt;')}</pre>
      </div>
    `));
  });
}

function handleFileTestIssue(req, res) {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const params = new URLSearchParams(body);
    const index = parseInt(params.get('index') || '0', 10);

    const reportPath = path.join(ARTIFACT_DIRS.emulator, 'report.json');
    if (!fs.existsSync(reportPath)) {
      res.writeHead(400, { 'Content-Type': 'text/html' });
      res.end(html('Error', '<h1>No test results</h1><p><a href="/">Back</a></p>'));
      return;
    }

    const tests = parseSuiteResults(reportPath);
    if (index < 0 || index >= tests.length) {
      res.writeHead(400, { 'Content-Type': 'text/html' });
      res.end(html('Error', '<h1>Invalid test index</h1><p><a href="/emulator">Back</a></p>'));
      return;
    }

    const t = tests[index];
    const hash = gitHash();
    const ts = archiveTimestamp();
    const dirName = `${ts}-${hash}`;
    const destDir = path.join(ISSUES_DIR, dirName);
    const meta = archiveRun(destDir);

    // Format video timestamp
    function fmtOffset(s) {
      if (s == null) return 'N/A';
      const m = Math.floor(s / 60), sec = Math.floor(s % 60);
      return `${m}:${sec.toString().padStart(2, '0')}`;
    }
    const videoStart = fmtOffset(t.videoOffset);
    const endOffset = t.videoOffset != null ? t.videoOffset + t.duration / 1000 : null;
    const videoEnd = fmtOffset(endOffset);

    // Build test-specific readable summary
    const allSummary = readableTestSummary(reportPath);

    const errorSection = t.error
      ? `\n## Error\n\`\`\`\n${t.error.substring(0, 1000)}\n\`\`\`\n`
      : '';

    const issueBody = [
      `## Failed Test`,
      `**${t.title}** (${t.suite})`,
      `- Status: ${t.status}`,
      `- Duration: ${(t.duration / 1000).toFixed(1)}s`,
      `- Video: \`${videoStart}\` → \`${videoEnd}\``,
      '',
      `## Video`,
      `Full recording: \`test-history/issues/${dirName}/recording.mp4\``,
      `Seek to **${videoStart}** for this test.`,
      errorSection,
      `## Full Run Context`,
      `- Git: ${hash}`,
      `- Date: ${new Date().toISOString()}`,
      `- Archive: \`test-history/issues/${dirName}/\``,
      '',
      allSummary,
    ].filter(Boolean).join('\n');

    const titlePrefix = t.status === 'failed' ? 'bug' : 'chore';
    const issueTitle = `${titlePrefix}: ${t.title}`.substring(0, 120);

    const bodyFile = path.join('/tmp/mobissh', `issue-test-${ts}.md`);
    fs.mkdirSync(path.dirname(bodyFile), { recursive: true });
    fs.writeFileSync(bodyFile, issueBody);
    fs.writeFileSync(path.join(destDir, 'issue-body.md'), issueBody);

    let issueUrl = '';
    let ghError = '';
    try {
      issueUrl = execSync(
        `scripts/gh-file-issue.sh --title "${issueTitle.replace(/"/g, '\\"')}" --label bug --body-file "${bodyFile}"`,
        { cwd: REPO, encoding: 'utf8', timeout: 30000 }
      ).trim();
    } catch (e) {
      ghError = e.stderr || e.message || 'Unknown error filing issue';
    }

    if (issueUrl) {
      fs.writeFileSync(path.join(destDir, 'issue-url.txt'), issueUrl);
    }

    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html('Issue Filed', `
      <h1>${issueUrl ? 'Issue filed' : 'Issue filing failed'}</h1>
      <div class="card">
        ${issueUrl
          ? `<p><a href="${issueUrl}">${issueUrl}</a></p>`
          : `<p class="fail">Error: ${ghError}</p>`
        }
        <p><strong>Test:</strong> ${t.title}</p>
        <p><strong>Video:</strong> ${videoStart} → ${videoEnd}</p>
        <p><strong>Archive:</strong> test-history/issues/${dirName}</p>
      </div>
      <div class="card">
        <h2>Issue body</h2>
        <pre style="white-space:pre-wrap;font-size:0.85rem;color:var(--dim)">${issueBody.replace(/</g, '&lt;')}</pre>
      </div>
      <p><a href="/emulator">Back to results</a></p>
    `));
  });
}

function goldenListPage() {
  fs.mkdirSync(GOLDEN_DIR, { recursive: true });
  const runs = listFiles(GOLDEN_DIR).filter(d => {
    try { return fs.statSync(path.join(GOLDEN_DIR, d)).isDirectory(); }
    catch { return false; }
  });

  if (!runs.length) return html('Golden', '<h1>Golden Baselines</h1><p class="empty">No golden runs saved yet.</p>');

  const rows = runs.map(run => {
    const metaPath = path.join(GOLDEN_DIR, run, 'meta.json');
    let meta = {};
    try { meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')); } catch {}
    return `<tr>
      <td><a href="/golden/${run}">${run}</a></td>
      <td>${meta.git || '?'}</td>
      <td class="pass">${meta.pass || 0}</td>
      <td class="fail">${meta.fail || 0}</td>
      <td>${meta.total || 0}</td>
    </tr>`;
  }).join('');

  return html('Golden', `
    <h1>Golden Baselines (${runs.length})</h1>
    <div class="card">
      <table>
        <tr><th>Run</th><th>Git</th><th>Pass</th><th>Fail</th><th>Total</th></tr>
        ${rows}
      </table>
    </div>
  `);
}

function goldenDetailPage(run) {
  const runDir = path.join(GOLDEN_DIR, run);
  if (!fs.existsSync(runDir)) return html('Not Found', '<h1>Golden run not found</h1>');
  return archiveDetailPage(runDir, run, 'golden');
}

function issuesListPage() {
  fs.mkdirSync(ISSUES_DIR, { recursive: true });
  const runs = listFiles(ISSUES_DIR).filter(d => {
    try { return fs.statSync(path.join(ISSUES_DIR, d)).isDirectory(); }
    catch { return false; }
  });

  if (!runs.length) return html('Issues', '<h1>Issue Runs</h1><p class="empty">No issue runs filed yet.</p>');

  const rows = runs.map(run => {
    const metaPath = path.join(ISSUES_DIR, run, 'meta.json');
    const urlPath = path.join(ISSUES_DIR, run, 'issue-url.txt');
    let meta = {};
    let issueUrl = '';
    try { meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')); } catch {}
    try { issueUrl = fs.readFileSync(urlPath, 'utf8').trim(); } catch {}
    return `<tr>
      <td><a href="/issues/${run}">${run}</a></td>
      <td>${meta.git || '?'}</td>
      <td class="pass">${meta.pass || 0}</td>
      <td class="fail">${meta.fail || 0}</td>
      <td>${issueUrl ? `<a href="${issueUrl}">${issueUrl.split('/').pop()}</a>` : '-'}</td>
    </tr>`;
  }).join('');

  return html('Issues', `
    <h1>Issue Runs (${runs.length})</h1>
    <div class="card">
      <table>
        <tr><th>Run</th><th>Git</th><th>Pass</th><th>Fail</th><th>Issue</th></tr>
        ${rows}
      </table>
    </div>
  `);
}

function issuesDetailPage(run) {
  const runDir = path.join(ISSUES_DIR, run);
  if (!fs.existsSync(runDir)) return html('Not Found', '<h1>Issue run not found</h1>');
  return archiveDetailPage(runDir, run, 'issues');
}

/** Shared detail page for golden and issue archives. */
function archiveDetailPage(runDir, run, kind) {
  const metaPath = path.join(runDir, 'meta.json');
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')); } catch {}

  const reportPath = path.join(runDir, 'report.json');
  const tests = parseSuiteResults(reportPath);

  const hasRecording = fs.existsSync(path.join(runDir, 'recording.mp4'));
  const hasWorkflow = fs.existsSync(path.join(runDir, 'workflow-report.html'));
  const issueUrlPath = path.join(runDir, 'issue-url.txt');
  let issueUrl = '';
  try { issueUrl = fs.readFileSync(issueUrlPath, 'utf8').trim(); } catch {}

  const framesDir = path.join(runDir, 'frames');
  const frames = fs.existsSync(framesDir) ? listFiles(framesDir, ['.png']) : [];

  const screenshotsDir = path.join(runDir, 'screenshots');
  const screenshotDirs = fs.existsSync(screenshotsDir)
    ? fs.readdirSync(screenshotsDir).filter(d => {
        try { return fs.statSync(path.join(screenshotsDir, d)).isDirectory(); }
        catch { return false; }
      })
    : [];

  const fileBase = `test-history/${kind}/${run}`;

  const rows = tests.map(t =>
    `<tr><td class="${t.status}">${t.status === 'passed' ? '+' : t.status === 'failed' ? 'x' : '-'}</td><td>${t.title}</td><td>${(t.duration/1000).toFixed(1)}s</td></tr>`
  ).join('');

  let body = `<h1>${kind === 'golden' ? 'Golden' : 'Issue'}: ${run}</h1>`;

  body += `<div class="card">
    <p><strong>Git:</strong> ${meta.git || '?'}</p>
    <p><strong>Date:</strong> ${meta.timestamp || '?'}</p>
    <p><strong>Results:</strong> <span class="pass">${meta.pass || 0} pass</span>, <span class="fail">${meta.fail || 0} fail</span>, ${meta.skip || 0} skip</p>
    ${issueUrl ? `<p><strong>Issue:</strong> <a href="${issueUrl}">${issueUrl}</a></p>` : ''}
    ${hasWorkflow ? `<p><a href="/file/${fileBase}/workflow-report.html">Workflow Report</a></p>` : ''}
  </div>`;

  if (hasRecording) {
    body += `<div class="card"><h2>Recording</h2><video controls><source src="/file/${fileBase}/recording.mp4" type="video/mp4"></video></div>`;
  }

  if (rows) {
    body += `<div class="card"><h2>Tests</h2><table><tr><th></th><th>Test</th><th>Time</th></tr>${rows}</table></div>`;
  }

  if (frames.length) {
    body += `<div class="card"><h2>Frames (${frames.length})</h2><div class="grid">${
      frames.slice(0, 20).map(f => `<div><a href="/file/${fileBase}/frames/${f}"><img class="thumb" src="/file/${fileBase}/frames/${f}" loading="lazy"></a><div class="meta">${f}</div></div>`).join('')
    }</div></div>`;
  }

  if (screenshotDirs.length) {
    for (const sd of screenshotDirs.slice(0, 10)) {
      const pngs = listFiles(path.join(screenshotsDir, sd), ['.png']);
      if (pngs.length) {
        body += `<div class="card"><h2>${sd.replace(/-/g, ' ').substring(0, 60)}</h2><div class="grid">${
          pngs.map(f => `<div><a href="/file/${fileBase}/screenshots/${sd}/${f}"><img class="thumb" src="/file/${fileBase}/screenshots/${sd}/${f}" loading="lazy"></a></div>`).join('')
        }</div></div>`;
      }
    }
  }

  return html(`${kind} ${run}`, body);
}

function fileIssuePage() {
  const reportPath = path.join(ARTIFACT_DIRS.emulator, 'report.json');
  const tests = parseSuiteResults(reportPath);
  const failed = tests.filter(t => t.status === 'failed');
  const hasResults = tests.length > 0;

  // Pre-fill title with failed test names
  const defaultTitle = failed.length
    ? `bug: ${failed.map(t => t.title).join(', ').substring(0, 100)}`
    : 'bug: emulator test failure';

  return html('File Issue', `
    <h1>File Issue from Test Run</h1>
    ${!hasResults ? '<div class="card"><p class="fail">No test results. Run emulator tests first.</p></div>' : `
    <div class="card">
      <p>${tests.filter(t=>t.status==='passed').length} pass, <span class="fail">${failed.length} fail</span></p>
      ${failed.length ? `<ul>${failed.map(t => `<li class="fail">${t.title}</li>`).join('')}</ul>` : ''}
    </div>
    <div class="card">
      <form method="POST" action="/file-issue">
        <label>Title:<br>
          <input type="text" name="title" value="${defaultTitle.replace(/"/g, '&quot;')}" style="width:100%;padding:0.5rem;margin:0.5rem 0;background:var(--bg);color:var(--fg);border:1px solid var(--dim);border-radius:4px;">
        </label><br>
        <label>Description (added to issue body):<br>
          <textarea name="description" rows="4" style="width:100%;padding:0.5rem;margin:0.5rem 0;background:var(--bg);color:var(--fg);border:1px solid var(--dim);border-radius:4px;resize:vertical;" placeholder="Optional context about what was being tested..."></textarea>
        </label><br>
        <button type="submit" style="margin-top:1rem;padding:0.6rem 1.5rem;background:var(--err);color:var(--bg);border:none;border-radius:4px;font-weight:bold;cursor:pointer;">File Issue + Archive Run</button>
      </form>
    </div>
    `}
  `);
}

// Router
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname;

  res.req = req; // for range header access in serveFile

  if (p === '/' || p === '/dashboard') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(dashboardPage());
  } else if (p === '/emulator') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(emulatorPage());
  } else if (p === '/appium') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(appiumPage());
  } else if (p === '/frames') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(framesPage());
  } else if (p === '/recordings') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(recordingsPage());
  } else if (p.startsWith('/history/')) {
    const run = p.replace('/history/', '');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(historyRunPage(run));
  } else if (p === '/mark-golden' && req.method === 'POST') {
    handleMarkGolden(req, res);
  } else if (p === '/file-issue' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(fileIssuePage());
  } else if (p === '/file-issue' && req.method === 'POST') {
    handleFileIssue(req, res);
  } else if (p === '/file-test-issue' && req.method === 'POST') {
    handleFileTestIssue(req, res);
  } else if (p === '/golden') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(goldenListPage());
  } else if (p.startsWith('/golden/')) {
    const run = p.replace('/golden/', '');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(goldenDetailPage(run));
  } else if (p === '/issues') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(issuesListPage());
  } else if (p.startsWith('/issues/')) {
    const run = p.replace('/issues/', '');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(issuesDetailPage(run));
  } else if (p === '/upload' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(uploadPage());
  } else if (p === '/upload' && req.method === 'POST') {
    handleUpload(req, res);
  } else if (p === '/uploads') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(uploadsPage());
  } else if (p.startsWith('/file/')) {
    serveFile(p, res);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/html' });
    res.end(html('Not Found', '<h1>404</h1><p><a href="/">Back to dashboard</a></p>'));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Review server: http://localhost:${PORT}`);
  console.log(`Serving artifacts from: ${REPO}`);
});
