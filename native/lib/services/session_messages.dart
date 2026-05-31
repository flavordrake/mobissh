// Typed message envelopes for UI ↔ foreground-task isolate IPC (#524).
//
// The `flutter_foreground_task` plugin only ships Dart-serializable values
// across the isolate boundary (`Map<String, dynamic>` is the lowest common
// denominator). This module owns the wire contract: every command sent from
// the UI to the task and every event sent back is round-trippable through
// `toJson` / `fromJson`.
//
// Keep the payloads SMALL. Anything that crosses the boundary is copied; a
// 4KB scrollback chunk emitted 30× a second will saturate the channel. The
// snapshot event is intentionally string-typed (last-N rendered lines, not
// raw byte chunks).

import 'dart:convert';
import 'dart:typed_data';

/// Envelope kind discriminator for UI → task commands.
enum SshTaskCommandKind {
  connect,
  disconnect,
  input,
  resize,
  requestSnapshot,
  hostKeyDecision,

  // --- SFTP (#559) ---
  /// List a remote directory over the session's SftpClient.
  sftpList,

  /// Download a single remote file; the task streams chunks back.
  sftpDownload,
}

/// Envelope kind discriminator for task → UI events.
enum SshTaskEventKind {
  state,
  output,
  snapshot,
  closed,
  error,
  hostKeyChallenge,

  /// Task isolate finished booting (`SessionHost` + gateway wired). The UI
  /// gateway flushes any commands it buffered during isolate spin-up (#539).
  ready,

  // --- SFTP (#559) ---
  /// A directory listing result (entries for one path).
  sftpListing,

  /// One chunk of a file being downloaded (base64 bytes + running offset).
  sftpDownloadChunk,

  /// A download finished — total bytes + the request id.
  sftpDownloadDone,

  /// An SFTP operation failed (list or download). Carries the request id so
  /// the UI can match it to the in-flight op without tearing down the session.
  sftpError,
}

/// One remote filesystem entry surfaced to the file browser (#559). Kept small
/// and Dart-serializable so it round-trips across the UI ↔ task IPC boundary.
/// Mirrors the fields the PWA file explorer renders (name, dir flag, size,
/// mtime). `path` is the absolute remote path (parent + name) so the UI can
/// navigate / download without re-joining paths itself.
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifyTime,
    this.isSymlink = false,
  });

  final String name;
  final String path;
  final bool isDirectory;

  /// Size in bytes (null for directories / when the server omits it).
  final int? size;

  /// Modification time in seconds since epoch (null when omitted).
  final int? modifyTime;

  final bool isSymlink;

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isDirectory': isDirectory,
        if (size != null) 'size': size,
        if (modifyTime != null) 'modifyTime': modifyTime,
        if (isSymlink) 'isSymlink': true,
      };

  factory SftpEntry.fromJson(Map<String, dynamic> json) => SftpEntry(
        name: json['name'] as String,
        path: json['path'] as String,
        isDirectory: json['isDirectory'] as bool,
        size: json['size'] as int?,
        modifyTime: json['modifyTime'] as int?,
        isSymlink: (json['isSymlink'] as bool?) ?? false,
      );
}

/// Base for all UI → task command envelopes. Subclasses are concrete records
/// of one command shape; serialization goes through [toJson] / [fromJson].
sealed class SshTaskCommand {
  const SshTaskCommand(this.sessionId);

  /// Per-session identifier. Matches the UI-side `SessionEntry.id` so the
  /// task-side router knows which holder to dispatch to.
  final String sessionId;

  SshTaskCommandKind get kind;

  Map<String, dynamic> toJson();

