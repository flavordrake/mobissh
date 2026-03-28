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
const TEXT_EXTS = new Set(['.md', '.txt', '.log']);
const HTML_EXTS = new Set(['.html', '.htm']);

function extOf(filename: string): string {
  const dot = filename.lastIndexOf('.');
  if (dot === -1) return '';
  return filename.slice(dot).toLowerCase();
}

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

const MIME_MAP: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.m4v': 'video/mp4',
};

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

  for (const line of lines) {
    // Fenced code blocks
    if (line.match(/^```/)) {
      if (!inCode) {
        flushParagraph();
        flushList();
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
  flushParagraph();

  // Inline formatting on the assembled HTML
  let html = out.join('\n');
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  return html;
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
      return `<video controls src="${url}" style="max-width:100%;max-height:80vh;"></video>`;
    }
    case 'text': {
      const text = toText(data);
      if (extOf(filename) === '.md') {
        return renderMarkdown(text);
      }
      return `<pre>${escapeHtml(text)}</pre>`;
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
  return `<pre class="source-view">${escapeHtml(text)}</pre>`;
}

// ── Preview panel with source/rendered toggle ────────────────────────────────

interface PreviewPanel extends HTMLElement {
  cleanup(): void;
}

export function createPreviewPanel(filename: string, data: Uint8Array | string): PreviewPanel {
  _lastBlobUrls = [];

  const rendered = renderPreview(filename, data);
  const source = renderSource(data);
  const blobUrls = [..._lastBlobUrls];

  const container = document.createElement('div') as unknown as PreviewPanel;
  container.className = 'sftp-preview-panel';

  // Build the full innerHTML with tab bar + both views
  // Default to rendered tab active
  container.innerHTML = [
    '<div class="preview-tab-bar">',
    '  <button class="preview-tab" data-tab="source">Source</button>',
    '  <button class="preview-tab active" data-tab="rendered">Rendered</button>',
    '</div>',
    '<div class="preview-source" style="display:none;">',
    source,
    '</div>',
    '<div class="preview-rendered">',
    rendered,
    '</div>',
  ].join('');

  // Attach cleanup method to revoke blob URLs
  container.cleanup = (): void => {
    for (const url of blobUrls) {
      URL.revokeObjectURL(url);
    }
  };

  return container;
}
