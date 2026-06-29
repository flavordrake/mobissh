// File browser UPLOAD UI widget test (#960).
//
// Drives [FileBrowserScreen] against the same task-side [SessionHost] + scripted
// SFTP harness as the other browser tests, and exercises the upload affordance:
//   - the AppBar shows an upload button
//   - tapping it (with a stubbed file picker) sends a chunked sftpUploadFile for
//     the picked local path → the CURRENT directory + picked name
//   - on completion the browser confirms (top toast) and refreshes the listing
//
// The real .part/rename/resume semantics need a live SFTP server and are covered
// by the emulator integration test; here the scripted session records the call
// and emits progress→done so the UI wiring is asserted headlessly.

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

/// Scripted SFTP that records the chunked upload + emits progress→done.
class _RecordingSftpSession implements SftpSession {
  final Map<String, List<SftpEntry>> byPath;
  _RecordingSftpSession(this.byPath);

  String? uploadedLocalPath;
  String? uploadedRemotePath;

  @override
  Future<List<SftpEntry>> list(String path) async => byPath[path] ?? const [];

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
    uploadedLocalPath = localPath;
    uploadedRemotePath = remotePath;
    onProgress(0, 2048);
    onProgress(2048, 2048);
    return 2048;
  }

  @override
  Future<void> close() async {}
}

const Map<String, List<SftpEntry>> _tree = {
  '/': [SftpEntry(name: 'a.bin', path: '/a.bin', isDirectory: false, size: 4)],
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('upload button picks a file and uploads it into the current dir', (
    tester,
  ) async {
    final pair = InMemoryGatewayPair();
    final recording = _RecordingSftpSession(_tree);
    final host = SessionHost(
      gateway: pair.taskSide,
      controllerFactory: _stubControllerFactory,
      sftpOpener: (_) async => recording,
      snapshotInterval: const Duration(hours: 1),
    );
    addTearDown(() async => pair.dispose());

    final container = ProviderContainer(
      overrides: [
        taskSshGatewayProvider.overrideWithValue(pair.uiSide),
        // Stub the picker: always "pick" /local/upload.bin.
        fileUploadPickerProvider.overrideWithValue(
          () async => (path: '/local/upload.bin', name: 'upload.bin'),
        ),
      ],
    );

    final entry = container.read(sessionsProvider.notifier).addOrActivate(
          _params,
        );
    entry.proxy.connect(_params);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: FileBrowserScreen(sessionId: entry.id)),
      ),
    );
    await _pump(tester);

    // The upload affordance is present.
    expect(find.byKey(const Key('file-browser-upload')), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-browser-upload')));
    await _pump(tester);

    // The chunked upload reached the session with the picked local path and a
    // remote path = current dir ('/') + picked name.
    expect(recording.uploadedLocalPath, '/local/upload.bin');
    expect(recording.uploadedRemotePath, '/upload.bin');

    // Cancel the host's timers INLINE before the framework's pending-timer check
    // (addTearDown runs too late for that invariant).
    host.disposeSyncForTest();
    container.dispose();
  });
}