  static SshTaskCommand fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'] as String?;
    final sessionId = json['sessionId'] as String?;
    if (kindRaw == null || sessionId == null) {
      throw FormatException('SshTaskCommand: missing kind/sessionId in $json');
    }
    final kind = SshTaskCommandKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () =>
          throw FormatException('SshTaskCommand: unknown kind "$kindRaw"'),
    );
    switch (kind) {
      case SshTaskCommandKind.connect:
        return SshConnectCommand(
          sessionId: sessionId,
          host: json['host'] as String,
          port: json['port'] as int,
          username: json['username'] as String,
          authJson: Map<String, dynamic>.from(json['auth'] as Map),
          title: json['title'] as String?,
        );
      case SshTaskCommandKind.disconnect:
        return SshDisconnectCommand(sessionId: sessionId);
      case SshTaskCommandKind.input:
        final b64 = json['bytes'] as String;
        return SshInputCommand(
          sessionId: sessionId,
          bytes: Uint8List.fromList(base64Decode(b64)),
        );
      case SshTaskCommandKind.resize:
        return SshResizeCommand(
          sessionId: sessionId,
          cols: json['cols'] as int,
          rows: json['rows'] as int,
          pixelWidth: (json['pixelWidth'] as int?) ?? 0,
          pixelHeight: (json['pixelHeight'] as int?) ?? 0,
        );
      case SshTaskCommandKind.requestSnapshot:
        return SshRequestSnapshotCommand(sessionId: sessionId);
      case SshTaskCommandKind.hostKeyDecision:
        return SshHostKeyDecisionCommand(
          sessionId: sessionId,
          accepted: json['accepted'] as bool,
        );
      case SshTaskCommandKind.sftpList:
        return SftpListCommand(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          path: json['path'] as String,
        );
      case SshTaskCommandKind.sftpDownload:
        return SftpDownloadCommand(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          path: json['path'] as String,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// SFTP commands (#559)
// ---------------------------------------------------------------------------

/// UI → task: list the remote directory at [path]. The task replies with a
/// matching [SftpListingEvent] (or [SftpErrorEvent]) carrying [requestId] so
/// the browser can ignore stale listings after a fast navigation.
class SftpListCommand extends SshTaskCommand {
  const SftpListCommand({
    required String sessionId,
    required this.requestId,
    required this.path,
  }) : super(sessionId);

  final String requestId;
  final String path;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.sftpList;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'path': path,
      };
}

/// UI → task: download the single remote file at [path]. The task streams
/// [SftpDownloadChunkEvent]s and a terminal [SftpDownloadDoneEvent], all keyed
/// by [requestId]. Folder/recursive download is Slice 2 — this is one file.
class SftpDownloadCommand extends SshTaskCommand {
  const SftpDownloadCommand({
    required String sessionId,
    required this.requestId,
    required this.path,
  }) : super(sessionId);

  final String requestId;
  final String path;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.sftpDownload;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'path': path,
      };
}

class SshConnectCommand extends SshTaskCommand {
  const SshConnectCommand({
    required String sessionId,
    required this.host,
    required this.port,
    required this.username,
    required this.authJson,
    this.title,
  }) : super(sessionId);

  final String host;
  final int port;
  final String username;

  /// Auth payload, opaque to this module. The task-side router converts it
  /// back to `SshConnectParams.auth`. Keeping it as a map lets us evolve the
  /// auth shape without breaking the wire contract.
  final Map<String, dynamic> authJson;
  final String? title;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.connect;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'host': host,
        'port': port,
        'username': username,
        'auth': authJson,
        if (title != null) 'title': title,
      };
}

class SshDisconnectCommand extends SshTaskCommand {
  const SshDisconnectCommand({required String sessionId}) : super(sessionId);

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.disconnect;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
      };
}

class SshInputCommand extends SshTaskCommand {
  SshInputCommand({required String sessionId, required this.bytes})
      : super(sessionId);

  final Uint8List bytes;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.input;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'bytes': base64Encode(bytes),
      };
}

class SshResizeCommand extends SshTaskCommand {
  const SshResizeCommand({
    required String sessionId,
    required this.cols,
    required this.rows,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  }) : super(sessionId);

  final int cols;
  final int rows;
  final int pixelWidth;
  final int pixelHeight;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.resize;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'cols': cols,
        'rows': rows,
        'pixelWidth': pixelWidth,
        'pixelHeight': pixelHeight,
      };
}

class SshRequestSnapshotCommand extends SshTaskCommand {
  const SshRequestSnapshotCommand({required String sessionId})
      : super(sessionId);

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.requestSnapshot;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
      };
}

/// UI → task: the user's trust decision for a pending host-key challenge
/// (#536). Routed to the task-side controller's
/// `acceptHostKey()` / `rejectHostKey()` so trust-on-first-use can resolve the
/// verify callback that the controller is blocked on.
class SshHostKeyDecisionCommand extends SshTaskCommand {
  const SshHostKeyDecisionCommand({
    required String sessionId,
    required this.accepted,
  }) : super(sessionId);

  /// True = trust + continue; false = reject + abort.
  final bool accepted;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.hostKeyDecision;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'accepted': accepted,
      };
}

// ---------------------------------------------------------------------------
// Events (task → UI)
// ---------------------------------------------------------------------------

