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

  /// WHOLE-FILE upload (#892): write [bytes] to the remote file at [path],
  /// opening it write|create|truncate (replacing any existing content). Reuses
  /// the same `~`/relative resolution as the read ops so `~/.ssh/config` works.
  /// Returns the number of bytes written. Chunked upload is a later slice.
  Future<int> upload(String path, Uint8List bytes);

  /// CHUNKED, RESUMABLE upload of the local file at [localPath] to [remotePath]
  /// (#960). Streams the local file (never the whole thing in memory) to
  /// `[remotePath].part`, then atomically renames it into place. If a `.part`
  /// already exists for an interrupted upload, RESUMES from its size; a `.part`
  /// larger than the local file (stale) is discarded and the upload restarts.
  /// [onProgress] reports (sent, total) — sent starts at the resume offset.
  /// Returns the total bytes of the file. Reuses `~`/relative resolution.
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
    int chunkSize,
  });

  /// STREAMING download of the remote file at [remotePath] to the LOCAL file at
  /// [localPath] (#976). The mirror of [uploadFile]: the task reads the remote
  /// file chunk-by-chunk and writes each straight to the local staging file
  /// (never the whole file in memory), reporting only (done, total) via
  /// [onProgress] — the bytes never cross the isolate IPC (unlike [download],
  /// which hands every chunk back to the UI). [total] is resolved up front via
  /// stat (0 when the server omits the size) so the UI can render a determinate
  /// bar. Returns the total bytes written. Reuses `~`/relative resolution.
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize,
  });

  /// CREATE the directory at [path] (#1133). Reuses the same `~`/relative
  /// resolution as every other op. Deliberately does NOT pre-check existence:
  /// the server is the authority, and its failure (permission denied / already
  /// exists) propagates to the caller for the UI to surface.
  Future<void> mkdir(String path);

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
  Future<int> upload(String path, Uint8List bytes) async {
    // Open the RESOLVED path write|create|truncate so a `~/…` or relative path
    // (#867) lands at the right place and any existing content is replaced
    // (whole-file write, #892). `truncate` requires `create` per the SFTP spec.
    final file = await _client.open(
      await _resolve(path),
      mode: SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
      return bytes.length;
    } finally {
      await file.close();
    }
  }

  @override
  Future<int> uploadFile(
    String localPath,
    String remotePath, {
    required void Function(int sent, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    final resolved = await _resolve(remotePath);
    final partPath = '$resolved.part';
    final local = File(localPath);
    final total = await local.length();

    // Resume: if a `.part` from an interrupted upload exists, continue from its
    // size. A `.part` LARGER than the local file is stale/corrupt → discard it
    // and start over. `stat` throwing means no `.part` yet → fresh upload.
    var resumeAt = 0;
    try {
      final partAttr = await _client.stat(partPath);
      final partSize = partAttr.size ?? 0;
      if (partSize > total) {
        await _client.remove(partPath);
      } else {
        resumeAt = partSize;
      }
    } catch (_) {
      resumeAt = 0;
    }

    if (resumeAt < total) {
      // Fresh start truncates; a resume appends in place (no truncate) and seeks
      // each chunk to its absolute offset via writeBytes(offset:).
      final mode = resumeAt == 0
          ? (SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.truncate)
          : (SftpFileOpenMode.write | SftpFileOpenMode.create);
      final file = await _client.open(partPath, mode: mode);
      try {
        var sent = resumeAt;
        onProgress(sent, total);
        // openRead(resumeAt) streams the local file from the resume offset only.
        await for (final chunk in local.openRead(resumeAt)) {
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          await file.writeBytes(bytes, offset: sent);
          sent += bytes.length;
          onProgress(sent, total);
        }
      } finally {
        await file.close();
      }
    } else {
      // `.part` already holds the whole file (interrupted right before rename).
      onProgress(total, total);
    }

    // Atomic publish: rename `.part` → final. If the destination already exists
    // (re-upload / replace), remove it first then rename (SFTP rename won't
    // clobber on most servers). The `.part` shielded the real file throughout.
    try {
      await _client.rename(partPath, resolved);
    } catch (_) {
      try {
        await _client.remove(resolved);
      } catch (_) {
        // best-effort; the rename retry below surfaces any real failure
      }
      await _client.rename(partPath, resolved);
    }
    return total;
  }

  @override
  Future<int> downloadFile(
    String remotePath,
    String localPath, {
    required void Function(int done, int total) onProgress,
    int chunkSize = 64 * 1024,
  }) async {
    final resolved = await _resolve(remotePath);
    // Resolve the size up front for a determinate bar; a null size (server
    // omitted it) reports as 0 total — the UI falls back to an indeterminate
    // spinner but progress still ticks by `done`.
    final attr = await _client.stat(resolved);
    final total = attr.size ?? 0;
    final file = await _client.open(resolved);
    // openWrite streams to disk incrementally — the whole file is never held in
    // memory and never returned to the caller (bytes stay task-side).
    final sink = File(localPath).openWrite();
    var done = 0;
    try {
      onProgress(done, total);
      await for (final chunk in file.read(chunkSize: chunkSize)) {
        sink.add(chunk);
        done += chunk.length;
        onProgress(done, total);
      }
    } finally {
      await file.close();
      await sink.close();
    }
    return done;
  }

  @override
  Future<void> mkdir(String path) async {
    await _client.mkdir(await _resolve(path));
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
