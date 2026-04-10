import { describe, it, expect, beforeEach, vi } from 'vitest';

/**
 * TDD red baseline for SFTP quick preview (#370).
 *
 * Tests define the expected API surface for file preview:
 * - File type detection (isPreviewable, getPreviewType)
 * - Preview rendering (renderPreview)
 * - Source/rendered toggle panel (createPreviewPanel)
 * - Security constraints (sandbox, CSP, blob URL revocation)
 *
 * These tests import from '../sftp-preview.js' which does not exist yet.
 * They MUST fail until the feature is implemented.
 */

// Minimal DOM stubs for createPreviewPanel tests
vi.stubGlobal('URL', class {
  constructor(public href: string) {}
  static createObjectURL = vi.fn(() => 'blob:http://localhost/fake-blob-id');
  static revokeObjectURL = vi.fn();
});
vi.stubGlobal('Blob', class {
  constructor(public parts: unknown[], public options?: { type?: string }) {}
});
vi.stubGlobal('document', {
  createElement: vi.fn((tag: string) => {
    const el: Record<string, unknown> = {
      tagName: tag.toUpperCase(),
      className: '',
      textContent: '',
      innerHTML: '',
      id: '',
      children: [] as unknown[],
      childNodes: [] as unknown[],
      setAttribute: vi.fn(),
      getAttribute: vi.fn((attr: string) => (el as Record<string, unknown>)[`_attr_${attr}`] ?? null),
      appendChild: vi.fn((child: unknown) => { (el.children as unknown[]).push(child); return child; }),
      addEventListener: vi.fn(),
      querySelector: vi.fn(() => null),
      querySelectorAll: vi.fn(() => []),
      remove: vi.fn(),
      classList: {
        add: vi.fn(),
        remove: vi.fn(),
        toggle: vi.fn(),
        contains: vi.fn(() => false),
      },
      style: {} as Record<string, string>,
      dataset: {} as Record<string, string>,
    };
    // Track setAttribute calls so getAttribute can return them
    (el.setAttribute as ReturnType<typeof vi.fn>).mockImplementation((attr: string, val: string) => {
      (el as Record<string, unknown>)[`_attr_${attr}`] = val;
    });
    return el;
  }),
});

import {
  isPreviewable,
  getPreviewType,
  renderPreview,
  createPreviewPanel,
} from '../sftp-preview.js';

// --- 1. File type detection ---

describe('isPreviewable', () => {
  it.each([
    'photo.png', 'image.jpg', 'pic.jpeg', 'anim.gif', 'hero.webp', 'logo.svg',
    'README.md', 'notes.txt', 'server.log', 'page.html', 'doc.htm',
  ])('returns true for previewable file: %s', (filename) => {
    expect(isPreviewable(filename)).toBe(true);
  });

  it.each([
    'archive.bin', 'backup.zip', 'data.tar', 'manual.pdf', 'video.mp4', 'app.exe',
  ])('returns false for non-previewable file: %s', (filename) => {
    expect(isPreviewable(filename)).toBe(false);
  });

  it('is case-insensitive for extensions', () => {
    expect(isPreviewable('PHOTO.PNG')).toBe(true);
    expect(isPreviewable('readme.MD')).toBe(true);
    expect(isPreviewable('page.HTML')).toBe(true);
  });
});

describe('getPreviewType', () => {
  it.each([
    ['photo.png', 'image'],
    ['pic.jpg', 'image'],
    ['pic.jpeg', 'image'],
    ['anim.gif', 'image'],
    ['hero.webp', 'image'],
    ['logo.svg', 'image'],
  ])('returns "image" for %s', (filename, expected) => {
    expect(getPreviewType(filename)).toBe(expected);
  });

  it.each([
    ['README.md', 'text'],
    ['notes.txt', 'text'],
    ['server.log', 'text'],
  ])('returns "text" for %s', (filename, expected) => {
    expect(getPreviewType(filename)).toBe(expected);
  });

  it.each([
    ['page.html', 'html'],
    ['doc.htm', 'html'],
  ])('returns "html" for %s', (filename, expected) => {
    expect(getPreviewType(filename)).toBe(expected);
  });

  it.each([
    'archive.bin', 'backup.zip', 'data.tar', 'manual.pdf', 'video.mp4', 'app.exe',
  ])('returns null for non-previewable file: %s', (filename) => {
    expect(getPreviewType(filename)).toBeNull();
  });
});

