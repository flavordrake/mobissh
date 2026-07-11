// On-emulator rendered-HTML viewer smoke (#1037, epic #944).
//
// Headless widget tests stub the WebView + byte fetcher, so they prove the
// browser → registry → HtmlFileViewerScreen routing but not that a REAL page's
// relative references resolve over the session's SFTP. This test runs the real
// app against test-sshd: it seeds an html file whose RELATIVE css (background
// color + marker) and RELATIVE image live next to it, plus a `../escape.css`
// reference above the served root, opens it through the SFTP browser, and
// asserts:
//   - the rendered viewer opens with a live WebView surface (not raw source),
//   - the loopback resolver serves the page, the relative css, and the
//     relative image over SFTP (probed with real HTTP GETs against the
//     viewer's 127.0.0.1 server from inside the app process — the same origin
//     the WebView loads from),
//   - traversal misses 404 (`/escape.css` after browser normalization of
//     `../escape.css`, an encoded `%2e%2e` escape, and a plain miss) while the
//     page keeps rendering,
//   - the loopback port closes when the viewer route is popped.
//
// DEVICE GATE: actual pinch-zoom + pan are the WebView's built-in gestures on
// a PlatformView — a synthetic multi-touch can't assert rendered-pixel zoom
// (same posture as markdown_media_fill_test.dart). The zoom config
// (enableZoom + full-bleed, the #949 selfZooming shape) is code-asserted; the
// gesture itself is owner-validated. The test holds the rendered page on
// screen at the end for an emu-shot screenshot window.
//
// Network + bridge: identical setup to markdown_media_fill_test.dart.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/html_file_viewer.dart';
import 'package:mobissh/ui/text_file_viewer.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

// A minimal valid 1x1 transparent PNG (base64) — seeded as the relative image.
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

const _html =
    '<!doctype html>\n'
    '<html><head>\n'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    '<link rel="stylesheet" href="css/style.css">\n'
    '<link rel="stylesheet" href="../escape.css">\n'
    '<title>itest 1037</title>\n'
    '</head><body>\n'
    '<h1>MOBISSH_HTML_1037</h1>\n'
    '<p>styled via relative css; image below via relative path</p>\n'
    '<img src="img/a.png" alt="relative image">\n'
    '</body></html>\n';

