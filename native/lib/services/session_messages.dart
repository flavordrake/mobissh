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
}

/// Envelope kind discriminator for task → UI events.
enum SshTaskEventKind {
  state,
  output,
  snapshot,
  closed,
  error,
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
    }
  }
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