// --- 2. Preview rendering API ---

describe('renderPreview', () => {
  it('returns an <img> tag with blob URL for image files', () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG header bytes
    const html = renderPreview('photo.png', data);
    expect(html).toContain('<img');
    expect(html).toContain('blob:');
  });

  it('returns rendered HTML for markdown files (headers)', () => {
    const md = new TextEncoder().encode('# Hello World\n\nSome text');
    const html = renderPreview('README.md', md);
    expect(html).toContain('<h1');
    expect(html).toContain('Hello World');
  });

  it('returns rendered HTML for markdown files (lists)', () => {
    const md = new TextEncoder().encode('- item one\n- item two\n- item three');
    const html = renderPreview('notes.md', md);
    expect(html).toContain('<li');
    expect(html).toContain('item one');
  });

  it('returns rendered HTML for markdown files (code blocks)', () => {
    const md = new TextEncoder().encode('```js\nconst x = 1;\n```');
    const html = renderPreview('example.md', md);
    expect(html).toContain('<code');
    expect(html).toContain('const x = 1;');
  });

  it('returns <pre> with escaped content for text/log files', () => {
    const text = new TextEncoder().encode('line 1\nline 2\n<script>alert("xss")</script>');
    const html = renderPreview('server.log', text);
    expect(html).toContain('<pre');
    expect(html).toContain('line 1');
    expect(html).toContain('&lt;script&gt;'); // HTML-escaped
    expect(html).not.toContain('<script>');
  });

  it('returns sandboxed iframe with srcdoc for HTML files', () => {
    const htmlContent = new TextEncoder().encode('<h1>Hello</h1><p>World</p>');
    const html = renderPreview('page.html', htmlContent);
    expect(html).toContain('iframe');
    expect(html).toContain('srcdoc');
  });

  it('iframe sandbox includes allow-same-origin but NOT allow-scripts', () => {
    const htmlContent = new TextEncoder().encode('<p>Safe content</p>');
    const html = renderPreview('page.html', htmlContent);
    expect(html).toContain('sandbox');
    expect(html).toContain('allow-same-origin');
    expect(html).not.toMatch(/allow-scripts/);
  });
});

// --- 3. Source/rendered toggle ---

describe('createPreviewPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('returns a DOM element', () => {
    const data = new TextEncoder().encode('# Hello');
    const panel = createPreviewPanel('README.md', data);
    expect(panel).toBeDefined();
    expect(panel).toHaveProperty('appendChild');
  });

  it('has a tab bar with Source and Rendered tabs', () => {
    const data = new TextEncoder().encode('# Hello');
    const panel = createPreviewPanel('README.md', data);
    // The panel should contain tab elements; check via innerHTML or children
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    // At minimum the panel structure should reference both tabs
    expect(html).toMatch(/source/i);
    expect(html).toMatch(/rendered/i);
  });

  it('Source tab shows raw text with line numbers', () => {
    const data = new TextEncoder().encode('line one\nline two\nline three');
    const panel = createPreviewPanel('notes.txt', data);
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    // Source view should contain line numbers
    expect(html).toContain('1');
    expect(html).toContain('2');
    expect(html).toContain('3');
    expect(html).toContain('line one');
  });

  it('Rendered tab shows the rendered preview', () => {
    const data = new TextEncoder().encode('# Title\n\nParagraph text');
    const panel = createPreviewPanel('doc.md', data);
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    expect(html).toContain('Title');
  });

  it('default tab for images is rendered', () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const panel = createPreviewPanel('photo.png', data);
    // The rendered tab should be active/visible by default for images
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    expect(html).toContain('<img');
  });

  it('default tab for text files is rendered', () => {
    const data = new TextEncoder().encode('plain text content');
    const panel = createPreviewPanel('notes.txt', data);
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    expect(html).toContain('<pre');
  });

  it('default tab for markdown is rendered', () => {
    const data = new TextEncoder().encode('# Heading');
    const panel = createPreviewPanel('README.md', data);
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    expect(html).toContain('<h1');
  });

  it('default tab for HTML is rendered', () => {
    const data = new TextEncoder().encode('<p>Hello</p>');
    const panel = createPreviewPanel('page.html', data);
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    expect(html).toContain('iframe');
  });
});