sealed class SshTaskEvent {
  const SshTaskEvent(this.sessionId);

  final String sessionId;

  SshTaskEventKind get kind;

  Map<String, dynamic> toJson();

  static SshTaskEvent fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'] as String?;
    final sessionId = json['sessionId'] as String?;
    if (kindRaw == null || sessionId == null) {
      throw FormatException('SshTaskEvent: missing kind/sessionId in $json');
    }
    final kind = SshTaskEventKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () =>
          throw FormatException('SshTaskEvent: unknown kind "$kindRaw"'),
    );
    switch (kind) {
      case SshTaskEventKind.state:
        return SshStateEvent(
          sessionId: sessionId,
          state: json['state'] as String,
          error: json['error'] as String?,
          host: json['host'] as String?,
          port: json['port'] as int?,
          username: json['username'] as String?,
        );
      case SshTaskEventKind.output:
        final b64 = json['bytes'] as String;
        return SshOutputEvent(
          sessionId: sessionId,
          bytes: Uint8List.fromList(base64Decode(b64)),
        );
      case SshTaskEventKind.snapshot:
        return SshSnapshotEvent(
          sessionId: sessionId,
          state: json['state'] as String,
          bytesIn: (json['bytesIn'] as int?) ?? 0,
          bytesOut: (json['bytesOut'] as int?) ?? 0,
          lastKeepaliveRttMs: json['lastKeepaliveRttMs'] as int?,
          reconnectCount: (json['reconnectCount'] as int?) ?? 0,
          lastReconnectAtMs: json['lastReconnectAtMs'] as int?,
          scrollbackTail: json['scrollbackTail'] as String? ?? '',
        );
      case SshTaskEventKind.closed:
        return SshClosedEvent(sessionId: sessionId);
      case SshTaskEventKind.error:
        return SshErrorEvent(
          sessionId: sessionId,
          message: json['message'] as String,
        );
      case SshTaskEventKind.hostKeyChallenge:
        return SshHostKeyChallengeEvent(
          sessionId: sessionId,
          host: json['host'] as String,
          port: json['port'] as int,
          keyType: json['keyType'] as String,
          fingerprint: json['fingerprint'] as String,
        );
      case SshTaskEventKind.ready:
        return const SshTaskReadyEvent();
      case SshTaskEventKind.sftpListing:
        final rawEntries = (json['entries'] as List)
            .map((e) => SftpEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        return SftpListingEvent(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          path: json['path'] as String,
          entries: rawEntries,
        );
      case SshTaskEventKind.sftpDownloadChunk:
        return SftpDownloadChunkEvent(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          bytes: Uint8List.fromList(base64Decode(json['bytes'] as String)),
          offset: json['offset'] as int,
          totalBytes: json['totalBytes'] as int?,
        );
      case SshTaskEventKind.sftpDownloadDone:
        return SftpDownloadDoneEvent(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          totalBytes: json['totalBytes'] as int,
        );
      case SshTaskEventKind.sftpError:
        return SftpErrorEvent(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          message: json['message'] as String,
        );
    }
  }
}

class SshStateEvent extends SshTaskEvent {
  const SshStateEvent({
    required String sessionId,
    required this.state,
    this.error,
    this.host,
    this.port,
    this.username,
  }) : super(sessionId);

  /// SshSessionState.name string; the UI proxy maps it back to the enum.
  final String state;
  final String? error;
  final String? host;
  final int? port;
  final String? username;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.state;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'state': state,
        if (error != null) 'error': error,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        if (username != null) 'username': username,
      };
}

class SshOutputEvent extends SshTaskEvent {
  SshOutputEvent({required String sessionId, required this.bytes})
      : super(sessionId);

  final Uint8List bytes;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.output;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'bytes': base64Encode(bytes),
      };
}

/// Periodic state-of-the-world dump from task → UI. Used to populate the
/// Connection Audit screen and the fast-rebind cache.
class SshSnapshotEvent extends SshTaskEvent {
  const SshSnapshotEvent({
    required String sessionId,
    required this.state,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.lastKeepaliveRttMs,
    this.reconnectCount = 0,
    this.lastReconnectAtMs,
    this.scrollbackTail = '',
  }) : super(sessionId);

  final String state;
  final int bytesIn;
  final int bytesOut;
  final int? lastKeepaliveRttMs;
  final int reconnectCount;
  final int? lastReconnectAtMs;

