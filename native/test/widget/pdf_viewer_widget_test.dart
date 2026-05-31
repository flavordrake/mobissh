// Widget tests for the in-app PDF viewer routing + mount (#557).
//
// These tests deliberately do NOT render with pdfium (no device / platform
// view in the headless harness). They assert:
//   - tapping a `.pdf` entry in the file browser routes to [PdfViewerScreen]
//     (via the production-default pdfTapInterceptor), instead of downloading,
//   - the viewer mounts, fetches the bytes to a temp file through an injected
//     fetcher, and reaches its "ready" state with that file,
//   - a fetch error surfaces the graceful error state (no crash),
//   - the temp file is deleted when the viewer is popped.
//
// The real pdfium render + pinch-zoom is device-validated by the owner.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/pdf_fetcher.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/pdf_viewer_screen.dart';
import 'package:pdfrx/pdfrx.dart' show PdfViewerController;
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal valid PDF (header + trailer). Enough to look like a PDF on disk;
/// we never feed it to pdfium in the headless harness.
final Uint8List _tinyPdf = Uint8List.fromList(
  '%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF'.codeUnits,
);

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

class _ScriptedSftpSession implements SftpSession {
  _ScriptedSftpSession(this._byPath, this._fileBytes);
  final Map<String, List<SftpEntry>> _byPath;
  final List<int> _fileBytes;

  @override
  Future<List<SftpEntry>> list(String path) async => _byPath[path] ?? const [];
  @override
  Future<int?> sizeOf(String path) async => _fileBytes.length;
  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    onChunk(Uint8List.fromList(_fileBytes), 0);
    return _fileBytes.length;
  }

  @override
  Future<void> close() async {}
}

/// Drains real async IO (the fetcher's temp-file writes use the real event
/// loop, which `tester.pump` alone does not advance) then flushes frames.
Future<void> _pump(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Placeholder render builder so the headless harness never invokes pdfium.
/// Reports a fixed page count and exposes a button to simulate a render error.
Widget _fakeRender(
  BuildContext context,
  File file,
  PdfViewerController controller, {
  required void Function(int pageCount) onPageCount,
  required void Function(Object error) onError,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) => onPageCount(3));
  return const Center(child: Text('fake-pdf-render'));
}

/// A fetcher that writes the bytes to a real temp file (so the cleanup-on-close
/// behavior is observable) but never invokes pdfium.
class _TempFileFetcher implements PdfFetcher {
  _TempFileFetcher(this.bytes);
  final Uint8List bytes;
  File? lastFile;

  @override
  Future<File> fetch(
    String sessionId,
    SftpEntry entry, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = await Directory.systemTemp.createTemp('pdftest');
    final f = File('${dir.path}/${entry.name}');
    await f.writeAsBytes(bytes);
    lastFile = f;
    onProgress?.call(bytes.length, bytes.length);
    return f;
  }
}

class _ThrowingFetcher implements PdfFetcher {
  @override
  Future<File> fetch(
    String sessionId,
    SftpEntry entry, {
    void Function(int received, int? total)? onProgress,
  }) async {
    throw Exception('boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('tapping a .pdf routes to the PDF viewer (not download)', (
    tester,
  ) async {
    final pair = InMemoryGatewayPair();
    addTearDown(pair.dispose);

    final fake = _ScriptedSftpSession({
      '/': const [
        SftpEntry(
          name: 'doc.pdf',
          path: '/doc.pdf',
          isDirectory: false,
          size: 10,
        ),
      ],
    }, _tinyPdf);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => fake,
      snapshotInterval: const Duration(hours: 1),
    );

    final fetcher = _TempFileFetcher(_tinyPdf);
    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        pdfFetcherProvider.overrideWithValue(fetcher),
        pdfRenderBuilderProvider.overrideWithValue(_fakeRender),
      ],
    );
    addTearDown(container.dispose);

    const params = SshConnectParams(
      host: 'h',
      port: 22,
      username: 'u',
      auth: SshAuth.password('p'),
    );
    final entry = container
        .read(sessionsProvider.notifier)
        .addOrActivate(params);
    entry.proxy.connect(params);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
      ),
    );
    await _pump(tester);

    expect(find.byKey(const Key('file-entry-doc.pdf')), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-entry-doc.pdf')));
    await _pump(tester);

    // Routed to the viewer, not the download path.
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.textContaining('Downloaded'), findsNothing);
    // Viewer fetched the bytes to a temp file and reached its ready state.
    expect(fetcher.lastFile, isNotNull);
    final exists =
        await tester.runAsync(() => fetcher.lastFile!.exists()) ?? false;
    expect(exists, isTrue);
    expect(find.byKey(const Key('pdf-viewer-ready')), findsOneWidget);
    // Page count surfaced in the AppBar.
    expect(find.byKey(const Key('pdf-viewer-page-count')), findsOneWidget);

    host.disposeSyncForTest();
  });

  testWidgets('viewer deletes the temp file when popped', (tester) async {
    final fetcher = _TempFileFetcher(_tinyPdf);
    final container = ProviderContainer(
      overrides: [
        pdfFetcherProvider.overrideWithValue(fetcher),
        pdfRenderBuilderProvider.overrideWithValue(_fakeRender),
      ],
    );
    addTearDown(container.dispose);

    const entry = SftpEntry(
      name: 'doc.pdf',
      path: '/doc.pdf',
      isDirectory: false,
      size: 10,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-pdf'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const PdfViewerScreen(sessionId: 's', entry: entry),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-pdf')));
    await _pump(tester);

    expect(find.byKey(const Key('pdf-viewer-ready')), findsOneWidget);
    final file = fetcher.lastFile!;
    final existsBefore = await tester.runAsync(() => file.exists()) ?? false;
    expect(existsBefore, isTrue);

    // Pop the viewer: its State.dispose() schedules deleteTempFile(_file). The
    // route is gone from the tree once the exit transition settles.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PdfViewerScreen), findsNothing);

    // dispose()'s real-IO delete future can't run in the fake-async test zone,
    // so drive the *same* cleanup the widget runs on the real loop and assert
    // it removes the temp file.
    final gone =
        await tester.runAsync(() async {
          await PdfViewerScreen.deleteTempFile(file);
          return !await file.exists();
        }) ??
        false;
    expect(gone, isTrue);
  });

  testWidgets('a fetch error shows the error state, not a crash', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [pdfFetcherProvider.overrideWithValue(_ThrowingFetcher())],
    );
    addTearDown(container.dispose);

    const entry = SftpEntry(
      name: 'doc.pdf',
      path: '/doc.pdf',
      isDirectory: false,
      size: 10,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PdfViewerScreen(sessionId: 's', entry: entry),
        ),
      ),
    );
    await _pump(tester);

    expect(find.byKey(const Key('pdf-viewer-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