// --- 4. Security ---

describe('Security constraints', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('HTML preview iframe has sandbox attribute without allow-scripts', () => {
    const data = new TextEncoder().encode('<script>alert(1)</script><p>Safe</p>');
    const html = renderPreview('evil.html', data);
    // Must have sandbox
    expect(html).toContain('sandbox=');
    // Must NOT allow scripts
    expect(html).not.toMatch(/allow-scripts/);
  });

  it('HTML preview does not load external resources (no allow-top-navigation)', () => {
    const data = new TextEncoder().encode('<img src="https://evil.com/track.png">');
    const html = renderPreview('phishing.html', data);
    expect(html).toContain('sandbox=');
    // Sandbox without allow-same-origin + allow-scripts effectively blocks external loads
    // but we explicitly require allow-same-origin for srcdoc, so verify no allow-top-navigation
    expect(html).not.toMatch(/allow-top-navigation/);
  });

  it('image blob URLs are created via URL.createObjectURL', () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    renderPreview('photo.png', data);
    expect(URL.createObjectURL).toHaveBeenCalled();
  });

  it('createPreviewPanel provides a cleanup mechanism for blob URLs', () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const panel = createPreviewPanel('photo.png', data);
    // Panel should expose a destroy/cleanup method or auto-revoke on remove
    // We check that the panel has a cleanup function
    expect(typeof (panel as unknown as Record<string, unknown>).destroy === 'function'
      || typeof (panel as unknown as Record<string, unknown>).cleanup === 'function'
      || typeof (panel as unknown as Record<string, unknown>).close === 'function').toBe(true);
  });

  it('cleanup revokes blob URLs via URL.revokeObjectURL', () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const panel = createPreviewPanel('photo.png', data) as unknown as Record<string, (...args: unknown[]) => void>;
    // Call whichever cleanup method exists
    const cleanupFn = panel.destroy ?? panel.cleanup ?? panel.close;
    if (typeof cleanupFn === 'function') {
      cleanupFn();
    }
    expect(URL.revokeObjectURL).toHaveBeenCalled();
  });
});

// --- 5. Issue #410 regression tests ---

describe('renderMarkdown — issue #410 regressions', () => {
  it('fenced code blocks produce <pre><code> with content intact', () => {
    const md = '```\nconst x = 1;\nlet y = 2;\n```';
    const html = renderPreview('test.md', md);
    expect(html).toContain('<pre><code>');
    expect(html).toContain('const x = 1;');
    expect(html).toContain('let y = 2;');
  });

  it('inline backtick does not corrupt fenced code block content', () => {
    const md = '```\nconst `x` = 1;\n```\n\nUse `foo` inline.';
    const html = renderPreview('test.md', md);
    // The fenced block should NOT have <code> injected inside <pre><code>
    // Count <code> occurrences: one from <pre><code> and one from inline `foo`
    const codeMatches = html.match(/<code>/g);
    expect(codeMatches).toBeTruthy();
    // The inline `foo` should become <code>foo</code>
    expect(html).toContain('<code>foo</code>');
    // The fenced block content should not have nested <code> tags
    const preBlock = html.match(/<pre><code>([\s\S]*?)<\/code><\/pre>/);
    expect(preBlock).toBeTruthy();
    // Inside the pre block, backtick-wrapped text should remain as literal backticks
    expect(preBlock![1]).toContain('`x`');
  });

  it('renders pipe-delimited tables as <table> HTML', () => {
    const md = '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |';
    const html = renderPreview('test.md', md);
    expect(html).toContain('<table>');
    expect(html).toContain('<th>');
    expect(html).toContain('Name');
    expect(html).toContain('Age');
    expect(html).toContain('<td>');
    expect(html).toContain('Alice');
    expect(html).toContain('30');
    expect(html).toContain('Bob');
  });

  it('table without separator line is not rendered as table', () => {
    const md = '| not | a | table |\n\nJust text.';
    const html = renderPreview('test.md', md);
    expect(html).not.toContain('<table>');
  });

  it('bold text inside paragraphs renders as <strong>', () => {
    const md = 'This is **bold** text.';
    const html = renderPreview('test.md', md);
    expect(html).toContain('<strong>bold</strong>');
  });
});
