// SFTP session wrapper (#559).
//
// A thin abstraction over dartssh2's `SftpClient` so the task-side
// `SessionHost` can be unit-tested with a fake. The real implementation opens
// an SFTP subsystem channel over the authenticated `SSHClient`; tests inject a
// [FakeSftpSession] and never touch a socket.
//
// Scope (Slice 1): list a directory + download one file (chunked). Upload,
// mkdir, rename, delete are deliberately absent — they are Slice 2 (#559 says
// keep this small + shippable). Add them here when that lands.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../services/session_messages.dart';

/// Joins a parent directory [parent] with a child [name] into an absolute
/// remote path, collapsing the duplicate slash at the root. Shared by the host
/// (when building [SftpEntry.path]) and the browser navigation logic.
String joinRemotePath(String parent, String name) {
  if (parent.endsWith('/')) return '$parent$name';
  return '$parent/$name';
}

/// The parent directory of an absolute remote [path]. Returns '/' for the root
/// or a top-level entry. Used by the "up" button in the browser.
String parentRemotePath(String path) {
  if (path == '/' || path.isEmpty) return '/';
  var p = path;
  if (p.endsWith('/')) p = p.substring(0, p.length - 1);
  final idx = p.lastIndexOf('/');
  if (idx <= 0) return '/';
  return p.substring(0, idx);
}

/// Abstraction the [SessionHost] talks to. One per live SSH session, opened
/// lazily on the first SFTP command and reused for subsequent ones.
abstract class SftpSession {
  /// List the directory at [path]. Returns [SftpEntry]s with absolute paths.
  Future<List<SftpEntry>> list(String path);

  /// Download the file at [path], invoking [onChunk] for each block (with the
  /// byte offset of the block's first byte) and [onProgress] with the running
  /// total. Returns the total bytes transferred. [totalBytes] is resolved up
  /// front via stat so the UI can render a determinate progress bar.
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize,
  });

  /// Stat the file at [path] to learn its size (for progress). Null when the
  /// server omits the size.
  Future<int?> sizeOf(String path);

  /// Release the underlying SFTP channel.
  Future<void> close();
}

/// Opens an [SftpSession] for a given session id. Injected into [SessionHost]
/// so tests can substitute a fake without a real `SSHClient`. Returns null
/// when no authenticated client is available for that session (the host then
/// emits an [SftpErrorEvent]).
typedef SftpSessionOpener = Future<SftpSession?> Function(String sessionId);

/// Production [SftpSession] backed by dartssh2's [SftpClient].
class DartSshSftpSession implements SftpSession {
  DartSshSftpSession(this._client);

  final SftpClient _client;

  @override
  Future<List<SftpEntry>> list(String path) async {
    final names = await _client.listdir(path);
    final entries = <SftpEntry>[];
    for (final n in names) {
      // Skip the "." / ".." pseudo-entries — the browser navigates with the
      // dedicated up-button instead, matching the PWA file explorer.
      if (n.filename == '.' || n.filename == '..') continue;
      final attr = n.attr;
      entries.add(SftpEntry(
        name: n.filename,
        path: joinRemotePath(path, n.filename),
        isDirectory: attr.isDirectory,
        size: attr.isDirectory ? null : attr.size,
        modifyTime: attr.modifyTime,
        isSymlink: attr.isSymlinkType,
      ));
    }
    entries.sort(_dirsFirstByName);
    return entries;
  }

  @override
  Future<int?> sizeOf(String path) async {
    final attr = await _client.stat(path);
    return attr.size;
  }

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    final file = await _client.open(path);
    try {
      var offset = 0;
      var total = 0;
      await for (final chunk in file.read(chunkSize: chunkSize)) {
        onChunk(Uint8List.fromList(chunk), offset);
        offset += chunk.length;
        total += chunk.length;
      }
      return total;
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}

/// Sort directories before files, each group alphabetical (case-insensitive) —
/// the same ordering the PWA file explorer uses.
int _dirsFirstByName(SftpEntry a, SftpEntry b) {
  if (a.isDirectory != b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

extension on SftpFileAttrs {
  /// dartssh2 exposes `isSymbolicLink`; wrap so the wrapper file owns the name
  /// the host/UI use (keeps the rename localized if the dep API shifts).
  bool get isSymlinkType => isSymbolicLink;
}
