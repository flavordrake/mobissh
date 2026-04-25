/**
 * SFTP quick preview — images, markdown/text, HTML with source/rendered toggle.
 *
 * Pure module: no DI deps, no side effects beyond DOM creation.
 * Security: HTML in sandboxed iframe (no allow-scripts), all text HTML-escaped,
 * blob URLs tracked and revoked on cleanup.
 */

// ── Extension maps ───────────────────────────────────────────────────────────

const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg']);
const VIDEO_EXTS = new Set(['.mp4', '.webm', '.mov', '.m4v']);
const TEXT_EXTS = new Set([
  '.md', '.txt', '.log',
  // Shell / interpreter scripts — preview as plain text
  '.sh', '.bash', '.zsh', '.fish',
  '.bat', '.cmd', '.ps1', '.psm1', '.psd1',
  '.py', '.rb', '.pl', '.lua', '.awk', '.sed',
  // Common config / data text formats
  '.json', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg', '.env',
  // Source files that are useful to peek
  '.js', '.ts', '.jsx', '.tsx', '.css', '.scss', '.xml',
]);
const HTML_EXTS = new Set(['.html', '.htm']);

// ── File type detection ──────────────────────────────────────────────────────

export function isPreviewable(filename: string): boolean {
  return getPreviewType(filename) !== null;
}

export type PreviewType = 'image' | 'video' | 'text' | 'html';

export function getPreviewType(filename: string): PreviewType | null {
  const ext = extOf(filename);
  if (IMAGE_EXTS.has(ext)) return 'image';
  if (VIDEO_EXTS.has(ext)) return 'video';
  if (TEXT_EXTS.has(ext)) return 'text';
  if (HTML_EXTS.has(ext)) return 'html';
  return null;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function toText(data: Uint8Array | string): string {
  if (typeof data === 'string') return data;
  return new TextDecoder().decode(data);
}

export const MIME_MAP: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  // Android Chrome does not play video/quicktime blobs; the majority of .mov
  // files are H.264+AAC inside a QuickTime container that the browser will
  // happily decode if we advertise the blob as video/mp4. If decode still
  // fails the fallback UI kicks in.
  '.mov': 'video/mp4',
  '.m4v': 'video/mp4',
};

/** Extension of a filename including the leading dot, lowercased. Empty if none. */
export function extOf(filename: string): string {
  const dot = filename.lastIndexOf('.');
  if (dot === -1) return '';
  return filename.slice(dot).toLowerCase();
}

/** Attribute markers emitted by renderMarkdown for the preview panel to wire up. */
export const SFTP_INLINE_IMG_ATTR = 'data-sftp-src';
export const SFTP_RELATIVE_LINK_ATTR = 'data-sftp-relative';

/** Track blob URLs created during rendering so cleanup can revoke them. */
let _lastBlobUrls: string[] = [];

// ── Markdown rendering (basic) ───────────────────────────────────────────────

