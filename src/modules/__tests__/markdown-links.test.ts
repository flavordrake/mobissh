import { describe, it, expect } from 'vitest';

/**
 * Markdown link + image rendering in SFTP preview.
 *
 * Before this change, `[text](url)` and `![alt](url)` rendered as literal
 * escaped text in the markdown preview. This is the red baseline for:
 *   - Absolute links → <a href target="_blank" rel="noopener noreferrer">
 *   - Relative links → <a href> (points at the SFTP-served URL; broken is fine for now)
 *   - Images → <img src alt>
 *   - Unsafe schemes (javascript:, vbscript:, data:, file:) → stripped, text only
 *   - Links/images inside fenced code blocks are NOT rewritten
 */

import { renderPreview } from '../sftp-preview.js';

function md(source: string): string {
  return renderPreview('doc.md', source);
}

describe('markdown links — absolute URLs', () => {
  it('renders [text](https://...) as an <a> tag with the text', () => {
    const html = md('Click [here](https://example.com) now.');
    expect(html).toContain('<a ');
    expect(html).toContain('href="https://example.com"');
    expect(html).toMatch(/<a[^>]*>here<\/a>/);
  });

  it('absolute links open in a new tab with noopener', () => {
    const html = md('[x](https://example.com)');
    expect(html).toContain('target="_blank"');
    expect(html).toContain('rel="noopener noreferrer"');
  });

  it('http and mailto schemes are allowed', () => {
    const http = md('[x](http://example.com)');
    expect(http).toContain('href="http://example.com"');
    const mail = md('[x](mailto:a@b.com)');
    expect(mail).toContain('href="mailto:a@b.com"');
  });

  it('does NOT render [text](url) as literal text', () => {
    const html = md('[readme](./README.md)');
    expect(html).not.toMatch(/\[readme\]\(\.\/README\.md\)/);
  });

  it('multiple links on the same line all render', () => {
    const html = md('See [a](https://a.com) and [b](https://b.com).');
    expect((html.match(/<a /g) ?? []).length).toBe(2);
    expect(html).toContain('href="https://a.com"');
    expect(html).toContain('href="https://b.com"');
  });
});

describe('markdown links — relative URLs (SFTP-served)', () => {
  it('renders [text](./file.md) as an <a> tag', () => {
    const html = md('[readme](./README.md)');
    expect(html).toContain('<a ');
    expect(html).toMatch(/<a[^>]*>readme<\/a>/);
  });

  it('relative href is preserved (same as source)', () => {
    const html = md('[x](./folder/file.txt)');
    expect(html).toContain('href="./folder/file.txt"');
    const parent = md('[x](../sibling.md)');
    expect(parent).toContain('href="../sibling.md"');
  });

  it('absolute-path relative link is preserved', () => {
    const html = md('[x](/var/log/app.log)');
    expect(html).toContain('href="/var/log/app.log"');
  });
});

