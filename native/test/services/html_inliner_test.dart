// Unit tests for the safe-HTML inliner (#1107).
//
// The hardened HTML viewer (Approach A) renders a single self-contained
// document: active content stripped, referenced assets inlined as `data:` URIs
// against the document's remote directory (traversal-contained), and a
// `default-src 'none'` meta-CSP prepended. There is no origin, no socket, no
// network egress — so a hostile remote `.html` can no longer read `~/.ssh/id_rsa`
// same-origin and POST it out (the loopback server that made that possible is
// gone). These tests pin the strip + inline + containment + CSP contract on the
// pure builder, which needs no WebView / platform channel.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' show parse;
import 'package:mobissh/services/html_inliner.dart';

/// Records every remote path requested and answers canned bytes for known
/// paths (throws for anything else — the "missing asset" path).
class _RecordingFetcher {
  final List<String> requested = [];
  final Map<String, Uint8List> byPath;
  _RecordingFetcher(this.byPath);

  Future<Uint8List> call(String remotePath) async {
    requested.add(remotePath);
    final bytes = byPath[remotePath];
    if (bytes == null) throw Exception('no such file: $remotePath');
    return bytes;
  }
}

void main() {
  const docPath = '/home/u/site/index.html';
  final pngBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4]);

  test('strips script/iframe/object/embed/base/meta-refresh/prefetch-link', () async {
    final fetcher = _RecordingFetcher({});
    const source = '''
<html><head>
  <base href="http://evil/">
  <meta http-equiv="refresh" content="0;url=http://evil/">
  <link rel="prefetch" href="http://evil/x">
  <link rel="preload" href="http://evil/y">
</head><body>
  <script>fetch('/home/u/.ssh/id_rsa')</script>
  <iframe src="http://evil/frame"></iframe>
  <object data="http://evil/o"></object>
  <embed src="http://evil/e">
  <p>visible</p>
</body></html>''';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out, isNot(contains('<script')));
    expect(out, isNot(contains('<iframe')));
    expect(out, isNot(contains('<object')));
    expect(out, isNot(contains('<embed')));
    expect(out, isNot(contains('<base')));
    expect(out.toLowerCase(), isNot(contains('http-equiv="refresh"')));
    expect(out, isNot(contains('rel="prefetch"')));
    expect(out, isNot(contains('rel="preload"')));
    expect(out, contains('visible'));
  });

  test('strips on* event-handler attributes on every element', () async {
    final fetcher = _RecordingFetcher({});
    const source =
        '<html><body><div onclick="steal()" onmouseover="x()">hi</div>'
        '<button ONCLICK="y()">b</button></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out.toLowerCase(), isNot(contains('onclick')));
    expect(out.toLowerCase(), isNot(contains('onmouseover')));
    expect(out, contains('hi'));
  });

  test('inlines a relative <img src> as a data: URI', () async {
    final fetcher = _RecordingFetcher({'/home/u/site/logo.png': pngBytes});
    const source = '<html><body><img src="logo.png"></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    final b64 = base64Encode(pngBytes);
    expect(out, contains('data:image/png;base64,$b64'));
    expect(fetcher.requested, contains('/home/u/site/logo.png'));
  });

  test('missing asset drops the src attribute (no crash, no network ref)', () async {
    final fetcher = _RecordingFetcher({}); // every fetch throws
    const source = '<html><body><img src="gone.png"></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out, isNot(contains('gone.png')));
    expect(out, contains('<img'));
  });

  test('a remote http img src is neutralized (never a network reference)', () async {
    final fetcher = _RecordingFetcher({});
    const source =
        '<html><body><img src="http://attacker/x?exfil=1"></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out, isNot(contains('http://attacker')));
    // and no attempt was made to fetch it over SFTP either
    expect(fetcher.requested, isEmpty);
  });

  test('output carries the default-src none / connect-src none meta-CSP', () async {
    final fetcher = _RecordingFetcher({});
    const source = '<html><body><p>x</p></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out, contains('Content-Security-Policy'));
    expect(out, contains("default-src 'none'"));
    expect(out, contains("connect-src 'none'"));
    expect(out, contains("script-src 'none'"));
    expect(out, contains("base-uri 'none'"));
  });

  test('the CSP meta is the first element child of <head>', () async {
    final fetcher = _RecordingFetcher({});
    const source =
        '<html><head><title>t</title></head><body><p>x</p></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    final head = parse(out).head!;
    final first = head.children.first;
    expect(first.localName, 'meta');
    expect(first.attributes['http-equiv'], 'Content-Security-Policy');
  });

  test('an ../../.ssh/id_rsa reference never resolves outside the doc dir', () async {
    final fetcher = _RecordingFetcher({});
    const source =
        '<html><body><img src="../../.ssh/id_rsa"></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    // The escaping path must never reach the fetcher, and every path that DOES
    // must stay under the document's directory (the old loopback containment
    // guarantee, preserved).
    expect(
      fetcher.requested,
      everyElement(startsWith('/home/u/site/')),
    );
    expect(fetcher.requested, isNot(contains('/home/.ssh/id_rsa')));
    expect(out, isNot(contains('id_rsa')));
  });

  test('inlines a linked stylesheet as an inline <style> block', () async {
    final css = Uint8List.fromList(utf8.encode('body { color: red; }'));
    final fetcher = _RecordingFetcher({'/home/u/site/app.css': css});
    const source =
        '<html><head><link rel="stylesheet" href="app.css"></head>'
        '<body><p>x</p></body></html>';
    final out = await buildSafeHtml(
      source: source,
      docRemotePath: docPath,
      fetchAsset: fetcher.call,
    );
    expect(out, isNot(contains('<link')));
    expect(out, contains('<style'));
    expect(out, contains('color: red'));
  });
}
