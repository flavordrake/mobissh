// Safe-HTML inliner (#1107).
//
// The hardened HTML viewer (Approach A) never renders a remote page live off a
// server. Instead it fetches the document + every asset it references over the
// session's SFTP and folds them into ONE self-contained document: active
// content stripped, assets inlined as `data:` URIs, and a `default-src 'none'`
// meta-CSP prepended. The viewer then hands that string to a JS-DISABLED WebView
// via `loadHtmlString` (null baseUrl → opaque origin). Result: no origin, no
// socket, no network egress possible; the asset allowlist is implicit (only the
// bytes we inlined exist). This replaces html_loopback_server.dart, which served
// the WHOLE opened SFTP subtree same-origin with no auth — a hostile `.html`
// could `fetch('~/.ssh/id_rsa')` and POST it out. The only capability lost is
// running the page's own JS; read / copy / act need none.
//
// Parsing uses `package:html` (spec-compliant DOM) rather than regex: asset
// extraction from ADVERSARIAL markup must not be fooled by exotic quoting,
// comments, or malformed tags.

import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;

import 'content_types.dart';

/// Fetches the raw bytes of [remotePath] (an absolute POSIX path on the SFTP
/// host). Throws on miss — the caller drops the reference.
typedef AssetFetcher = Future<Uint8List> Function(String remotePath);

/// Per-asset cap (8 MiB — the SftpImageFetcher default). One asset larger than
/// this is dropped rather than ballooning the document.
const int kMaxInlineAssetBytes = 8 * 1024 * 1024;

/// Default ceiling on the total inlined bytes across a document.
const int kDefaultInlineBudget = 24 * 1024 * 1024;

/// The meta-CSP prepended as `<head>`'s first child. `default-src 'none'` plus
/// `connect-src 'none'` means no network of any kind; only `data:` images /
/// media / fonts and inline styles are permitted (everything is already inlined
/// as `data:`). Defense in depth behind the JS-disabled, origin-less WebView.
const String kSafeHtmlCsp =
    "default-src 'none'; script-src 'none'; img-src data:; media-src data:; "
    "font-src data:; style-src 'unsafe-inline' data:; base-uri 'none'; "
    "form-action 'none'; frame-src 'none'; child-src 'none'; "
    "object-src 'none'; connect-src 'none'";

/// Builds a single self-contained, safe-to-render document from [source] (the
/// raw remote HTML at [docRemotePath]). Active content is stripped, referenced
/// assets are inlined as `data:` URIs (resolved against the document's remote
/// directory, traversal-contained), and the meta-CSP is prepended. Assets that
/// are missing, oversized, over [totalInlineBudget], or escape the document's
/// directory are dropped (graceful broken reference — never a network fallback,
/// never a throw).
Future<String> buildSafeHtml({
  required String source,
  required String docRemotePath,
  required AssetFetcher fetchAsset,
  int totalInlineBudget = kDefaultInlineBudget,
}) async {
  final doc = parse(source);
  _stripActiveContent(doc);
  final docDir = _dirnamePosix(docRemotePath);
  final budget = _Budget(totalInlineBudget);
  await _inlineAssets(doc, docDir, fetchAsset, budget);
  _prependCsp(doc);
  return doc.outerHtml;
}

