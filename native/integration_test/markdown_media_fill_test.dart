// On-emulator tap-to-fill embedded-media smoke (#946).
//
// The markdown viewer renders embedded media (inline images + mermaid diagrams)
// inline and makes each TAP-TO-FILL: tapping pushes a shared fullscreen viewer
// (FillMediaViewer) whose InteractiveViewer forces pinch-zoom + pan on. Headless
// widget tests stub the image bytes + the WebView surface, so they prove the tap
// → fill routing but cannot prove a real image fetched over SFTP renders, nor
// the live webview. This test runs the REAL app on the emulator against
// test-sshd: it seeds a .md that references a relative image plus a mermaid
// block, opens it through the SFTP browser, and asserts BOTH media items tap
// into the fill viewer (the InteractiveViewer is present + pan/scale enabled).
//
// DEVICE GATE: the actual pinch-zoom + pan gestures (multi-touch on the
// InteractiveViewer for images, the fullscreen WebView's built-in zoom for
// mermaid) are verified MANUALLY on a real device/emulator — a synthetic gesture
// can't assert the visual zoom of rendered pixels / PlatformView. This test
// asserts the tap→fill route + the forced-zoom widget config; the gesture
// invariant is owner-validated.
//
// Network + bridge: identical setup to mermaid_markdown_render_test.dart.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/fill_media_viewer.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

// A minimal valid 1x1 transparent PNG (base64) — seeded as the embedded image.
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

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

  const done = 'MOBISSH_SEED_DONE_946';
  final mdB64 = base64Encode(utf8.encode(_doc));
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root/img; ')
    ..write("printf '%s' '$mdB64' | base64 -d > $root/doc.md; ")
    ..write("printf '%s' '$_pngB64' | base64 -d > $root/img/a.png; ")
    ..write('echo $done\n');
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));

  final seeded = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(done),
    maxSlices: 40,
  );
  expect(seeded, isTrue, reason: 'media seed never completed on test-sshd');
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

const _doc =
    '# Media\n\n'
    'An inline image:\n\n'
    '![a diagram](img/a.png)\n\n'
    'A flowchart:\n\n'
    '```mermaid\n'
    'graph TD;\n'
    '  A[Start] --> B{Choice};\n'
    '  B -->|yes| C[Do];\n'
    '```\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('inline image + mermaid both tap-to-fill into the zoom viewer', (
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

    const root = '/tmp/mobissh_itest_946';
    await _seedFiles(tester, entry!, root: root);

    final ctx = tester.element(find.byKey(const Key('session-menu-button')));
    await _openBrowserAt(tester, ctx, entry.id, root);
    expect(
      find.byKey(const Key('file-entry-doc.md')),
      findsOneWidget,
      reason: 'seeded markdown file not listed',
    );

    await tester.tap(find.byKey(const Key('file-entry-doc.md')));
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(MarkdownFileViewerScreen).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'markdown viewer did not open',
    );

    // The relative image fetched over the SAME SFTP session and rendered inline.
    expect(
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('markdown-inline-image')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'inline image never rendered (SFTP image fetch failed)',
    );

    // Tap the image → shared fill viewer with forced pinch/pan.
    await tester.tap(find.byKey(const Key('markdown-inline-image')));
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(FillMediaViewer).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'tapping the image did not open the fill viewer',
    );
    final ivImg = tester.widget<InteractiveViewer>(
      find.byKey(const Key('fill-media-interactive-viewer')),
    );
    expect(ivImg.panEnabled && ivImg.scaleEnabled, isTrue);

    // Close and tap the mermaid diagram → same fill viewer.
    await tester.tap(find.byKey(const Key('fill-media-close')));
    await _pumpUntil(
      tester,
      () => find.byType(FillMediaViewer).evaluate().isEmpty,
    );

    expect(
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('mermaid-tap-to-fill')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'mermaid diagram never rendered inline',
    );
    await tester.tap(find.byKey(const Key('mermaid-tap-to-fill')));
    expect(
      await _pumpUntil(
        tester,
        () => find.byType(FillMediaViewer).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'tapping the mermaid diagram did not open the fill viewer',
    );
  });
}
