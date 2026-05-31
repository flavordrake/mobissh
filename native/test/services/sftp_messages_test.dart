// Wire-contract tests for the SFTP IPC envelopes (#559).
//
// Every SFTP command/event must round-trip through toJson/fromJson without
// losing a field — the task host and UI browser both depend on this. Mirrors
// the existing task_ipc_test.dart pattern.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/services/session_messages.dart';

void main() {
  group('SftpEntry round-trip', () {
    test('file entry preserves all fields', () {
      const e = SftpEntry(
        name: 'report.pdf',
        path: '/home/user/report.pdf',
        isDirectory: false,
        size: 4096,
        modifyTime: 1700000000,
      );
      final restored = SftpEntry.fromJson(e.toJson());
      expect(restored.name, 'report.pdf');
      expect(restored.path, '/home/user/report.pdf');
      expect(restored.isDirectory, false);
      expect(restored.size, 4096);
      expect(restored.modifyTime, 1700000000);
      expect(restored.isSymlink, false);
    });

    test('directory entry omits size', () {
      const e = SftpEntry(
        name: 'docs',
        path: '/home/user/docs',
        isDirectory: true,
      );
      final json = e.toJson();
      expect(json.containsKey('size'), false);
      final restored = SftpEntry.fromJson(json);
      expect(restored.isDirectory, true);
      expect(restored.size, isNull);
    });

    test('symlink flag survives', () {
      const e = SftpEntry(
        name: 'link',
        path: '/link',
        isDirectory: false,
        isSymlink: true,
      );
      expect(SftpEntry.fromJson(e.toJson()).isSymlink, true);
    });
  });

  group('SFTP command round-trip', () {
    test('SftpListCommand preserves request id + path', () {
      const cmd = SftpListCommand(
        sessionId: 'sid',
        requestId: 'sid#3',
        path: '/var/log',
      );
      final restored = SshTaskCommand.fromJson(cmd.toJson());
      expect(restored, isA<SftpListCommand>());
      restored as SftpListCommand;
      expect(restored.sessionId, 'sid');
      expect(restored.requestId, 'sid#3');
      expect(restored.path, '/var/log');
    });

    test('SftpDownloadCommand preserves request id + path', () {
      const cmd = SftpDownloadCommand(
        sessionId: 'sid',
        requestId: 'sid#7',
        path: '/etc/hosts',
      );
      final restored =
          SshTaskCommand.fromJson(cmd.toJson()) as SftpDownloadCommand;
      expect(restored.requestId, 'sid#7');
      expect(restored.path, '/etc/hosts');
    });
  });

  group('SFTP event round-trip', () {
    test('SftpListingEvent preserves entries', () {
      const ev = SftpListingEvent(
        sessionId: 'sid',
        requestId: 'sid#1',
        path: '/',
        entries: [
          SftpEntry(name: 'a', path: '/a', isDirectory: true),
          SftpEntry(name: 'b.txt', path: '/b.txt', isDirectory: false, size: 9),
        ],
      );
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SftpListingEvent;
      expect(restored.requestId, 'sid#1');
      expect(restored.path, '/');
      expect(restored.entries.length, 2);
      expect(restored.entries[0].name, 'a');
      expect(restored.entries[0].isDirectory, true);
      expect(restored.entries[1].size, 9);
    });

    test('SftpDownloadChunkEvent preserves binary bytes + offset', () {
      final bytes = Uint8List.fromList([0, 255, 127, 1, 2, 250]);
      final ev = SftpDownloadChunkEvent(
        sessionId: 'sid',
        requestId: 'sid#2',
        bytes: bytes,
        offset: 128,
        totalBytes: 4096,
      );
      final restored =
          SshTaskEvent.fromJson(ev.toJson()) as SftpDownloadChunkEvent;
      expect(restored.bytes, bytes);
      expect(restored.offset, 128);
      expect(restored.totalBytes, 4096);
    });

    test('SftpDownloadDoneEvent preserves totalBytes', () {
      const ev = SftpDownloadDoneEvent(
        sessionId: 'sid',
        requestId: 'sid#2',
        totalBytes: 123456,
      );
      final restored =
          SshTaskEvent.fromJson(ev.toJson()) as SftpDownloadDoneEvent;
      expect(restored.totalBytes, 123456);
    });

    test('SftpErrorEvent preserves message + request id', () {
      const ev = SftpErrorEvent(
        sessionId: 'sid',
        requestId: 'sid#9',
        message: 'No such file',
      );
      final restored = SshTaskEvent.fromJson(ev.toJson()) as SftpErrorEvent;
      expect(restored.requestId, 'sid#9');
      expect(restored.message, 'No such file');
    });
  });
}
