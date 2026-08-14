// Widget tests for tap-to-fill embedded media in the markdown viewer (#946).
//
// Assert the consistent gesture model for embedded media:
//   - an inline image (`![](img/a.png)`) renders inline (resolved + fetched over
//     the injected SFTP image fetcher, relative to the .md's dir) and tapping it
//     pushes the shared fill viewer (InteractiveViewer with pan + scale forced),
//   - a broken/failed image falls back to a placeholder and never throws,
//   - a mermaid block renders inline and tapping it pushes the same fill viewer,
//   - the raw/source toggle (#854) still shows the source verbatim.
//
// Real platform surfaces (WebView, image decode) are swapped/canned so the test
// runs without a platform channel or socket — mirrors the existing markdown +
// mermaid widget tests.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/sftp_image_fetcher.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/services/text_file_fetcher.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/fill_media_viewer.dart';
import 'package:mobissh/ui/markdown_file_viewer.dart';
import 'package:mobissh/ui/mermaid_diagram_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A minimal valid 1x1 transparent PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

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

/// Records the path it is asked to fetch; returns canned bytes (or throws to
/// simulate a broken image).
class _FakeImageFetcher implements SftpImageFetcher {
  _FakeImageFetcher({required this.bytes, this.fail = false});
  final Uint8List bytes;
  final bool fail;
  String? requestedPath;

  @override
  Future<Uint8List> fetch(
    String sessionId,
    String path, {
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    requestedPath = path;
    if (fail) throw Exception('boom');
    return bytes;
  }
}

Future<void> _pump(WidgetTester tester, {int count = 14}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

({ProviderContainer container, SessionEntry session, SessionHost host}) _wire(
  WidgetTester tester, {
  required String markdown,
  required SftpImageFetcher imageFetcher,
}) {
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
      sftpImageFetcherProvider.overrideWithValue(imageFetcher),
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

Future<SessionHost> _open(
  WidgetTester tester, {
  required String markdown,
  required SftpImageFetcher imageFetcher,
  String mdPath = '/DOC.md',
}) async {
  final w = _wire(tester, markdown: markdown, imageFetcher: imageFetcher);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: w.container,
      child: MaterialApp(
        home: MarkdownFileViewerScreen(
          sessionId: w.session.id,
          entry: SftpEntry(name: 'DOC.md', path: mdPath, isDirectory: false),
          openLink: (_) async {},
        ),
      ),
    ),
  );
  await _pump(tester);
  return w.host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mermaidWebViewBuilder = (source) => Container(key: const Key('mm-stub'));
    mermaidFillBuilder = (source) => Container(key: const Key('mm-fill-stub'));
  });

  tearDown(() {
    mermaidWebViewBuilder = defaultMermaidWebViewBuilderForTest;
    mermaidFillBuilder = defaultMermaidFillBuilderForTest;
  });

  testWidgets('inline image resolves over SFTP and renders inline', (
    tester,
  ) async {
    final fetcher = _FakeImageFetcher(bytes: _png);
    final host = await _open(
      tester,
      markdown: '# Doc\n\n![a diagram](img/a.png)\n',
      imageFetcher: fetcher,
      mdPath: '/home/me/README.md',
    );

    expect(find.byKey(const Key('markdown-inline-image')), findsOneWidget);
    // Relative src resolved against the .md's directory before fetching.
    expect(fetcher.requestedPath, '/home/me/img/a.png');

    host.disposeSyncForTest();
  });

  testWidgets('tapping an inline image pushes the zoomable fill viewer', (
    tester,
  ) async {
    final host = await _open(
      tester,
      markdown: '![a](pic.png)\n',
      imageFetcher: _FakeImageFetcher(bytes: _png),
    );

    expect(find.byType(FillMediaViewer), findsNothing);

    await tester.tap(find.byKey(const Key('markdown-inline-image')));
    await _pump(tester);

    expect(find.byType(FillMediaViewer), findsOneWidget);
    final iv = tester.widget<InteractiveViewer>(
      find.byKey(const Key('fill-media-interactive-viewer')),
    );
    expect(iv.panEnabled, isTrue);
    expect(iv.scaleEnabled, isTrue);
    expect(find.byKey(const Key('fill-media-close')), findsOneWidget);

    host.disposeSyncForTest();
  });

  testWidgets(
    'http(s) image is never fetched and renders an inert placeholder (#1107 sibling)',
    (tester) async {
      // An untrusted remote .md that references an attacker-chosen absolute URL
      // must NOT trigger any outbound request on view (no beacon). We render an
      // inert "external image (not loaded)" affordance and make no fetch.
      final fetcher = _FakeImageFetcher(bytes: _png);
      final host = await _open(
        tester,
        markdown: '![tracker](http://attacker.example/x.png)\n',
        imageFetcher: fetcher,
      );

      // The inert affordance is shown...
      expect(find.byKey(const Key('markdown-image-external')), findsOneWidget);
      // ...and NO inline image / fill-viewer image was created.
      expect(find.byKey(const Key('markdown-inline-image')), findsNothing);
      // No Image widget backed by a NetworkImage (the beacon vector) exists.
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage),
        findsNothing,
      );
      // The SFTP fetcher was never asked to fetch the remote URL either.
      expect(fetcher.requestedPath, isNull);
      expect(tester.takeException(), isNull);

      host.disposeSyncForTest();
    },
  );

  testWidgets('broken image falls back to a placeholder without throwing', (
    tester,
  ) async {
    final host = await _open(
      tester,
      markdown: '![missing](nope.png)\n',
      imageFetcher: _FakeImageFetcher(bytes: _png, fail: true),
    );

    expect(find.byKey(const Key('markdown-image-placeholder')), findsOneWidget);
    expect(find.byKey(const Key('markdown-inline-image')), findsNothing);
    expect(tester.takeException(), isNull);

    host.disposeSyncForTest();
  });

  testWidgets('mermaid block renders inline and taps into the fill viewer', (
    tester,
  ) async {
    final host = await _open(
      tester,
      markdown: '```mermaid\ngraph TD; A-->B;\n```\n',
      imageFetcher: _FakeImageFetcher(bytes: _png),
    );

    expect(find.byType(MermaidDiagramView), findsOneWidget);
    expect(find.byType(FillMediaViewer), findsNothing);

    await tester.tap(find.byKey(const Key('mermaid-tap-to-fill')));
    await _pump(tester);

    expect(find.byType(FillMediaViewer), findsOneWidget);
    expect(find.byKey(const Key('mm-fill-stub')), findsOneWidget);
    // #949: the mermaid fill is SELF-ZOOMING (full-bleed; the WebView owns its
    // crisp built-in pinch/pan) — it must NOT be wrapped in the InteractiveViewer.
    expect(find.byKey(const Key('fill-media-self-zooming')), findsOneWidget);
    expect(
      find.byKey(const Key('fill-media-interactive-viewer')),
      findsNothing,
    );

    host.disposeSyncForTest();
  });

  testWidgets('raw toggle still shows the image source verbatim', (
    tester,
  ) async {
    final host = await _open(
      tester,
      markdown: '![a](img/a.png)\n',
      imageFetcher: _FakeImageFetcher(bytes: _png),
    );

    await tester.tap(find.byKey(const Key('markdown-raw-toggle')));
    await _pump(tester);

    expect(find.byKey(const Key('markdown-viewer-raw')), findsOneWidget);
    expect(find.textContaining('![a](img/a.png)'), findsOneWidget);
    expect(find.byKey(const Key('markdown-inline-image')), findsNothing);

    host.disposeSyncForTest();
  });
}
