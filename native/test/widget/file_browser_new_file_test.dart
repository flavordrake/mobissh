// File browser NEW FILE widget test (#1222).
//
// Mirrors the #1133 New folder test: drives [FileBrowserScreen] against the
// task-side [SessionHost] + a scripted SFTP tree, and covers the three places
// the owner asked for (toolbar → current dir; long-press a folder → inside it;
// long-press a file → alongside it).
//
// The create must NEVER overwrite: the fake refuses an existing path the way an
// exclusive open does on a real server, and the test asserts the existing
// file's bytes are untouched and the dialog stays open with the reason inline.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_host.dart';
import 'package:mobissh/services/session_messages.dart';
import 'package:mobissh/services/task_ssh_gateway.dart';
import 'package:mobissh/ssh/sftp_session.dart';
import 'package:mobissh/ssh/ssh_connect_params.dart';
import 'package:mobissh/ssh/ssh_session.dart';
import 'package:mobissh/state/session_host_providers.dart';
import 'package:mobissh/state/sessions.dart';
import 'package:mobissh/ui/file_browser_screen.dart';
import 'package:mobissh/ui/file_viewer_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

/// Scripted SFTP over a MUTABLE tree with real file CONTENTS, so a refused
/// create can be proven to have left the existing bytes alone.
class _NewFileSftpSession implements SftpSession {
  _NewFileSftpSession(this.byPath, this.contents);

  final Map<String, List<SftpEntry>> byPath;
  final Map<String, Uint8List> contents;

  /// Every path the UI asked to create, in order.
  final List<String> createCalls = [];

  @override
  Future<List<SftpEntry>> list(String path) async => byPath[path] ?? const [];

  @override
  Future<void> createFile(String path) async {
    createCalls.add(path);
    final parent = parentRemotePath(path);
    final name = path.substring(path.lastIndexOf('/') + 1);
    final siblings = [...(byPath[parent] ?? const <SftpEntry>[])];
    // Exclusive-create semantics: an existing name (file OR folder) is refused.
    if (contents.containsKey(path) || siblings.any((e) => e.path == path)) {
      throw SftpStatusError(11, 'File already exists');
    }
    siblings.add(SftpEntry(name: name, path: path, isDirectory: false, size: 0));
    byPath[parent] = siblings;
    contents[path] = Uint8List(0);
  }

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<int?> sizeOf(String path) async => contents[path]?.length ?? 0;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async => 0;

  @override
  Future<int> upload(String path, Uint8List bytes) async {
    contents[path] = Uint8List.fromList(bytes);
    return bytes.length;
  }

  @override
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    onProgress(0, 0);
    return 0;
  }

  @override
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    onProgress(0, 0);
    return 0;
  }

  @override
  Future<void> close() async {}
}

final Uint8List _existingReadme = Uint8List.fromList(
  utf8.encode('# keep me\n'),
);

Map<String, List<SftpEntry>> _tree() => {
  '/home/u': [
    const SftpEntry(
      name: 'projects',
      path: '/home/u/projects',
      isDirectory: true,
    ),
    const SftpEntry(
      name: 'a.txt',
      path: '/home/u/a.txt',
      isDirectory: false,
      size: 4,
    ),
  ],
  '/home/u/projects': [
    SftpEntry(
      name: 'README.md',
      path: '/home/u/projects/README.md',
      isDirectory: false,
      size: _existingReadme.length,
    ),
  ],
};

const SshConnectParams _params = SshConnectParams(
  host: 'h',
  port: 22,
  username: 'u',
  auth: SshAuth.password('p'),
);

