// Widget tests for mermaid rendering in the markdown viewer (#942, #944).
//
// Assert the RENDERED view routes a ```mermaid fenced block to the offline
// WebView diagram renderer ([MermaidDiagramView]) instead of a plain code block,
// while:
//   - a non-mermaid fence (```dart) still renders as a normal code block,
//   - the raw/source toggle (#854) still shows the mermaid source VERBATIM,
//   - routing never throws for odd/garbage mermaid (graceful — the invalid →
//     error-note path is webview-side, exercised on device).
//
// The real WebView needs a platform channel, so we swap the diagram's render
// surface via the `mermaidWebViewBuilder` seam for a keyed stub. The public
// MermaidDiagramView type stays in the tree, so routing assertions hold without
// a platform webview.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/mermaid_diagram_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _stubKey = Key('mermaid-webview-stub');

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

class _CannedTextFetcher implements TextFileFetcher {
  _CannedTextFetcher(this.text);
  final String text;

  @override
  Future<String> fetch(
    String sessionId,
    SftpEntry entry, {
    int maxBytes = 2 * 1024 * 1024,
    void Function(int received, int? total)? onProgress,
  }) async => text;
}

Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester,
  String markdown,
) {
  final pair = InMemoryGatewayPair();
  addTearDown(pair.dispose);
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    snapshotInterval: const Duration(hours: 1),
  );
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      textFileFetcherProvider.overrideWithValue(_CannedTextFetcher(markdown)),
    ],
  );
  addTearDown(container.dispose);
  const params = SshConnectParams(
    host: 'h',
    port: 22,
    username: 'u',
    auth: SshAuth.password('p'),
  );
  final session = container.read(sessionsProvider.notifier).addOrActivate(
    params,
  );
  return (container: container, session: session, host: host);
}

Future<SessionHost> _open(WidgetTester tester, String markdown) async {
  final w = _wire(tester, markdown);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: w.container,
      child: MaterialApp(
        home: MarkdownFileViewerScreen(
          sessionId: w.session.id,
          entry: const SftpEntry(
            name: 'DOC.md',
            path: '/DOC.md',
            isDirectory: false,
          ),
          openLink: (_) async {},
        ),
      ),
    ),
  );
  await _pump(tester);
  return w.host;
}

const _mermaidDoc =
    '# Diagram\n\n'
    'Intro text.\n\n'
    '```mermaid\ngraph TD; A-->B; B-->C;\n```\n\n'
    'Outro text.\n';

const _mixedDoc =
    '```dart\nvoid main() {}\n```\n\n'
    '```mermaid\nsequenceDiagram; Alice->>Bob: Hi;\n```\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Swap the real WebView surface for a keyed stub (no platform channel).
    mermaidWebViewBuilder = (source) => Container(key: _stubKey);
  });

  tearDown(() {
    mermaidWebViewBuilder = defaultMermaidWebViewBuilderForTest;
  });

  testWidgets('mermaid fence renders as a diagram surface, not a code block', (
    tester,
  ) async {
    final host = await _open(tester, _mermaidDoc);

    // Routed to the offline-WebView diagram renderer.
    expect(find.byType(MermaidDiagramView), findsOneWidget);
    expect(find.byKey(_stubKey), findsOneWidget);
    // The mermaid SOURCE is NOT shown as text in rendered mode (it went to the
    // diagram, not a code block).
    expect(find.textContaining('graph TD'), findsNothing);
    // Surrounding markdown still renders normally.
    expect(find.textContaining('Intro text.'), findsOneWidget);
    expect(find.textContaining('Outro text.'), findsOneWidget);

    host.disposeSyncForTest();
  });

  testWidgets('raw toggle still shows the mermaid source verbatim', (
    tester,
  ) async {
    final host = await _open(tester, _mermaidDoc);

    // Default rendered: diagram surface present, no raw source text.
    expect(find.byType(MermaidDiagramView), findsOneWidget);

    await tester.tap(find.byKey(const Key('markdown-raw-toggle')));
    await _pump(tester);

    // Raw mode: verbatim source (fence + mermaid body) is shown; no diagram.
    expect(find.byKey(const Key('markdown-viewer-raw')), findsOneWidget);
    expect(find.byType(MermaidDiagramView), findsNothing);
    expect(find.textContaining('```mermaid'), findsOneWidget);
    expect(find.textContaining('graph TD'), findsOneWidget);

    host.disposeSyncForTest();
  });

  testWidgets('a non-mermaid fence still renders as a normal code block', (
    tester,
  ) async {
    final host = await _open(tester, _mixedDoc);

    // Exactly one mermaid diagram (the sequenceDiagram fence).
    expect(find.byType(MermaidDiagramView), findsOneWidget);
    // The dart fence is a normal code block: its source IS rendered as text
    // (code blocks paint via rich text, hence findRichText).
    expect(
      find.textContaining('void main', findRichText: true),
      findsOneWidget,
    );
    // …and it did NOT route to a diagram (source not consumed by a webview).
    expect(
      find.textContaining('sequenceDiagram', findRichText: true),
      findsNothing,
    );

    host.disposeSyncForTest();
  });

  testWidgets('garbage mermaid still routes without throwing (graceful)', (
    tester,
  ) async {
    // The invalid → source+error-note fallback is webview-side (device-gated);
    // here we assert the builder never crashes the viewer for odd content.
    final host = await _open(
      tester,
      '```mermaid\n!!! not a real diagram @@@\n```\n',
    );
    expect(find.byType(MermaidDiagramView), findsOneWidget);
    expect(tester.takeException(), isNull);
    host.disposeSyncForTest();
  });
}