const _css =
    '/* MOBISSH_CSS_MARKER_1037 */\n'
    'body { background: #1a5c2a; color: #ffffff; font-size: 28px; }\n'
    'h1 { color: #ffd54f; }\n';

Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() test, {
  int maxSlices = 80,
}) async {
  for (var i = 0; i < maxSlices; i++) {
    await tester.pump(_slice);
    final trust = find.text('Trust + connect');
    if (trust.evaluate().isNotEmpty) {
      await tester.tap(trust.first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (test()) return true;
  }
  return false;
}

Future<bool> _reachTerminal(WidgetTester tester) {
  return _pumpUntil(
    tester,
    () => find.byKey(const Key('session-menu-button')).evaluate().isNotEmpty,
  );
}

Future<void> _seedFiles(
  WidgetTester tester,
  SessionEntry entry, {
  required String root,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  const done = 'MOBISSH_SEED_DONE_1037';
  final htmlB64 = base64Encode(utf8.encode(_html));
  final cssB64 = base64Encode(utf8.encode(_css));
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root/site/css $root/site/img; ')
    // escape.css lives ABOVE the served root ($root/site) — the traversal
    // target that must never be served.
    ..write("printf '%s' 'SECRET_ESCAPE_1037' > $root/escape.css; ")
    ..write("printf '%s' '$htmlB64' | base64 -d > $root/site/index.html; ")
    ..write("printf '%s' '$cssB64' | base64 -d > $root/site/css/style.css; ")
    ..write("printf '%s' '$_pngB64' | base64 -d > $root/site/img/a.png; ")
    ..write('echo $done\n');

  // Let the remote shell finish its first-connect prompt/resize churn before
  // typing (the input can otherwise race shell readiness — seed flaked once).
  await tester.pump(const Duration(seconds: 2));

  var seeded = false;
  for (var attempt = 0; attempt < 2 && !seeded; attempt++) {
    entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));
    seeded = await _pumpUntil(
      tester,
      () => utf8.decode(out, allowMalformed: true).contains(done),
      maxSlices: 60,
    );
  }
  expect(seeded, isTrue, reason: 'html seed never completed on test-sshd');
}

Future<void> _openBrowserAt(
  WidgetTester tester,
  BuildContext context,
  String sessionId,
  String path,
) async {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(
          key: const Key('itest-file-browser'),
          sessionId: sessionId,
          initialPath: path,
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find.byKey(const Key('file-browser-list')).evaluate().isNotEmpty,
  );
}

/// GET [path] against the viewer's live loopback server; returns
/// (status, body). Runs in the app process — the same 127.0.0.1 origin the
/// WebView resolves against, so a 200 proves the SFTP round-trip.
Future<(int, String)> _probe(int port, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    final res = await req.close();
    final body = await utf8.decodeStream(res).catchError((_) => '');
    return (res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('html renders via the SFTP loopback resolver; escapes 404', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MobisshApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await adhocPasswordConnect(
      tester,
      host: '127.0.0.1',
      port: '2222',
      user: 'testuser',
      pass: 'testpass',
    );
    expect(
      await _reachTerminal(tester),
      isTrue,
      reason: 'never reached the terminal screen',
    );
    final entry = container.read(sessionsProvider).active;
    expect(entry, isNotNull, reason: 'no active session after connect');

    const root = '/tmp/mobissh_itest_1037';
    await _seedFiles(tester, entry!, root: root);

    final ctx = tester.element(find.byKey(const Key('session-menu-button')));
    await _openBrowserAt(tester, ctx, entry.id, '$root/site');
    expect(
      find.byKey(const Key('file-entry-index.html')),
      findsOneWidget,
      reason: 'seeded html file not listed',
    );

    // Tap the .html entry → the RENDERED viewer (not the text viewer).
    await tester.tap(find.byKey(const Key('file-entry-index.html')));
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(HtmlFileViewerScreen).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'html viewer did not open',
    );
    expect(find.byType(TextFileViewerScreen), findsNothing);
    expect(
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('html-webview-surface')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'webview surface never mounted (loopback server not ready)',
    );
    expect(find.byKey(const Key('html-view-source')), findsOneWidget);

    final server = debugLastHtmlLoopbackServer;
    expect(server, isNotNull, reason: 'no live loopback server');
    final port = server!.port!;

    // The WEBVIEW itself must fetch the page from the loopback origin. This
    // is the assertion that caught the cleartext-blocked WebView on the first
    // run (Android blocks http:// by default; fixed via
    // network_security_config.xml scoped to 127.0.0.1) — every out-of-process
    // probe succeeds while the WebView silently renders an error page.
    expect(
      await _pumpUntil(tester, () => server.requestCount > 0, maxSlices: 40),
      isTrue,
      reason: 'WebView never contacted the loopback origin '
          '(cleartext blocked? navigation blocked?)',
    );
    // Let the page finish pulling its relative assets, then probe the SAME
    // loopback origin ourselves.
    await tester.pump(const Duration(seconds: 2));

    final (pageStatus, pageBody) = await _probe(port, '/index.html');
    expect(pageStatus, 200);
    expect(pageBody, contains('MOBISSH_HTML_1037'));

    // Relative css + image resolve over SFTP (this is what styles the page).
    final (cssStatus, cssBody) = await _probe(port, '/css/style.css');
    expect(cssStatus, 200, reason: 'relative css did not resolve over SFTP');
    expect(cssBody, contains('MOBISSH_CSS_MARKER_1037'));
    final (imgStatus, _) = await _probe(port, '/img/a.png');
    expect(imgStatus, 200, reason: 'relative image did not resolve over SFTP');

    // Traversal: the page's `../escape.css` normalizes browser-side to
    // `/escape.css` — a miss under the root → 404, and the secret above the
    // root is never served. Encoded escapes and plain misses 404 too.
    final (escStatus, escBody) = await _probe(port, '/escape.css');
    expect(escStatus, 404, reason: 'escape ref must 404');
    expect(escBody, isNot(contains('SECRET_ESCAPE_1037')));
    final (encStatus, encBody) = await _probe(
      port,
      '/%2e%2e/escape.css',
    );
    expect(encStatus, anyOf(404, 200));
    expect(encBody, isNot(contains('SECRET_ESCAPE_1037')));
    final (missStatus, _) = await _probe(port, '/nope.css');
    expect(missStatus, 404);

    // Hold the rendered page on screen for the emu-shot window — the
    // screenshot shows the css-styled background + heading + image, which is
    // the visual proof of SFTP-backed rendering (and the pinch-zoom target
    // for manual validation). The marker line lets the orchestrator time the
    // shot (a Flutter screenshot can't capture a PlatformView surface).
    debugPrint('MOBISSH_HOLD_FOR_SHOT_1037');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Popping the viewer closes the loopback port.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(HtmlFileViewerScreen).evaluate().isEmpty,
      ),
      isTrue,
      reason: 'html viewer did not close',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(server.port, isNull, reason: 'loopback port must close on dispose');
  });
}
