// SFTP session wrapper (#559).
//
// A thin abstraction over dartssh2's `SftpClient` so the task-side
// `SessionHost` can be unit-tested with a fake. The real implementation opens
// an SFTP subsystem channel over the authenticated `SSHClient`; tests inject a
// [FakeSftpSession] and never touch a socket.
//
// Scope: list a directory + download one file (chunked) + WHOLE-FILE upload
// (#892, the foundation for file editing) + chunked/resumable upload (#960) +
// streaming download (#976) + CREATE A DIRECTORY (#1133). rename and delete
// remain deliberately absent — add them HERE when they land, so the write seam
// stays in one place rather than growing a second path.

import 'dart:async';
import 'dart:io';
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
  // #1092: the SFTP subsystem open timed out (a stalled channel on a busy
  // connection). Say so — a bare "Couldn't open" reads like a bad path.
  if (error is TimeoutException) {
    return "SFTP didn't respond — the connection may be busy. Try again.";
  }
  return "Couldn't open $path";
}

/// Map a raw SFTP mkdir error to a user-facing line (#1133). The SERVER is the
/// authority on whether a create is legal (a stale listing must never veto a
/// legitimate one), so its own words are what the user sees: [SftpStatusError]
/// carries the server's `message`, and the two the owner actually hits get a
/// path-qualified phrasing. Anything else falls back to the raw message, then
/// to a generic line — never a bare bool.
String friendlySftpMkdirError(Object error, String path) {
  if (error is SftpStatusError) {
    // 3 = SSH_FX_PERMISSION_DENIED, 11 = SSH_FX_FILE_ALREADY_EXISTS.
    switch (error.code) {
      case 3:
        return 'Permission denied: $path';
      case 11:
        return 'Already exists: $path';
    }
    if (error.message.isNotEmpty) return '${error.message}: $path';
  }
  if (error is TimeoutException) {
    return "SFTP didn't respond — the connection may be busy. Try again.";
  }
  return "Couldn't create $path";
}

/// #1225: a download whose received byte count differs from the size the
/// server reported. Success is a checked state, not the end of a stream.
class DownloadIncompleteException implements Exception {
  const DownloadIncompleteException(this.received, this.expected);

  final int received;
  final int expected;

  @override
  String toString() => 'Download incomplete: got $received of $expected bytes';
}

/// Throws [DownloadIncompleteException] unless [received] == [expected].
void verifyDownloadComplete(int received, int expected) {
  if (received != expected) {
    throw DownloadIncompleteException(received, expected);
  }
}

/// #1228: an upload whose server-side size differs from the source size.
/// Thrown BEFORE the publish rename, so the destination is never touched.
class UploadIncompleteException implements Exception {
  const UploadIncompleteException(this.written, this.expected);

  /// What the server reports for the `.part` (-1 when it reports no size).
  final int written;
  final int expected;

  @override
  String toString() =>
      'Upload incomplete: server has $written of $expected bytes';
}

/// #1228: the verified `.part` could not be renamed over [destination]. BOTH
/// files are kept — the original is never deleted to make room.
class UploadPublishException implements Exception {
  const UploadPublishException(this.partPath, this.destination, this.cause);

  final String partPath;
  final String destination;
  final Object cause;

  @override
  String toString() =>
      'Upload complete but could not replace $destination ($cause); the new '
      'content is at $partPath and the original is untouched';
}

/// The size to verify a download of [file] against: its FSTAT size, taken on
/// the open handle so it is the same snapshot the read uses. Null when the
/// server omits it or reports 0 — virtual files (`/proc`) report 0 yet have
/// content, and dartssh2 then reads to EOF, so only the count is known.
Future<int?> _expectedSize(SftpFile file) async {
  final size = (await file.stat()).size;
  return (size == null || size == 0) ? null : size;
}

/// Abstraction the [SessionHost] talks to. One per live SSH session, opened
/// lazily on the first SFTP command and reused for subsequent ones.
abstract class SftpSession {
  /// List the directory at [path]. Returns [SftpEntry]s with absolute paths.
  Future<List<SftpEntry>> list(String path);

  /// Download the file at [path], invoking [onChunk] for each block (with the
  /// byte offset of the block's first byte) and [onProgress] with the running
  /// total. Returns the total bytes transferred. Throws
  /// [DownloadIncompleteException] when that differs from the server's size.
  Future<int> download(
    String path, {
    required void Function(Uint8List chunk, int offset) onChunk,
  });

  /// Stat the file at [path] to learn its size (for progress). Null when the
  /// server omits the size.
  Future<int?> sizeOf(String path);