function renderMarkdown(raw: string): string {
  const escaped = escapeHtml(raw);
  const lines = escaped.split('\n');
  const out: string[] = [];
  let inList = false;
  let inCode = false;
  let codeLines: string[] = [];
  let paragraph: string[] = [];

  const flushParagraph = (): void => {
    if (paragraph.length > 0) {
      out.push(`<p>${paragraph.join('\n')}</p>`);
      paragraph = [];
    }
  };

  const flushList = (): void => {
    if (inList) {
      out.push('</ul>');
      inList = false;
    }
  };

  let inTable = false;
  let tableHeader: string[] = [];
  let tableRows: string[][] = [];

  const flushTable = (): void => {
    if (!inTable) return;
    const headerHtml = tableHeader.map(h => `<th>${h}</th>`).join('');
    const rowsHtml = tableRows.map(
      row => `<tr>${row.map(c => `<td>${c}</td>`).join('')}</tr>`
    ).join('\n');
    out.push(`<table>\n<thead><tr>${headerHtml}</tr></thead>\n<tbody>\n${rowsHtml}\n</tbody>\n</table>`);
    inTable = false;
    tableHeader = [];
    tableRows = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;

    // Fenced code blocks
    if (line.match(/^```/)) {
      if (!inCode) {
        flushParagraph();
        flushList();
        flushTable();
        inCode = true;
        codeLines = [];
      } else {
        inCode = false;
        out.push(`<pre><code>${codeLines.join('\n')}</code></pre>`);
      }
      continue;
    }
    if (inCode) {
      codeLines.push(line);
      continue;
    }

    // Table detection: pipe-delimited line followed by separator line (e.g. | --- | --- |)
    if (!inTable && line.match(/^\|.+\|$/) && i + 1 < lines.length && lines[i + 1]!.match(/^\|[\s|:-]+$/)) {
      flushParagraph();
      flushList();
      inTable = true;
      tableHeader = line.split('|').slice(1, -1).map(c => c.trim());
      // Skip the separator line
      i++;
      continue;
    }
    if (inTable) {
      if (line.match(/^\|.+\|$/)) {
        tableRows.push(line.split('|').slice(1, -1).map(c => c.trim()));
        continue;
      } else {
        flushTable();
        // Fall through to process this line normally
      }
    }

    // Headers
    const h3 = line.match(/^### (.+)/);
    if (h3) { flushParagraph(); flushList(); out.push(`<h3>${String(h3[1])}</h3>`); continue; }
    const h2 = line.match(/^## (.+)/);
    if (h2) { flushParagraph(); flushList(); out.push(`<h2>${String(h2[1])}</h2>`); continue; }
    const h1 = line.match(/^# (.+)/);
    if (h1) { flushParagraph(); flushList(); out.push(`<h1>${String(h1[1])}</h1>`); continue; }

    // List items
    const li = line.match(/^- (.+)/);
    if (li) {
      flushParagraph();
      if (!inList) { out.push('<ul>'); inList = true; }
      out.push(`<li>${String(li[1])}</li>`);
      continue;
    }

    // End of list on non-list line
    flushList();

    // Blank line = paragraph break
    if (line.trim() === '') {
      flushParagraph();
      continue;
    }

    paragraph.push(line);
  }

  // Close open blocks
  if (inCode) {
    out.push(`<pre><code>${codeLines.join('\n')}</code></pre>`);
  }
  flushList();
  flushTable();
  flushParagraph();

  // Inline formatting — but skip content inside <pre><code>...</code></pre>
  let html = out.join('\n');
  html = html.replace(
    /(<pre><code>[\s\S]*?<\/code><\/pre>)|`([^`]+)`/g,
    (_match, preBlock?: string, inlineCode?: string) => {
      if (preBlock) return preBlock; // preserve fenced blocks as-is
      return `<code>${inlineCode ?? ''}</code>`;
    }
  );
  html = html.replace(
    /(<pre><code>[\s\S]*?<\/code><\/pre>)|(<code>[^<]*<\/code>)|\*\*([^*]+)\*\*/g,
    (_match, preBlock?: string, inlineCode?: string, boldText?: string) => {
      if (preBlock || inlineCode) return _match;
      return `<strong>${boldText ?? ''}</strong>`;
    }
  );
  // Images first (so `!` isn't stripped by the link pass leaving a stray `!`).
  // Absolute image URLs keep `src` (browser fetches); relative paths become
  // `data-sftp-src` and the preview panel mounts a blob URL after async fetch.
  html = html.replace(
    /(<pre><code>[\s\S]*?<\/code><\/pre>)|(<code>[^<]*<\/code>)|!\[([^\]]*)\]\(([^)]+)\)/g,
    (_match, preBlock?: string, inlineCode?: string, alt?: string, src?: string) => {
      if (preBlock || inlineCode) return _match;
      const url = (src ?? '').trim();
      if (!isSafeMdUrl(url)) return _match;
      if (isAbsoluteUrl(url)) {
        return `<img src="${url}" alt="${alt ?? ''}">`;
      }
      return `<img data-sftp-src="${url}" alt="${alt ?? ''}">`;
    }
  );
  // Links. Absolute URLs (http/https/mailto/etc) open in a new tab; relative
  // paths are tagged so the preview panel's click handler can intercept them
  // and re-enter the SFTP download flow with a resolved path.
  html = html.replace(
    /(<pre><code>[\s\S]*?<\/code><\/pre>)|(<code>[^<]*<\/code>)|\[([^\]]+)\]\(([^)]+)\)/g,
    (_match, preBlock?: string, inlineCode?: string, text?: string, href?: string) => {
      if (preBlock || inlineCode) return _match;
      const url = (href ?? '').trim();
      if (!isSafeMdUrl(url)) return _match;
      if (isAbsoluteUrl(url)) {
        return `<a href="${url}" target="_blank" rel="noopener noreferrer">${text ?? ''}</a>`;
      }
      return `<a href="${url}" data-sftp-relative="true">${text ?? ''}</a>`;
    }
  );
  return html;
}

