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

/// Expand a shell-style `~` / `~user` (or a relative) [path] to an absolute
/// remote path (#867). SFTP has no shell, so it never expands `~` itself — the
/// browser would pass a literal `~/.claude/...` to `listdir`, which the server
/// can't resolve (`No such file`, code 2). We expand it here, in the single
/// SFTP layer every list/stat/read routes through (so the tap-to-navigate path
/// from #777/#778 is covered too).
///
/// [home] is the session's resolved home directory (the realpath of the SFTP
/// cwd at open, via `SftpClient.absolute('.')`). Rules:
///   - `~`             → [home]
///   - `~/rest`        → [home] joined with `rest`
///   - `~user[/rest]`  → left UNCHANGED. Resolving another user's home cheaply
///                       needs `/etc/passwd`; rather than guess wrong we defer
///                       to the server's realpath / the friendly error path.
///   - absolute (`/…`) → unchanged.
///   - relative (`rest`) → joined onto [home] (the cwd at SFTP open), so a bare
///                       `foo` resolves like the shell would.
String expandTilde(String path, String home) {
  if (path.isEmpty) return home;
  if (path == '~') return home;
  if (path.startsWith('~/')) {
    return joinRemotePath(home, path.substring(2)); // drop the leading "~/"
  }
  // `~user` (not `~` or `~/…`): leave to the server / error path.
  if (path.startsWith('~')) return path;
  if (path.startsWith('/')) return path; // already absolute
  return joinRemotePath(home, path); // relative → resolve against home/cwd
}

/// Map a raw SFTP list error to a clean, user-facing empty-state message
/// (#867). The raw `SftpStatusError: No such file(code 2)` is dumped into the
/// diagnostic log by the caller; the UI shows this friendlier line instead.
///   - code 2 (no such file)     → `Folder not found: <path>`
///   - code 3 (permission denied)→ `Permission denied: <path>`
///   - anything else             → `Couldn't open <path>`
String friendlySftpListError(Object error, String path) {
  if (error is SftpStatusError) {
    switch (error.code) {
      case 2:
        return 'Folder not found: $path';
      case 3:
        return 'Permission denied: $path';
    }
  }
  return "Couldn't open $path";
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

  /// The session's home directory (realpath of the SFTP cwd at open), resolved
  /// once via `absolute('.')` and cached. Used to expand `~` (#867).
  String? _home;

  /// Resolve + cache the session home, then expand any `~`/relative [path] to
  /// an absolute path the server can resolve (SFTP has no shell). Called by
  /// every op (list/stat/download) so the literal `~/…` the browser builds
  /// (incl. the #777/#778 tap path) never reaches `listdir` unexpanded.
  Future<String> _resolve(String path) async {
    final home = _home ??= await _client.absolute('.');
    return expandTilde(path, home);
  }

  @override
  Future<List<SftpEntry>> list(String path) async {
    final resolved = await _resolve(path);
    final names = await _client.listdir(resolved);
    final entries = <SftpEntry>[];
    for (final n in names) {
      // Skip the "." / ".." pseudo-entries — the browser navigates with the
      // dedicated up-button instead, matching the PWA file explorer.
      if (n.filename == '.' || n.filename == '..') continue;
      final attr = n.attr;
      entries.add(SftpEntry(
        name: n.filename,
        // Build child paths off the RESOLVED absolute dir so navigation into a
        // subfolder doesn't re-introduce a `~` segment.
        path: joinRemotePath(resolved, n.filename),
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
    final attr = await _client.stat(await _resolve(path));
    return attr.size;
  }

  @override
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
    int chunkSize = 64 * 1024,
  }) async {
    final file = await _client.open(await _resolve(path));
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