  /// WHOLE-FILE upload (#892): write [bytes] to the remote file at [path],
  /// replacing any existing content. ATOMIC since #1228 (the editor save,
  /// #1227): the bytes go to `[path].part`, the server size is verified, then
  /// one rename publishes it — a cut connection can never leave a half-written
  /// destination. Reuses the same `~`/relative resolution as the read ops so
  /// `~/.ssh/config` works. Returns the number of bytes written. Throws
  /// [UploadIncompleteException] / [UploadPublishException] (see [uploadFile]).
  Future<int> upload(String path, Uint8List bytes);

  /// CHUNKED, RESUMABLE upload of the local file at [localPath] to [remotePath]
  /// (#960). Streams the local file (never the whole thing in memory) to
  /// `[remotePath].part`, then atomically renames it into place.
  ///
  /// Resume (#1228): a leftover `.part` is resumed ONLY when every byte it holds
  /// equals the source's prefix — it is read back and compared — which proves
  /// both that it belongs to THIS source (not an edited same-name file) and
  /// that it has no hole below its size (pipelined writes cut mid-flight leave
  /// one). Anything else restarts from 0. Before publishing, the server's size
  /// must equal the source size or [UploadIncompleteException] is thrown and
  /// the destination is untouched. The publish is one rename (posix-rename
  /// overwrite when the server has it); if it fails, BOTH files are kept and
  /// [UploadPublishException] is thrown — the original is never deleted.
  /// [onProgress] reports (sent, total) — sent starts at the resume offset.
  /// Returns the total bytes of the file. Reuses `~`/relative resolution.
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
  });

  /// STREAMING download of the remote file at [remotePath] to the LOCAL file at
  /// [localPath] (#976). The mirror of [uploadFile]: the task reads the remote
  /// file chunk-by-chunk and writes each straight to the local staging file
  /// (never the whole file in memory), reporting only (done, total) via
  /// [onProgress] — the bytes never cross the isolate IPC (unlike [download],
  /// which hands every chunk back to the UI). [total] is resolved up front via
  /// stat (0 when the server omits the size) so the UI can render a determinate
  /// bar. Returns the total bytes written. Reuses `~`/relative resolution.
  /// Throws [DownloadIncompleteException] (and deletes [localPath]) when the
  /// bytes written differ from the server's size (#1225).
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
  });

  /// CREATE the directory at [path] (#1133). Reuses the same `~`/relative
  /// resolution as every other op. Deliberately does NOT pre-check existence:
  /// the server is the authority, and its failure (permission denied / already
  /// exists) propagates to the caller for the UI to surface.
  Future<void> mkdir(String path);

  /// CREATE an EMPTY file at [path] (#1222), NEVER overwriting: the open is
  /// write|create|EXCLUSIVE, so the server refuses an existing name atomically
  /// (a stat-then-write pre-check would race). An existing name surfaces as an
  /// [SftpStatusError] with code 11 (already exists).
  Future<void> createFile(String path);

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
  }) async {
    final file = await _client.open(await _resolve(path));
    try {
      // #1225: library default request size. dartssh2 >= 3.0.2 re-requests the
      // remainder of a short READ and yields in offset order, so `offset` is
      // the running count; no chunk bookkeeping of our own.
      final expected = await _expectedSize(file);
      var offset = 0;
      await for (final chunk in file.read(length: expected)) {
        onChunk(Uint8List.fromList(chunk), offset);
        offset += chunk.length;
      }
      if (expected != null) verifyDownloadComplete(offset, expected);
      return offset;
    } finally {
      await file.close();
    }
  }

  @override
  Future<int> upload(String path, Uint8List bytes) async {
    // #1228: never open the destination for writing. The bytes go to `.part`
    // (write|create|truncate — `truncate` requires `create` per the SFTP spec)
    // on the RESOLVED path so `~/…` lands right (#867), then verify + rename.
    final resolved = await _resolve(path);
    final partPath = '$resolved.part';
    final file = await _client.open(partPath, mode: _truncateMode);
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
    await _publishPart(partPath, resolved, bytes.length);
    return bytes.length;
  }

  @override
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
  }) async {
    final resolved = await _resolve(remotePath);
    final partPath = '$resolved.part';
    final local = File(localPath);
    final total = await local.length();

    final resumeAt = await _verifiedPartLength(partPath, local, total);
    onProgress(resumeAt, total);
    if (resumeAt < total) {
      // A restart truncates; a verified resume writes in place from its end.
      final mode = resumeAt == 0
          ? _truncateMode
          : (SftpFileOpenMode.write | SftpFileOpenMode.create);
      final file = await _client.open(partPath, mode: mode);
      try {
        // The library's pipelined writer (16 KiB packets, 64 in flight, #1225
        // lesson: library sizes, not ours). `done` completes only once every
        // write is ACKED, so nothing is left in flight at close.
        await file.write(
          local.openRead(resumeAt).map(_asBytes),
          offset: resumeAt,
          onProgress: (acked) => onProgress(resumeAt + acked, total),
        ).done;
      } finally {
        await file.close();
      }
    }
    await _publishPart(partPath, resolved, total);
    return total;
  }

  static final _truncateMode = SftpFileOpenMode.write |
      SftpFileOpenMode.create |
      SftpFileOpenMode.truncate;

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

  /// #1228 resume decision. Returns the `.part` length when EVERY byte it holds
  /// equals [local]'s prefix, else 0 (restart). The read-back compare is the
  /// one check that proves both identity and contiguity without a server-side
  /// exec; it costs a download of the `.part` (≤ the source), which on this
  /// app's asymmetric mobile links still beats re-uploading. Rejected: a
  /// sidecar (cannot vouch for a hole) and rewinding by the in-flight window
  /// (cannot vouch for an edited same-name source). When in doubt, restart.
  Future<int> _verifiedPartLength(
      String partPath, File local, int total) async {
    final int partLen;
    try {
      partLen = (await _client.stat(partPath)).size ?? 0;
    } catch (_) {
      return 0; // no `.part`
    }
    if (partLen == 0 || partLen > total) return 0;
    try {
      final remote = await _client.open(partPath);
      final mine = await local.open();
      try {
        var matched = 0;
        await for (final chunk in remote.read(length: partLen)) {
          final want = await mine.read(chunk.length);
          if (!_sameBytes(chunk, want)) return 0;
          matched += chunk.length;
        }
        return matched == partLen ? partLen : 0;
      } finally {
        await remote.close();
        await mine.close();
      }
    } catch (_) {
      return 0; // unreadable `.part` → the truncating open below decides
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// #1228 publish: the `.part` must hold exactly [expected] bytes on the
  /// server, then ONE rename moves it over [resolved] (dartssh2 4.1.0 uses
  /// posix-rename's overwrite when the server advertises it). On failure both
  /// files stay put — the destination is never removed to make room.
  Future<void> _publishPart(
      String partPath, String resolved, int expected) async {
    final size = (await _client.stat(partPath)).size ?? -1;
    if (size != expected) throw UploadIncompleteException(size, expected);
    try {
      await _client.rename(partPath, resolved);
    } catch (e) {
      throw UploadPublishException(partPath, resolved, e);
    }
  }

  @override
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
  }) async {
    final file = await _client.open(await _resolve(remotePath));
    final local = File(localPath);
    // openWrite streams to disk incrementally — the whole file is never held in
    // memory and never returned to the caller (bytes stay task-side).
    final sink = local.openWrite();
    var complete = false;
    try {
      // The size drives a determinate bar and is the completeness check; when
      // unknown the total reports 0 and the UI shows an indeterminate spinner.
      final expected = await _expectedSize(file);
      final total = expected ?? 0;
      onProgress(0, total);
      // #1225: the library's downloadTo, at its default request size — it
      // re-requests short READs and writes in offset order (dartssh2 >= 3.0.2).
      final done = await file.downloadTo(
        sink,
        length: expected,
        onProgress: (n) => onProgress(n, total),
      );
      await sink.flush();
      if (expected != null) verifyDownloadComplete(done, expected);
      complete = true;
      return done;
    } finally {
      await file.close();
      await sink.close();
      // Never leave a short file where a caller could publish it.
      if (!complete) {
        try {
          if (await local.exists()) await local.delete();
        } catch (_) {
          /* best-effort; the error that got us here is what surfaces */
        }
      }
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await _client.mkdir(await _resolve(path));
  }

  @override
  Future<void> createFile(String path) async {
    final resolved = await _resolve(path);
    final SftpFile file;
    try {
      file = await _client.open(
        resolved,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive,
      );
    } on SftpStatusError {
      // OpenSSH's sftp-server reports EEXIST as a generic FAILURE (code 4),
      // not FILE_ALREADY_EXISTS. The exclusive open already refused — this stat
      // only NAMES the reason, it decides nothing — so it is not a race.
      var exists = false;
      try {
        await _client.stat(resolved);
        exists = true;
      } catch (_) {}
      if (exists) throw SftpStatusError(11, 'File already exists');
      rethrow;
    }
    await file.close();
  }

  @override
  Future<void> close() async {
    // SftpClient.close() is a Future since dartssh2 2.22.3 (#1226, minimal
    // API adaptation only — transfer logic is #1225's). Deliberately NOT
    // awaited: it waits for the peer's CHANNEL_CLOSE, which never comes on a
    // dead link, and session teardown awaits this before disposing the
    // controller. Pre-upgrade close() was void, so this keeps that behaviour.
    unawaited(_client.close().catchError((Object _) {}));
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
