// File browser CREATE FOLDER widget test (#1133).
//
// Drives [FileBrowserScreen] against the same task-side [SessionHost] +
// scripted SFTP harness as the other browser tests, and exercises both mkdir
// affordances the owner asked for:
//   - an AppBar button that opens a name dialog and creates in the CURRENT dir
//   - a long-press context-menu entry that creates INSIDE a long-pressed
//     directory, or in the CURRENT dir when a file was long-pressed
//
// The name dialog's validation is asserted at the IPC boundary: a rejected name
// must not produce a single mkdir call. Server-side errors (permission denied,
// already exists) are the server's authority — the UI never pre-checks the
// listing — so the error path asserts the server's own message reaches the user
// and the listing is left untouched.

import 'dart:async';
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
import 'package:shared_preferences/shared_preferences.dart';

SshSessionController _stubControllerFactory() {
  return SshSessionController(
    socketOpener: (host, port, {timeout}) => Completer<SSHSocket>().future,
  );
}

/// Scripted SFTP over a MUTABLE tree: [mkdir] records the call and (unless it
/// is scripted to fail) inserts the new directory into its parent's listing, so
/// the post-create refresh really does show the new folder.
class _MkdirSftpSession implements SftpSession {
  _MkdirSftpSession(this.byPath, {this.mkdirError});

  final Map<String, List<SftpEntry>> byPath;

  /// When set, [mkdir] throws it instead of creating — the server is the
  /// authority on "already exists" / "permission denied".
  final Object? mkdirError;

  /// Every path the UI asked to create, in order.
  final List<String> createdDirs = [];

  @override
  Future<List<SftpEntry>> list(String path) async => byPath[path] ?? const [];

  @override
  Future<void> mkdir(String path) async {
    createdDirs.add(path);
    if (mkdirError != null) throw mkdirError!;
    final parent = parentRemotePath(path);
    final name = path.substring(path.lastIndexOf('/') + 1);
    final siblings = [...(byPath[parent] ?? const <SftpEntry>[])];
    siblings.add(SftpEntry(name: name, path: path, isDirectory: true));
    byPath[parent] = siblings;
    byPath[path] = const [];
  }

  @override
  Future<int?> sizeOf(String path) async => 0;

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async => 0;