/// Removes scripts, framing/plugin embeds, `<base>`, meta-refresh, resource-hint
/// links, form submission, and every `on*` event-handler attribute.
void _stripActiveContent(Document doc) {
  for (final el in doc.querySelectorAll('script, iframe, object, embed, base')) {
    el.remove();
  }
  for (final meta in doc.querySelectorAll('meta')) {
    if ((meta.attributes['http-equiv'] ?? '').toLowerCase() == 'refresh') {
      meta.remove();
    }
  }
  const badRel = {
    'prefetch',
    'dns-prefetch',
    'preconnect',
    'preload',
    'modulepreload',
  };
  for (final link in doc.querySelectorAll('link')) {
    final rels = (link.attributes['rel'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'));
    if (rels.any(badRel.contains)) link.remove();
  }
  for (final form in doc.querySelectorAll('form')) {
    form.attributes.remove('action');
  }
  for (final el in doc.querySelectorAll('*')) {
    final drop = el.attributes.keys
        .where((k) => _attrName(k).toLowerCase().startsWith('on'))
        .toList();
    for (final k in drop) {
      el.attributes.remove(k);
    }
  }
}

/// Inlines images / media, then stylesheets (`<link>` → `<style>`), then every
/// `<style>` element and inline `style="…url()…"`.
Future<void> _inlineAssets(
  Document doc,
  String docDir,
  AssetFetcher fetch,
  _Budget budget,
) async {
  for (final el in doc.querySelectorAll('img, source, video, audio')) {
    for (final attr in const ['src', 'poster']) {
      if (el.attributes.containsKey(attr)) {
        await _inlineUrlAttr(el, attr, docDir, fetch, budget);
      }
    }
    if (el.attributes.containsKey('srcset')) {
      await _inlineSrcset(el, docDir, fetch, budget);
    }
  }
  for (final link in doc.querySelectorAll('link')) {
    final rels = (link.attributes['rel'] ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'));
    if (!rels.contains('stylesheet')) continue;
    final href = link.attributes['href'];
    final css = href == null ? null : await _fetchText(href, docDir, fetch);
    if (css == null) {
      link.remove();
      continue;
    }
    link.replaceWith(Element.tag('style')..text = css);
  }
  for (final style in doc.querySelectorAll('style')) {
    style.text = await _rewriteCssUrls(style.text, docDir, fetch, budget);
  }
  for (final el in doc.querySelectorAll('*')) {
    final style = el.attributes['style'];
    if (style != null && style.contains('url(')) {
      el.attributes['style'] =
          await _rewriteCssUrls(style, docDir, fetch, budget);
    }
  }
}

Future<void> _inlineUrlAttr(
  Element el,
  String attr,
  String docDir,
  AssetFetcher fetch,
  _Budget budget,
) async {
  final dataUri = await _asDataUri(el.attributes[attr]!, docDir, fetch, budget);
  if (dataUri == null) {
    el.attributes.remove(attr);
  } else {
    el.attributes[attr] = dataUri;
  }
}

Future<void> _inlineSrcset(
  Element el,
  String docDir,
  AssetFetcher fetch,
  _Budget budget,
) async {
  final out = <String>[];
  for (final part in el.attributes['srcset']!.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final fields = trimmed.split(RegExp(r'\s+'));
    final dataUri = await _asDataUri(fields.first, docDir, fetch, budget);
    if (dataUri == null) continue;
    final descriptor = fields.length > 1 ? ' ${fields.sublist(1).join(' ')}' : '';
    out.add('$dataUri$descriptor');
  }
  if (out.isEmpty) {
    el.attributes.remove('srcset');
  } else {
    el.attributes['srcset'] = out.join(', ');
  }
}

/// Rewrites every `url(...)` in [css] to a `data:` URI, or to `about:blank`
/// when it can't be inlined (missing / oversized / escaping / non-SFTP). Never
/// leaves a network reference behind.
Future<String> _rewriteCssUrls(
  String css,
  String docDir,
  AssetFetcher fetch,
  _Budget budget,
) async {
  final re = RegExp('''url\\(\\s*(['"]?)([^'")]+)\\1\\s*\\)''');
  final buf = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(css)) {
    buf.write(css.substring(last, m.start));
    last = m.end;
    final dataUri = await _asDataUri(m.group(2)!.trim(), docDir, fetch, budget);
    buf.write(dataUri == null ? 'url(about:blank)' : 'url($dataUri)');
  }
  buf.write(css.substring(last));
  return buf.toString();
}

/// Fetches [ref] as UTF-8 text (linked stylesheet), or null when it can't be
/// resolved/fetched.
Future<String?> _fetchText(String ref, String docDir, AssetFetcher fetch) async {
  final remote = _resolveAssetPath(docDir, ref);
  if (remote == null) return null;
  try {
    final bytes = await fetch(remote);
    if (bytes.length > kMaxInlineAssetBytes) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Resolves + fetches [ref] and returns a `data:<mime>;base64,…` URI, or null
/// when [ref] is not an inlinable SFTP asset (network/data ref, escapes the doc
/// dir, missing, oversized, or over the total budget).
Future<String?> _asDataUri(
  String ref,
  String docDir,
  AssetFetcher fetch,
  _Budget budget,
) async {
  final remote = _resolveAssetPath(docDir, ref);
  if (remote == null) return null;
  try {
    final bytes = await fetch(remote);
    if (bytes.length > kMaxInlineAssetBytes) return null;
    if (!budget.take(bytes.length)) return null;
    return 'data:${_dataMime(remote)};base64,${base64Encode(bytes)}';
  } catch (_) {
    return null;
  }
}

/// Bare (parameter-free) media type for a `data:` URI — the content-type table
/// with any `; charset=…` stripped. Unknown → octet-stream.
String _dataMime(String path) {
  final full = contentTypeForName(path);
  final semi = full.indexOf(';');
  return semi == -1 ? full : full.substring(0, semi).trim();
}

/// Resolves an asset [ref] against the document's remote directory [docDir],
/// containing it UNDER that directory (mirrors the deleted loopback resolver:
/// `.`/`..` collapse before the containment check, root-absolute refs are
/// relative to the doc dir, escapes / network refs return null). This is the
/// asset allowlist boundary — an `../../.ssh/id_rsa` ref resolves to null and is
/// never fetched.
String? _resolveAssetPath(String docDir, String ref) {
  var s = ref.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('//') ||
      lower.startsWith('data:') ||
      lower.startsWith('blob:') ||
      lower.startsWith('#') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:') ||
      lower.startsWith('javascript:')) {
    return null;
  }
  if (lower.startsWith('file://')) s = s.substring('file://'.length);
  final cut = s.indexOf(RegExp('[?#]'));
  if (cut >= 0) s = s.substring(0, cut);
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  if (s.isEmpty) return null;
  final root = _normalizeAbsolutePosix(
    docDir.startsWith('/') ? docDir : '/$docDir',
  );
  final base = root == '/' ? '' : root;
  final resolved = _normalizeAbsolutePosix('$base/$s');
  if (resolved == root) return null;
  final prefix = root == '/' ? '/' : '$root/';
  if (!resolved.startsWith(prefix)) return null; // traversal escape
  return resolved;
}

/// Collapses `.` / `..` / empty segments in an absolute POSIX path. `..` is
/// clamped at the root (an absolute path cannot escape `/`).
String _normalizeAbsolutePosix(String p) {
  final out = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return '/${out.join('/')}';
}

/// Directory part of an absolute POSIX [path] (`/a/b/c.html` → `/a/b`).
String _dirnamePosix(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '/';
  return path.substring(0, i);
}

/// Inserts the meta-CSP as `<head>`'s first child so it governs the whole
/// document. `parse()` always synthesizes a `<head>`; the fallback is defensive.
void _prependCsp(Document doc) {
  var head = doc.head;
  if (head == null) {
    head = Element.tag('head');
    final html = doc.documentElement;
    if (html != null) {
      html.nodes.insert(0, head);
    } else {
      doc.append(head);
    }
  }
  final meta = Element.tag('meta')
    ..attributes['http-equiv'] = 'Content-Security-Policy'
    ..attributes['content'] = kSafeHtmlCsp;
  head.nodes.insert(0, meta);
}

/// Attribute-map keys are `String` for plain attributes and `AttributeName` for
/// namespaced ones; this reads the local name off either.
String _attrName(Object key) => key is AttributeName ? key.name : key.toString();

/// Running total of inlined bytes against a ceiling.
class _Budget {
  _Budget(this.limit);
  final int limit;
  int _used = 0;
  bool take(int n) {
    if (_used + n > limit) return false;
    _used += n;
    return true;
  }
}
