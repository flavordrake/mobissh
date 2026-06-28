// On-emulator mermaid RENDER smoke (#942, #944).
//
// The markdown viewer routes ```mermaid fenced blocks to an offline WebView that
// runs the bundled mermaid.js (native/assets/mermaid/) — see
// mermaid_diagram_view.dart. The headless widget tests stub the WebView surface
// (no platform channel), so they prove the BUILDER routing but cannot prove the
// real webview actually loads the offline bundle and renders an SVG. This test
// runs the REAL app on the emulator against test-sshd, seeds a .md with a
// mermaid flowchart, opens it through the SFTP browser, and asserts the live
// WebView render surface appears and does NOT fall back to the source/error box
// (i.e. mermaid.js loaded offline and rendered the diagram).
//
// DEVICE GATE: pinch-zoom + pan on the rendered diagram come from the Android
// WebView's built-in zoom (#944 hard invariant) and are verified MANUALLY on a
// real device/emulator — a synthetic gesture can't assert the visual zoom of
// PlatformView pixels. This test asserts the render path; the gesture invariant
// is owner-validated.
//
// Network + bridge: identical setup to sftp_browse_smoke_test.dart
// (127.0.0.1:2222 → test-sshd:22 via the connect helpers).

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
import 'package:webview_flutter/webview_flutter.dart';

import 'package:mobissh/main.dart' show MobisshApp;
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/mermaid_diagram_view.dart';

import 'support/connect_helpers.dart';

const _slice = Duration(milliseconds: 500);

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

Future<void> _seedMarkdown(
  WidgetTester tester,
  SessionEntry entry, {
  required String root,
  required String fileName,
  required String content,
}) async {
  final out = <int>[];
  final sub = entry.proxy.output.listen(out.addAll);
  addTearDown(sub.cancel);

  const done = 'MOBISSH_SEED_DONE_942';
  final b64 = base64Encode(utf8.encode(content));
  final script = StringBuffer()
    ..write('rm -rf $root; ')
    ..write('mkdir -p $root; ')
    ..write("printf '%s' '$b64' | base64 -d > $root/$fileName; ")
    ..write('echo $done\n');
  entry.proxy.sendInput(Uint8List.fromList(utf8.encode(script.toString())));

  final seeded = await _pumpUntil(
    tester,
    () => utf8.decode(out, allowMalformed: true).contains(done),
    maxSlices: 40,
  );
  expect(seeded, isTrue, reason: 'markdown seed never completed on test-sshd');
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

const _mermaidMarkdown =
    '# Flow\n\n'
    'A flowchart below:\n\n'
    '```mermaid\n'
    'graph TD;\n'
    '  A[Start] --> B{Choice};\n'
    '  B -->|yes| C[Do thing];\n'
    '  B -->|no| D[Skip];\n'
    '```\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'markdown viewer renders an embedded mermaid block as a diagram (webview)',
    (tester) async {
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

      const root = '/tmp/mobissh_itest_942';
      const fileName = 'diagram.md';
      await _seedMarkdown(
        tester,
        entry!,
        root: root,
        fileName: fileName,
        content: _mermaidMarkdown,
      );

      final ctx = tester.element(find.byKey(const Key('session-menu-button')));
      await _openBrowserAt(tester, ctx, entry.id, root);
      expect(
        find.byKey(const Key('file-entry-$fileName')),
        findsOneWidget,
        reason: 'seeded markdown file not listed',
      );

      // Open the markdown viewer.
      await tester.tap(find.byKey(const Key('file-entry-$fileName')));
      final opened = await _pumpUntil(
        tester,
        () => find.byType(MarkdownFileViewerScreen).evaluate().isNotEmpty,
      );
      expect(opened, isTrue, reason: 'markdown viewer did not open');

      // The mermaid fence routed to the diagram renderer with a LIVE webview
      // surface (not stubbed in integration).
      final rendered = await _pumpUntil(
        tester,
        () =>
            find.byType(MermaidDiagramView).evaluate().isNotEmpty &&
            find.byType(WebViewWidget).evaluate().isNotEmpty,
      );
      expect(rendered, isTrue, reason: 'mermaid webview surface never appeared');

      // Give mermaid.js time to load offline + render the SVG, then assert it
      // did NOT degrade to the source/error fallback (offline bundle worked).
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        find.byKey(const Key('mermaid-fallback')),
        findsNothing,
        reason: 'mermaid fell back to source — offline render failed',
      );
      expect(
        find.byKey(const Key('mermaid-webview-surface')),
        findsOneWidget,
        reason: 'mermaid diagram surface not present after render',
      );
    },
  );
}