  @override
  Future<int> upload(String path, Uint8List bytes) async => bytes.length;

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
  '/home/u/projects': const [],
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

/// Boot the browser at /home/u over a scripted SFTP session. Returns the pieces
/// a test asserts on plus the teardown the framework's pending-timer check needs
/// to run INLINE (addTearDown is too late for that invariant).
Future<({_MkdirSftpSession sftp, SessionHost host, ProviderContainer container})>
_bootBrowser(WidgetTester tester, {Object? mkdirError}) async {
  final pair = InMemoryGatewayPair();
  final sftp = _MkdirSftpSession(_tree(), mkdirError: mkdirError);
  final host = SessionHost(
    gateway: pair.taskSide,
    controllerFactory: _stubControllerFactory,
    sftpOpener: (_) async => sftp,
    snapshotInterval: const Duration(hours: 1),
  );
  addTearDown(() async => pair.dispose());

  final container = ProviderContainer(
    overrides: [taskSshGatewayProvider.overrideWithValue(pair.uiSide)],
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
  return (sftp: sftp, host: host, container: container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('toolbar button opens the name dialog; an empty name is rejected '
      'without any mkdir', (tester) async {
    final ctx = await _bootBrowser(tester);

    expect(find.byKey(const Key('file-browser-new-folder')), findsOneWidget);
    await tester.tap(find.byKey(const Key('file-browser-new-folder')));
    await _pump(tester);
    expect(find.byKey(const Key('new-folder-dialog')), findsOneWidget);

    // Create with nothing typed: rejected, dialog stays open, no IPC.
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);
    expect(find.byKey(const Key('new-folder-dialog')), findsOneWidget);
    expect(find.byKey(const Key('new-folder-error')), findsOneWidget);
    expect(ctx.sftp.createdDirs, isEmpty);

    // Whitespace-only is the same case (the name is trimmed).
    await tester.enterText(
      find.byKey(const Key('new-folder-name-field')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);
    expect(find.byKey(const Key('new-folder-dialog')), findsOneWidget);
    expect(ctx.sftp.createdDirs, isEmpty);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('".." and a name containing a slash are rejected without any '
      'mkdir', (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.tap(find.byKey(const Key('file-browser-new-folder')));
    await _pump(tester);

    for (final bad in ['..', '.', 'a/b']) {
      await tester.enterText(
        find.byKey(const Key('new-folder-name-field')),
        bad,
      );
      await tester.tap(find.byKey(const Key('new-folder-create')));
      await _pump(tester);
      expect(
        find.byKey(const Key('new-folder-dialog')),
        findsOneWidget,
        reason: '"$bad" must not close the dialog',
      );
      expect(find.byKey(const Key('new-folder-error')), findsOneWidget);
      expect(ctx.sftp.createdDirs, isEmpty, reason: '"$bad" must not reach SFTP');
    }

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('a valid name issues exactly ONE mkdir at the joined absolute '
      'path and refreshes the listing', (tester) async {
    final ctx = await _bootBrowser(tester);

    expect(find.byKey(const Key('file-entry-notes')), findsNothing);

    await tester.tap(find.byKey(const Key('file-browser-new-folder')));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('new-folder-name-field')),
      '  notes  ',
    );
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);

    // Trimmed + joined onto the CURRENT directory, exactly once.
    expect(ctx.sftp.createdDirs, ['/home/u/notes']);
    // The listing refreshed: the new folder is on screen.
    expect(find.byKey(const Key('file-entry-notes')), findsOneWidget);
    expect(find.text('Created notes'), findsOneWidget);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets("a server error surfaces verbatim and leaves the listing intact",
      (tester) async {
    final ctx = await _bootBrowser(
      tester,
      mkdirError: SftpStatusError(3, 'Permission denied'),
    );

    await tester.tap(find.byKey(const Key('file-browser-new-folder')));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('new-folder-name-field')),
      'nope',
    );
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);

    expect(ctx.sftp.createdDirs, ['/home/u/nope']);
    // The server's own words reach the user.
    expect(
      find.textContaining('Permission denied'),
      findsWidgets,
      reason: "the server's message must survive the isolate hop",
    );
    // Listing untouched: the original entries are still there, no phantom row.
    expect(find.byKey(const Key('file-entry-projects')), findsOneWidget);
    expect(find.byKey(const Key('file-entry-a.txt')), findsOneWidget);
    expect(find.byKey(const Key('file-entry-nope')), findsNothing);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('long-press on a DIRECTORY creates INSIDE that directory',
      (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.longPress(find.byKey(const Key('file-entry-projects')));
    await _pump(tester);
    expect(find.byKey(const Key('file-context-new-folder')), findsOneWidget);
    // The sheet says where the folder will land — never ambiguous.
    expect(find.text('Inside /home/u/projects'), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-context-new-folder')));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('new-folder-name-field')),
      'sub',
    );
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);

    expect(ctx.sftp.createdDirs, ['/home/u/projects/sub']);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });

  testWidgets('long-press on a FILE creates in the CURRENT directory',
      (tester) async {
    final ctx = await _bootBrowser(tester);

    await tester.longPress(find.byKey(const Key('file-entry-a.txt')));
    await _pump(tester);
    expect(find.byKey(const Key('file-context-new-folder')), findsOneWidget);
    expect(find.text('In /home/u'), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-context-new-folder')));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('new-folder-name-field')),
      'notes',
    );
    await tester.tap(find.byKey(const Key('new-folder-create')));
    await _pump(tester);

    expect(ctx.sftp.createdDirs, ['/home/u/notes']);
    expect(find.byKey(const Key('file-entry-notes')), findsOneWidget);

    ctx.host.disposeSyncForTest();
    ctx.container.dispose();
  });
}