/** True if the URL has a scheme (http:, https:, mailto:, etc) — browser handles it natively. */
function isAbsoluteUrl(url: string): boolean {
  return /^[a-z][a-z0-9+\-.]*:/i.test(url);
}

/** Scheme-safety check for markdown link/image URLs.
 *  Input is already HTML-escaped; scheme characters (a-z0-9+-.) and ':' pass through unchanged.
 *  Blocks javascript:, vbscript:, data:, file:. Allows everything else (http, https, mailto,
 *  relative paths, absolute paths). */
function isSafeMdUrl(url: string): boolean {
  if (!url) return false;
  const scheme = url.match(/^([a-z][a-z0-9+\-.]*):/i);
  if (!scheme) return true; // no scheme → relative/absolute path, safe
  const blocked = new Set(['javascript', 'vbscript', 'data', 'file']);
  return !blocked.has(scheme[1]!.toLowerCase());
}

// ── Preview rendering ────────────────────────────────────────────────────────

export function renderPreview(filename: string, data: Uint8Array | string): string {
  const type = getPreviewType(filename);
  if (!type) return `<pre>${escapeHtml(toText(data))}</pre>`;

  switch (type) {
    case 'image': {
      const ext = extOf(filename);
      const mime = MIME_MAP[ext] ?? 'application/octet-stream';
      const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
      const blob = new Blob([bytes as BlobPart], { type: mime });
      const url = URL.createObjectURL(blob);
      _lastBlobUrls.push(url);
      return `<img src="${url}" alt="${escapeHtml(filename)}" style="max-width:100%;max-height:80vh;">`;
    }
    case 'video': {
      const ext = extOf(filename);
      const mime = MIME_MAP[ext] ?? 'video/mp4';
      const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
      const blob = new Blob([bytes as BlobPart], { type: mime });
      const url = URL.createObjectURL(blob);
      _lastBlobUrls.push(url);
      // `playsinline` keeps iOS from fullscreen-hijacking. `preload="auto"`
      // nudges Android Chrome to load metadata on mount rather than waiting for
      // a user gesture (blob URLs otherwise stay idle until first tap).
      // Download fallback: many MP4s have the moov atom at the end of the file
      // (ffmpeg default without -movflags faststart) — browsers can't stream
      // those from a blob URL; the save-to-device link lets the user play in a
      // real video app as a fallback.
      // data-blob-url lets the ui.ts video handler rebuild the Blob with an
      // alternate MIME type (e.g. retrying a .mov that refused to load at
      // video/quicktime by re-wrapping as video/mp4) without re-downloading.
      return '<div class="preview-video-wrap">'
        + `<video class="preview-video" controls playsinline webkit-playsinline preload="auto" src="${url}"></video>`
        + '<div class="preview-video-fallback">'
        +   '<div class="preview-video-fallback-msg">In-browser playback failed for this video.</div>'
        +   '<div class="preview-video-fallback-detail"></div>'
        + '</div>'
        + `<a class="preview-video-save" href="${url}" download="${escapeHtml(filename)}">Save to device</a>`
        + '</div>';
    }
    case 'text': {
      const text = toText(data);
      const copyBtn = buildCopyAllBtn(text);
      if (extOf(filename) === '.md') {
        return `<div class="preview-with-copy">${copyBtn}${renderMarkdown(text)}</div>`;
      }
      return `<div class="preview-with-copy">${copyBtn}<pre>${escapeHtml(text)}</pre></div>`;
    }
    case 'html': {
      const html = toText(data);
      const escaped = escapeHtml(html);
      return `<iframe sandbox="allow-same-origin" srcdoc="${escaped}" style="width:100%;height:80vh;border:none;"></iframe>`;
    }
  }
}

