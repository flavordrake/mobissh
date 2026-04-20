import { describe, it, expect, vi } from 'vitest';

/**
 * Copy All button in text/markdown file preview (#460).
 *
 * The preview UI renders a "Copy All" button in the top-right of text,
 * markdown, and source views. The button carries the RAW source bytes in
 * a base64-encoded data-source attribute so the click handler can call
 * navigator.clipboard.writeText with the original text — NOT the rendered
 * HTML (important for markdown).
 *
 * Image/video previews must NOT include the button.
 */

// Minimal DOM stubs for createPreviewPanel tests (mirrors sftp-preview.test.ts).
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
      innerHTML: '',
      setAttribute: vi.fn(),
      getAttribute: vi.fn(),
      querySelector: vi.fn(() => null),
      querySelectorAll: vi.fn(() => []),
      appendChild: vi.fn(),
      addEventListener: vi.fn(),
      classList: { add: vi.fn(), remove: vi.fn(), toggle: vi.fn() },
      style: {} as Record<string, string>,
    };
    return el;
  }),
});

const { renderPreview, createPreviewPanel } = await import('../sftp-preview.js');

function extractDataSource(html: string): string {
  const match = html.match(/data-source="([^"]*)"/);
  if (!match) throw new Error('data-source attribute not found');
  return match[1]!;
}

function decodeDataSource(encoded: string): string {
  // Inverse of btoa(unescape(encodeURIComponent(...))) — UTF-8 safe.
  return decodeURIComponent(escape(atob(encoded)));
}

describe('#460: Copy All button — presence', () => {
  it('text preview HTML contains .preview-copy-all-btn', () => {
    const html = renderPreview('readme.txt', 'hello world');
    expect(html).toContain('preview-copy-all-btn');
  });

  it('markdown preview HTML contains .preview-copy-all-btn', () => {
    const html = renderPreview('README.md', '# Title\n\nBody text.');
    expect(html).toContain('preview-copy-all-btn');
  });

  it('source view HTML (inside panel innerHTML) contains .preview-copy-all-btn', () => {
    const panel = createPreviewPanel('readme.md', '# Title');
    const html = typeof panel.innerHTML === 'string' ? panel.innerHTML : '';
    // Panel composes tab bar + source + rendered; source view should include the btn
    expect(html).toContain('preview-source');
    expect(html).toContain('preview-copy-all-btn');
  });

  it('image preview HTML does NOT contain .preview-copy-all-btn', () => {
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const html = renderPreview('photo.png', bytes);
    expect(html).not.toContain('preview-copy-all-btn');
  });

  it('video preview HTML does NOT contain .preview-copy-all-btn', () => {
    const bytes = new Uint8Array([0x00, 0x00, 0x00, 0x20]);
    const html = renderPreview('clip.mp4', bytes);
    expect(html).not.toContain('preview-copy-all-btn');
  });
});

describe('#460: Copy All button — attributes', () => {
  it('button has aria-label="Copy all" and a data-source attribute carrying raw text', () => {
    const raw = 'plain text line\nsecond line';
    const html = renderPreview('notes.txt', raw);
    expect(html).toContain('aria-label="Copy all"');
    const decoded = decodeDataSource(extractDataSource(html));
    expect(decoded).toBe(raw);
  });

  it('markdown Copy All carries RAW markdown source, not rendered HTML', () => {
    const raw = '# Heading\n\n- item a\n- item b';
    const html = renderPreview('doc.md', raw);
    // Rendered HTML should contain <h1> (proof we render)
    expect(html).toContain('<h1>');
    // But the data-source must be the raw markdown, not the rendered output
    const decoded = decodeDataSource(extractDataSource(html));
    expect(decoded).toBe(raw);
    expect(decoded).toContain('# Heading');
    expect(decoded).not.toContain('<h1>');
  });

  it('data-source is UTF-8 safe (non-ASCII characters round-trip)', () => {
    const raw = 'café résumé — naïve';
    const html = renderPreview('notes.txt', raw);
    const decoded = decodeDataSource(extractDataSource(html));
    expect(decoded).toBe(raw);
  });
});

describe('#460: Copy All button — click copies raw source', () => {
  it('click handler calls navigator.clipboard.writeText with the decoded raw source', async () => {
    const raw = 'unicode café\nline 2';
    // Simulate the click-handler wiring from ui.ts:
    // 1. Render preview, extract encoded source from data-source attribute.
    // 2. Simulate click: decode and call navigator.clipboard.writeText.
    const html = renderPreview('note.txt', raw);
    const encoded = extractDataSource(html);

    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('navigator', { clipboard: { writeText } });

    // This mirrors the click handler logic that ui.ts will install.
    const clickHandler = async (): Promise<void> => {
      const text = decodeDataSource(encoded);
      await navigator.clipboard.writeText(text);
    };
    await clickHandler();

    expect(writeText).toHaveBeenCalledTimes(1);
    expect(writeText).toHaveBeenCalledWith(raw);
  });
});
