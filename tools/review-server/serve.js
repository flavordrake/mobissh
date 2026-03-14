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
  nav { display: flex; gap: 1rem; margin-bottom: 1.5rem; flex-wrap: wrap; }
  nav a { padding: 0.4rem 0.8rem; background: var(--card); border-radius: 4px; }
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
</style>
</head>
<body>
<nav>
  <a href="/">Dashboard</a>
  <a href="/emulator">Emulator</a>
  <a href="/appium">Appium</a>
  <a href="/frames">Frames</a>
  <a href="/recordings">Recordings</a>
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
    const d = new Date(stat.mtimeMs);
    // Compact localized: "Mar 14, 10:23 PM" or "Mar 13, 2:05 AM"
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
      + ', ' + d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  } catch { return ''; }
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
    const tests = [];
    function walk(suite) {
      for (const spec of (suite.specs || [])) {
        for (const test of (spec.tests || [])) {
          const result = test.results?.[0];
          tests.push({
            title: spec.title,
            status: result?.status || 'unknown',
            duration: result?.duration || 0,
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

  sections.push(`<div class="card">
    <h2>Emulator (CDP)</h2>
    ${emuTests.length ? `<p>${emuTests.filter(t=>t.status==='passed').length} pass, ${emuTests.filter(t=>t.status==='failed').length} fail, ${emuTests.filter(t=>t.status==='skipped').length} skip</p>` : '<p class="empty">No results</p>'}
    ${fs.existsSync(emuRecording) ? `<p><a href="/file/test-results/emulator/recording.mp4">Recording</a> (${fileTimestamp(emuRecording)})</p>` : ''}
    ${emuFrames.length ? `<p><a href="/frames">${emuFrames.length} frames</a></p>` : ''}
    <p class="meta">Report: ${fs.existsSync(emuReport) ? fileTimestamp(emuReport) : 'none'}</p>
  </div>`);

  // Appium results
  const appiumReport = path.join(ARTIFACT_DIRS.appium, 'results.json');
  const appiumTests = parseSuiteResults(appiumReport);
  sections.push(`<div class="card">
    <h2>Appium</h2>
    ${appiumTests.length ? `<p>${appiumTests.filter(t=>t.status==='passed').length} pass, ${appiumTests.filter(t=>t.status==='failed').length} fail</p>` : '<p class="empty">No results yet</p>'}
    <p class="meta">Report: ${fs.existsSync(appiumReport) ? fileTimestamp(appiumReport) : 'none'}</p>
  </div>`);

  // Test history
  const historyDir = path.join(ARTIFACT_DIRS.history, 'appium');
  const runs = listFiles(historyDir);
  sections.push(`<div class="card">
    <h2>History</h2>
    ${runs.length ? runs.slice(0, 5).map(r => `<p><a href="/history/${r}">${r}</a></p>`).join('') : '<p class="empty">No archived runs</p>'}
  </div>`);

  return html('Dashboard', `<h1>MobiSSH Test Review</h1>${sections.join('')}`);
}

function emulatorPage() {
  const emuReport = path.join(ARTIFACT_DIRS.emulator, 'report.json');
  const tests = parseSuiteResults(emuReport);
  const rows = tests.map(t =>
    `<tr><td class="${t.status}">${t.status === 'passed' ? '+' : t.status === 'failed' ? 'x' : '-'}</td><td>${t.title}</td><td>${(t.duration/1000).toFixed(1)}s</td></tr>`
  ).join('');

  const recording = fs.existsSync(path.join(ARTIFACT_DIRS.emulator, 'recording.mp4'));
  const workflowReport = fs.existsSync(path.join(ARTIFACT_DIRS.emulator, 'workflow-report.html'));

  return html('Emulator Results', `
    <h1>Emulator Results</h1>
    ${recording ? `<div class="card"><h2>Recording</h2><video controls><source src="/file/test-results/emulator/recording.mp4" type="video/mp4"></video></div>` : ''}
    ${workflowReport ? `<p><a href="/file/test-results/emulator/workflow-report.html">Workflow Report</a></p>` : ''}
    <div class="card">
      <h2>Tests</h2>
      ${rows ? `<table><tr><th></th><th>Test</th><th>Time</th></tr>${rows}</table>` : '<p class="empty">No results</p>'}
    </div>
  `);
}

function framesPage() {
  const framesDir = path.join(ARTIFACT_DIRS.emulator, 'frames');
  const frames = listFiles(framesDir, ['.png']);

  if (!frames.length) return html('Frames', '<h1>Video Frames</h1><p class="empty">No frames extracted. Run emulator tests first.</p>');

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
        ${files.map(f => `<div><a href="/file/test-results/emulator/frames/${f}"><img class="thumb" src="/file/test-results/emulator/frames/${f}" alt="${f}" loading="lazy"></a><div class="meta">${f}</div></div>`).join('')}
      </div>
    </div>
  `).join('');

  return html('Frames', `<h1>Video Frames (${frames.length})</h1>${sections}`);
}

function recordingsPage() {
  const recordings = [];

  // Emulator recording
  const emuRec = path.join(ARTIFACT_DIRS.emulator, 'recording.mp4');
  if (fs.existsSync(emuRec)) {
    recordings.push({ name: 'Emulator (latest)', path: '/file/test-results/emulator/recording.mp4', age: fileTimestamp(emuRec), type: 'video/mp4' });
  }

  // Appium recordings from history
  const historyDir = path.join(ARTIFACT_DIRS.history, 'appium');
  for (const run of listFiles(historyDir).slice(0, 10)) {
    const runDir = path.join(historyDir, run);
    for (const f of listFiles(runDir, ['.webm', '.mp4'])) {
      recordings.push({ name: `${run}/${f}`, path: `/file/test-history/appium/${run}/${f}`, age: fileTimestamp(path.join(runDir, f)), type: f.endsWith('.webm') ? 'video/webm' : 'video/mp4' });
    }
  }

  if (!recordings.length) return html('Recordings', '<h1>Recordings</h1><p class="empty">No recordings found.</p>');

  const cards = recordings.map(r => `
    <div class="card">
      <h2>${r.name}</h2>
      <video controls><source src="${r.path}" type="${r.type}"></video>
      <div class="meta">${r.age}</div>
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
    body += videos.map(v => `<div class="card"><h2>${v}</h2><video controls><source src="/file/test-history/appium/${run}/${v}" type="${v.endsWith('.webm') ? 'video/webm' : 'video/mp4'}"></video></div>`).join('');
  }
  if (images.length) {
    body += `<div class="card"><h2>Screenshots</h2><div class="grid">${images.map(f => `<div><a href="/file/test-history/appium/${run}/${f}"><img class="thumb" src="/file/test-history/appium/${run}/${f}" loading="lazy"></a><div class="meta">${f}</div></div>`).join('')}</div></div>`;
  }
  if (htmlFiles.length) {
    body += `<div class="card"><h2>Reports</h2>${htmlFiles.map(f => `<p><a href="/file/test-history/appium/${run}/${f}">${f}</a></p>`).join('')}</div>`;
  }
  if (others.length) {
    body += `<div class="card"><h2>Other</h2>${others.map(f => `<p><a href="/file/test-history/appium/${run}/${f}">${f}</a></p>`).join('')}</div>`;
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
    body += `<div class="card"><h2>Videos</h2>${videos.map(v => `<div style="margin-bottom:1rem"><h2 style="font-size:0.9rem">${v}</h2><video controls style="max-width:100%"><source src="/file/test-results/uploads/${v}"></video><div class="meta">${fileTimestamp(path.join(UPLOAD_DIR, v))}</div></div>`).join('')}</div>`;
  }
  if (images.length) {
    body += `<div class="card"><h2>Screenshots</h2><div class="grid">${images.map(f => `<div><a href="/file/test-results/uploads/${f}"><img class="thumb" src="/file/test-results/uploads/${f}" loading="lazy"></a><div class="meta">${f}<br>${fileTimestamp(path.join(UPLOAD_DIR, f))}</div></div>`).join('')}</div></div>`;
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
    res.end(emulatorPage()); // TODO: separate appium page
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