// ── Source view with line numbers ────────────────────────────────────────────

function renderSource(data: Uint8Array | string): string {
  const text = toText(data);
  const copyBtn = buildCopyAllBtn(text);
  return `<div class="preview-with-copy">${copyBtn}<pre class="source-view">${escapeHtml(text)}</pre></div>`;
}

/** Build a Copy All button carrying the raw source text as a base64 data attribute.
 *  Base64 (UTF-8 safe) avoids HTML-attribute escaping concerns for multi-line/quoted text. */
function buildCopyAllBtn(rawText: string): string {
  const bytes = new TextEncoder().encode(rawText);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!);
  const encoded = btoa(binary);
  return `<button class="preview-copy-all-btn" aria-label="Copy all" data-source="${encoded}" title="Copy all">Copy All</button>`;
}

// ── Preview panel with source/rendered toggle ────────────────────────────────

interface PreviewPanel extends HTMLElement {
  cleanup(): void;
}

export function createPreviewPanel(
  filename: string,
  data: Uint8Array | string,
  options?: { editable?: boolean },
): PreviewPanel {
  _lastBlobUrls = [];

  const rendered = renderPreview(filename, data);
  const source = renderSource(data);
  const blobUrls = [..._lastBlobUrls];
  const type = getPreviewType(filename);
  const isEditable = (options?.editable ?? false) && (type === 'text' || type === 'html');

  const container = document.createElement('div') as unknown as PreviewPanel;
  container.className = 'sftp-preview-panel';

  // Build the full innerHTML with tab bar + both views.
  // Edit tab sits at the FAR LEFT of the bar (per #523 — leftmost is the
  // most-explicit-action slot). Rendered remains the default active tab.
  const editTab = isEditable
    ? '  <button class="preview-tab" data-tab="edit">Edit</button>'
    : '';
  const editPane = isEditable
    ? [
        '<div class="preview-edit" style="display:none;">',
        '  <div class="preview-edit-toolbar">',
        '    <span class="preview-edit-status" data-status="clean">Saved</span>',
        '    <button type="button" class="preview-edit-btn preview-edit-discard" data-action="discard-edit" title="Discard changes">Revert</button>',
        '    <button type="button" class="preview-edit-btn preview-edit-save" data-action="save-edit" title="Push edits to server">Save</button>',
        '  </div>',
        '  <textarea class="preview-edit-area" spellcheck="false" autocomplete="off" autocorrect="off" autocapitalize="off"></textarea>',
        '</div>',
      ].join('\n')
    : '';

  container.innerHTML = [
    '<div class="preview-tab-bar">',
    editTab,
    '  <button class="preview-tab" data-tab="source">Source</button>',
    '  <button class="preview-tab active" data-tab="rendered">Rendered</button>',
    '</div>',
    editPane,
    '<div class="preview-source" style="display:none;">',
    source,
    '</div>',
    '<div class="preview-rendered">',
    rendered,
    '</div>',
  ].join('');

  // Seed the editable textarea with the current file contents. The textarea
  // owns the editing state; native browser undo (Ctrl+Z / mobile gesture) is
  // available for free. ui.ts wires Save / Revert via data-action attributes.
  if (isEditable) {
    const editArea = container.querySelector<HTMLTextAreaElement>('.preview-edit-area');
    if (editArea) {
      const text = typeof data === 'string' ? data : new TextDecoder().decode(data);
      editArea.value = text;
      editArea.dataset.original = text;
    }
  }

  // Attach cleanup method to revoke blob URLs
  container.cleanup = (): void => {
    for (const url of blobUrls) {
      URL.revokeObjectURL(url);
    }
  };

  return container;
}