  /// Last N rendered lines of scrollback, newline-joined. Capped at the
  /// task-side to keep the IPC payload small (target ≤ 4KB).
  final String scrollbackTail;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.snapshot;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'state': state,
        'bytesIn': bytesIn,
        'bytesOut': bytesOut,
        if (lastKeepaliveRttMs != null) 'lastKeepaliveRttMs': lastKeepaliveRttMs,
        'reconnectCount': reconnectCount,
        if (lastReconnectAtMs != null) 'lastReconnectAtMs': lastReconnectAtMs,
        'scrollbackTail': scrollbackTail,
      };
}

class SshClosedEvent extends SshTaskEvent {
  const SshClosedEvent({required String sessionId}) : super(sessionId);

  @override
  SshTaskEventKind get kind => SshTaskEventKind.closed;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
      };
}

class SshErrorEvent extends SshTaskEvent {
  const SshErrorEvent({required String sessionId, required this.message})
      : super(sessionId);

  final String message;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.error;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'message': message,
      };
}

/// Task → UI: a new (untrusted) host key needs a user trust decision (#536).
/// The UI proxy turns this into a `PendingHostKey` so the existing host-key
/// dialog (keyed on `SshSessionData.pendingHostKey`) surfaces unchanged.
class SshHostKeyChallengeEvent extends SshTaskEvent {
  const SshHostKeyChallengeEvent({
    required String sessionId,
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  }) : super(sessionId);

  final String host;
  final int port;
  final String keyType;
  final String fingerprint;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.hostKeyChallenge;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'host': host,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
      };
}

/// Task → UI: the foreground task isolate has finished booting (#539). Sent
/// once from `KeepaliveTaskHandler.onStart` after the `SessionHost` + gateway
/// are wired. It is task-global, not per-session, so [sessionId] is an empty
/// sentinel — the per-session proxy ignores it on the sessionId mismatch.
///
/// The UI-side gateway uses the FIRST inbound payload (typically this event) as
/// the signal to flush any commands it buffered while `startService` was still
/// spinning up the isolate.
class SshTaskReadyEvent extends SshTaskEvent {
  const SshTaskReadyEvent() : super('');

  @override
  SshTaskEventKind get kind => SshTaskEventKind.ready;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
      };
}

// ---------------------------------------------------------------------------
// SFTP events (#559)
// ---------------------------------------------------------------------------

/// Task → UI: the directory listing for [path]. [requestId] matches the
/// originating [SftpListCommand] so the browser can drop stale results.
class SftpListingEvent extends SshTaskEvent {
  const SftpListingEvent({
    required String sessionId,
    required this.requestId,
    required this.path,
    required this.entries,
  }) : super(sessionId);

  final String requestId;
  final String path;
  final List<SftpEntry> entries;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.sftpListing;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'path': path,
        'entries': entries.map((e) => e.toJson()).toList(),
      };
}

/// Task → UI: one chunk of a downloading file. Streamed in order; the UI
/// assembles them into the destination sink. [offset] is the byte offset of
/// this chunk's first byte; [totalBytes] (when known) drives the progress bar.
class SftpDownloadChunkEvent extends SshTaskEvent {
  SftpDownloadChunkEvent({
    required String sessionId,
    required this.requestId,
    required this.bytes,
    required this.offset,
    this.totalBytes,
  }) : super(sessionId);

  final String requestId;
  final Uint8List bytes;
  final int offset;
  final int? totalBytes;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.sftpDownloadChunk;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'bytes': base64Encode(bytes),
        'offset': offset,
        if (totalBytes != null) 'totalBytes': totalBytes,
      };
}

/// Task → UI: a download completed successfully. [totalBytes] is the full
/// transferred size; the UI flushes + closes its destination sink on this.
class SftpDownloadDoneEvent extends SshTaskEvent {
  const SftpDownloadDoneEvent({
    required String sessionId,
    required this.requestId,
    required this.totalBytes,
  }) : super(sessionId);

  final String requestId;
  final int totalBytes;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.sftpDownloadDone;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'totalBytes': totalBytes,
      };
}

/// Task → UI: an SFTP list/download op failed. Scoped to [requestId] so it
/// surfaces as an in-browser error (snackbar) without disturbing the SSH
/// session itself.
class SftpErrorEvent extends SshTaskEvent {
  const SftpErrorEvent({
    required String sessionId,
    required this.requestId,
    required this.message,
  }) : super(sessionId);

  final String requestId;
  final String message;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.sftpError;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'requestId': requestId,
        'message': message,
      };
}