describe('markdown links — security', () => {
  it('javascript: scheme is stripped — renders as plain text, no <a>', () => {
    const html = md('[xss](javascript:alert(1))');
    expect(html).not.toContain('<a ');
    expect(html).not.toMatch(/href="javascript:/i);
    // The visible text should still be there
    expect(html).toContain('xss');
  });

  it('vbscript: scheme is stripped', () => {
    const html = md('[xss](vbscript:msgbox)');
    expect(html).not.toContain('<a ');
    expect(html).not.toMatch(/href="vbscript:/i);
  });

  it('file: scheme is stripped', () => {
    const html = md('[leak](file:///etc/passwd)');
    expect(html).not.toContain('<a ');
    expect(html).not.toMatch(/href="file:/i);
  });

  it('data: scheme is stripped from links', () => {
    const html = md('[x](data:text/html,<script>alert(1)</script>)');
    expect(html).not.toContain('<a ');
    expect(html).not.toMatch(/href="data:/i);
  });

  it('scheme check is case-insensitive', () => {
    const html = md('[x](JavaScript:alert(1))');
    expect(html).not.toContain('<a ');
  });
});

describe('markdown images', () => {
  it('renders ![alt](https://...) as an <img> tag', () => {
    const html = md('![logo](https://example.com/logo.png)');
    expect(html).toContain('<img ');
    expect(html).toContain('src="https://example.com/logo.png"');
    expect(html).toContain('alt="logo"');
  });

  it('renders ![alt](./pic.png) with relative src (SFTP-served)', () => {
    const html = md('![screenshot](./screenshot.png)');
    expect(html).toContain('<img ');
    expect(html).toContain('src="./screenshot.png"');
    expect(html).toContain('alt="screenshot"');
  });

  it('image with empty alt renders with alt=""', () => {
    const html = md('![](./pic.png)');
    expect(html).toContain('<img ');
    expect(html).toContain('alt=""');
  });

  it('javascript: scheme is stripped from image src', () => {
    const html = md('![x](javascript:alert(1))');
    expect(html).not.toContain('<img ');
    expect(html).not.toMatch(/src="javascript:/i);
  });

  it('does NOT render ![alt](src) as literal text', () => {
    const html = md('![logo](./logo.png)');
    expect(html).not.toMatch(/!\[logo\]\(\.\/logo\.png\)/);
  });

  it('image before a regular link does not trip link detection', () => {
    const html = md('![pic](./a.png) and [text](./b.md)');
    expect(html).toContain('<img ');
    expect(html).toContain('src="./a.png"');
    // The link after the image should still render
    expect(html).toContain('<a ');
    expect(html).toContain('href="./b.md"');
  });
});

describe('markdown links/images — code block isolation', () => {
  it('links inside fenced code blocks are NOT rewritten', () => {
    const src = '```\n[not a link](./x.md)\n```';
    const html = md(src);
    // The raw text (escaped) should be inside <pre><code>, not converted to <a>
    const preMatch = html.match(/<pre><code>([\s\S]*?)<\/code><\/pre>/);
    expect(preMatch).toBeTruthy();
    expect(preMatch![1]).toContain('[not a link](./x.md)');
    // And there should be no <a> tag anywhere (no other links in source)
    expect(html).not.toContain('<a ');
  });

  it('images inside fenced code blocks are NOT rewritten', () => {
    const src = '```\n![not an image](./x.png)\n```';
    const html = md(src);
    const preMatch = html.match(/<pre><code>([\s\S]*?)<\/code><\/pre>/);
    expect(preMatch).toBeTruthy();
    expect(preMatch![1]).toContain('![not an image](./x.png)');
    expect(html).not.toContain('<img ');
  });

  it('inline code backticks do not swallow links on the same line', () => {
    const html = md('Use `foo` then see [docs](https://example.com).');
    expect(html).toContain('<code>foo</code>');
    expect(html).toContain('<a ');
    expect(html).toContain('href="https://example.com"');
  });
});

describe('markdown links — escaping', () => {
  it('link text is HTML-escaped (no <script> leak)', () => {
    const html = md('[<script>bad</script>](https://example.com)');
    expect(html).not.toMatch(/<script>bad<\/script>/);
    expect(html).toContain('&lt;script&gt;');
  });

  it('ampersands in URL are preserved as &amp; (valid in href)', () => {
    const html = md('[x](https://example.com?a=1&b=2)');
    // After escapeHtml, & becomes &amp; which is the correct form inside an href attribute
    expect(html).toMatch(/href="https:\/\/example\.com\?a=1&amp;b=2"/);
  });

  it('double-quote in URL cannot break out of href attribute', () => {
    const html = md('[x](https://evil.com" onerror="alert(1))');
    // Safe rendering: " in the URL is encoded as &quot;, so the literal string
    // `" onerror="` (which would indicate an attribute break-out) never appears.
    expect(html).not.toContain('" onerror="');
  });
});