Future<void> _pump(WidgetTester tester, {int count = 14}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<
  ({
    _NewFileSftpSession sftp,
    SessionHost host,
    ProviderContainer container,
    List<SftpEntry> opened,
  })
>
_bootBrowser(WidgetTester tester) async {
  final pair = InMemoryGatewayPair();
  final sftp = _NewFileSftpSession(_tree(), {
    '/home/u/a.txt': Uint8List.fromList(utf8.encode('aaaa')),
    '/home/u/projects/README.md': Uint8List.fromList(_existingReadme),
  });
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => sftp,
    snapshotInterval: const Duration(hours: 1),
  );
  addTearDown(() async => pair.dispose());

  // Spy viewer: records what the browser opens instead of pushing a real
  // viewer route (which would fetch over SFTP).
  final opened = <SftpEntry>[];
  final container = ProviderContainer(
    overrides: [
      taskSshGatewayProvider.overrideWithValue(pair.uiSide),
      fileViewerRegistryProvider.overrideWithValue(
        FileViewerRegistry([
          FileViewer(
            matches: (entry, {mime}) => true,
            open: (context, sessionId, entry) => opened.add(entry),
          ),
        ]),
      ),
    ],
  );
  final entry = container.read(sessionsProvider.notifier).addOrActivate(_params);
  entry.proxy.connect(_params);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FileBrowserScreen(sessionId: entry.id, initialPath: '/home/u'),
      ),
    ),
  );
  await _pump(tester);
  return (sftp: sftp, host: host, container: container, opened: opened);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('toolbar New file: prefilled README.md with "README" selected',
      (tester) async {
    final ctx = await _bootBrowser(tester);

    expect(find.byKey(const Key('file-browser-new-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-browser-new-file')));
    await _pump(tester);
    expect(find.byKey(const Key('new-file-dialog')), findsOneWidget);
    expect(find.text('In /home/u'), findsOneWidget);

    final field = tester.widget<TextField>(
      find.byKey(const Key('new-file-name-field')),
    );
    expect(field.controller!.text, 'README.md');
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 6),
      reason: 'the name part is selected so typing replaces it, keeping .md',
    );

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('invalid names are rejected inline without any create',
      (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.tap(find.byKey(const Key('file-browser-new-file')));
    await _pump(tester);

    for (final bad in ['', '   ', '..', '.', 'a/b']) {
      await tester.enterText(find.byKey(const Key('new-file-name-field')), bad);
      await tester.tap(find.byKey(const Key('new-file-create')));
      await _pump(tester);
      expect(
        find.byKey(const Key('new-file-dialog')),
        findsOneWidget,
        reason: '"$bad" must not close the dialog',
      );
      expect(find.byKey(const Key('new-file-error')), findsOneWidget);
      expect(ctx.sftp.createCalls, isEmpty, reason: '"$bad" must not reach SFTP');
    }

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('success creates ONE empty file in the current dir, refreshes '
      'the listing and opens it', (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.tap(find.byKey(const Key('file-browser-new-file')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('new-file-create')));
    await _pump(tester);

    expect(ctx.sftp.createCalls, ['/home/u/README.md']);
    expect(ctx.sftp.contents['/home/u/README.md'], isEmpty);
    expect(find.byKey(const Key('new-file-dialog')), findsNothing);
    expect(find.byKey(const Key('file-entry-README.md')), findsOneWidget);
    expect(ctx.opened.map((e) => e.path), ['/home/u/README.md']);
    expect(ctx.opened.single.isDirectory, isFalse);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('long-press a FOLDER: create inside it; an existing name is '
      'refused inline, dialog stays open, bytes untouched', (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.longPress(find.byKey(const Key('file-entry-projects')));
    await _pump(tester);
    await tester.ensureVisible(find.byKey(const Key('file-context-new-file')));
    await _pump(tester);
    expect(find.byKey(const Key('file-context-new-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-context-new-file')));
    await _pump(tester);
    expect(find.text('In /home/u/projects'), findsOneWidget);

    // README.md already exists in /home/u/projects.
    await tester.tap(find.byKey(const Key('new-file-create')));
    await _pump(tester);

    expect(ctx.sftp.createCalls, ['/home/u/projects/README.md']);
    expect(find.byKey(const Key('new-file-dialog')), findsOneWidget,
        reason: 'a refused create keeps the dialog open to pick another name');
    expect(find.byKey(const Key('new-file-error')), findsOneWidget);
    expect(find.textContaining('Already exists'), findsOneWidget);
    expect(ctx.sftp.contents['/home/u/projects/README.md'], _existingReadme,
        reason: 'the existing file must never be overwritten');
    expect(ctx.opened, isEmpty);

    // A different name then succeeds, inside the long-pressed folder.
    await tester.enterText(
      find.byKey(const Key('new-file-name-field')),
      'NOTES.md',
    );
    await tester.tap(find.byKey(const Key('new-file-create')));
    await _pump(tester);
    expect(ctx.sftp.createCalls.last, '/home/u/projects/NOTES.md');
    expect(find.byKey(const Key('new-file-dialog')), findsNothing);
    expect(ctx.opened.map((e) => e.path), ['/home/u/projects/NOTES.md']);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('long-press a FILE: create alongside it (current dir)',
      (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);
    await tester.ensureVisible(find.byKey(const Key('file-context-new-file')));
    await _pump(tester);
    await tester.tap(find.byKey(const Key('file-context-new-file')));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('new-file-name-field')),
      'b.txt',
    );
    await tester.tap(find.byKey(const Key('new-file-create')));
    await _pump(tester);

    expect(ctx.sftp.createCalls, ['/home/u/b.txt']);
    expect(find.byKey(const Key('file-entry-b.txt')), findsOneWidget);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });
}
