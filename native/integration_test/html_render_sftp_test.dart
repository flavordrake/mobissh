// On-emulator rendered-HTML viewer smoke (#1037, hardened #1107).
//
// Headless widget tests stub the WebView + byte fetcher, so they prove the
// browser → registry → HtmlFileViewerScreen routing but not that a REAL page
// renders self-contained with NO network egress. This test runs the real app
// against test-sshd: it seeds an html file whose RELATIVE css + RELATIVE image
// live next to it, PLUS a beacon `<img src="http://127.0.0.1:<beacon>/beacon">`
// pointing at a local counter server, opens it through the SFTP browser, and
// asserts:
//   - the rendered viewer opens with a live WebView surface (not raw source),
//   - #1107 EXFIL GUARD: the beacon server records ZERO hits — the hostile
//     network reference was inlined away (dropped) and no origin/egress exists
//     (the page is rendered via loadHtmlString + JS-off + a default-src 'none'
//     meta-CSP; the loopback server that served the whole SFTP subtree is gone),
//   - the viewer's "view source" escape hatch is present,
//   - the viewer route closes cleanly.
//
// DEVICE GATE: actual pinch-zoom + pan are the WebView's built-in gestures on a
// PlatformView — a synthetic multi-touch can't assert rendered-pixel zoom, and a
// Flutter screenshot can't capture a PlatformView surface. The rendered page is
// held on screen at the end for an emu-shot window (the css-styled background +
// heading + inlined image is the visual proof of SFTP-backed rendering, and the
// select+copy / link-launch checks are owner-validated on hardware).
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

// The page carries a relative css + relative image (both inlined over SFTP) and
// a BEACON image pointing at a local http counter (#1107): if anything about the
// hardened viewer let a network reference survive, this beacon would be hit.
// `%BEACON%` is replaced with the live counter port at seed time.
const _htmlTemplate =
    '<!doctype html>\n'
    '<html><head>\n'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    '<link rel="stylesheet" href="css/style.css">\n'
    '<title>itest 1107</title>\n'
    '</head><body>\n'
    '<h1>MOBISSH_HTML_1107</h1>\n'
    '<p>styled via relative css; image below via relative path</p>\n'
    '<img src="img/a.png" alt="relative image">\n'
    '<img src="http://127.0.0.1:%BEACON%/beacon.png" alt="beacon">\n'
    '</body></html>\n';

const _css =
    '/* MOBISSH_CSS_MARKER_1107 */\n'
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
  required int beaconPort,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  const done = 'MOBISSH_SEED_DONE_1107';
  final html = _htmlTemplate.replaceAll('%BEACON%', '$beaconPort');
  final htmlB64 = base64Encode(utf8.encode(html));
  final cssB64 = base64Encode(utf8.encode(_css));
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root/site/css $root/site/img; ')
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('html renders self-contained; a network beacon is never hit', (
    tester,
  ) async {
    FlutterForegroundTask.initCommunicationPort();

    // Local counter server — if the hardened viewer let ANY network reference
    // survive, the page's beacon <img> would hit this and bump the counter.
    var beaconHits = 0;
    final beacon = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    beacon.listen((req) async {
      beaconHits++;
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
    });
    addTearDown(() => beacon.close(force: true));

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

    const root = '/tmp/mobissh_itest_1107';
    await _seedFiles(tester, entry!, root: root, beaconPort: beacon.port);

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
      reason: 'webview surface never mounted',
    );
    expect(find.byKey(const Key('html-view-source')), findsOneWidget);

    // Give the WebView ample time to render + (attempt to) pull any references.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // #1107 EXFIL GUARD: no network reference survived the inliner + CSP.
    expect(
      beaconHits,
      0,
      reason: 'hardened viewer must never contact a network beacon',
    );

    // Hold the rendered page on screen for the emu-shot window — the screenshot
    // shows the css-styled background + heading + inlined image (the visual
    // proof of SFTP-backed rendering and the pinch-zoom / select-copy target).
    debugPrint('MOBISSH_HOLD_FOR_SHOT_1107');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Popping the viewer route closes it cleanly.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(HtmlFileViewerScreen).evaluate().isEmpty,
      ),
      isTrue,
      reason: 'html viewer did not close',
    );
    // Beacon still never hit, even after teardown.
    expect(beaconHits, 0);
  });
}
