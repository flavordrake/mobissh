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

  /// UI → task: a fresh UI-side gateway re-handshake request (#731). Sent
  /// straight to the transport via `sendControl` (NOT buffered) when the
  /// foreground service is "already running" but the new gateway is not-ready —
  /// the service outlived the UI process, so `onStart` won't re-fire and no
  /// `SshTaskReadyEvent` would otherwise reach the new gateway. The task
  /// re-emits its ready event in response.
  uiHello,

  /// UI → task: actively verify a session's socket is still alive after a
  /// background → resume cycle (#737). The task pings the hosted controller
  /// (`probeLiveness`) with a short timeout so a zombie-`connected` session
  /// whose socket died half-open during Doze is declared dead → reconnect,
  /// instead of being trusted and left frozen.
  resumeProbe,

  /// UI -> task: user tapped Reconnect on a dropped session (#817, Active
  /// Sessions UI). Maps task-side to `SshSessionController.reconnectNow()`,
  /// which FORCE re-enters the reconnect path from held params (no auth
  /// re-supply) for a `failed` / `disconnected` / `softDisconnected` /
  /// `reconnecting` session — ignoring the resume staleness threshold and
  /// overriding a prior user disconnect (an explicit "revive" intent).
  reconnect,

  /// UI → task: the UI's foreground/background state changed (#806). Carries an
  /// `active` flag — `false` when the UI is backgrounded (`AppLifecycleState.
  /// paused`, proxies unbound), `true` on resume. The task-side host gates its
  /// periodic snapshot timer on this: backgrounded, the UI discards snapshots,
  /// so the 2s push (incl. a ~4KB scrollback decode shipped cross-isolate) is
  /// pure battery waste. Task-global (empty sentinel sessionId) — one app-wide
  /// state, not per-session.
  setActive,

  // --- SFTP (#559) ---
  /// List a remote directory over the session's SftpClient.
  sftpList,

  /// Download a single remote file; the task streams chunks back.
  sftpDownload,

  /// Upload (whole-file write) a single remote file (#892). The bytes are
  /// carried inline; the task opens the resolved path write|create|truncate and
  /// writes them, then replies with a terminal [SftpUploadDoneEvent].
  sftpUpload,

  // --- tmux control mode (#911, Part C) ---

  /// UI → task: a FULL tmux `-CC` control-command LINE, delivered ATOMICALLY
  /// (#911). The host writes it as ONE framed `transport.send` with a single
  /// trailing newline (`TmuxControlChannel.controlCommand`) so a multi-token
  /// command (`select-window -t @1`) can't fragment across the gateway and hit
  /// the pane shell. Only acts when the control-mode flag is ON (the host has a
  /// `tmuxChannel`); a no-op otherwise. NEVER used by the scrape (flag-OFF) path.
  controlCommand,

  /// UI → task: a high-level tmux WINDOW gesture (#911) — `nextWindow`,
  /// `previousWindow`, or a status-bar TAP at a column. The host resolves it
  /// against the channel's authoritative ordered window list and issues the
  /// matching `next-window` / `previous-window` / `select-window -t @<id>` via the
  /// atomic control-command path. Keeping the index lookup TASK-SIDE means the UI
  /// never needs the window list and a status tap maps with no pixel guessing.
  tmuxGesture,
}

/// The kind of tmux window gesture an [SshTmuxGestureCommand] carries (#911).
enum TmuxWindowGesture {
  /// Horizontal swipe RIGHT → `next-window`.
  nextWindow,

  /// Horizontal swipe LEFT → `previous-window`.
  previousWindow,

  /// Tap a status-bar window name → `select-window -t @<id>` for the window whose
  /// status segment the tap column fell in.
  tapStatusCol,
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

  /// The PTY shell for a session is open + writable (its stdin is wired and
  /// its output is being piped back). Emitted once per shell open, including
  /// after a reconnect re-opens the shell (#619). The UI gates the
  /// run-on-connect "initial command" on THIS, not the bare `connected` state,
  /// so a slow host's shell can't be raced ahead of by the command bytes
  /// (which `_handleInput` would otherwise drop to scrollback).
  shellReady,

  // --- SFTP (#559) ---
  /// A directory listing result (entries for one path).
  sftpListing,

  /// One chunk of a file being downloaded (base64 bytes + running offset).
  sftpDownloadChunk,

  /// A download finished — total bytes + the request id.
  sftpDownloadDone,

  /// A whole-file upload finished — total bytes written + the request id
  /// (#892). The writer seam completes its future on this.
  sftpUploadDone,

  /// An SFTP operation failed (list, download, or upload). Carries the request
  /// id so the UI can match it to the in-flight op without tearing down the
  /// session.
  sftpError,

  /// Task → UI: one HIGH-signal lifecycle telemetry line (#759/#766). The
  /// `clifecycle` writers (resume-liveness probe OUTCOME, reconnect decisions)
  /// run in the foreground-task isolate, whose `lifecycleLog` ring is a SEPARATE
  /// per-isolate copy the UI never reads. The feedback bundle is assembled in
  /// the UI isolate, so without forwarding the lifecycle ring it ships EMPTY
  /// (#766 meta-bug). This event carries each lifecycle line across the boundary
  /// so the UI-side ring — the one the bundle reads — actually contains them.
  /// Task-global, so [sessionId] is the empty sentinel (mirrors ready).
  lifecycle,
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
          controlMode: json['controlMode'] as bool? ?? false,
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
      case SshTaskCommandKind.uiHello:
        return const SshUiHelloCommand();
      case SshTaskCommandKind.resumeProbe:
        return SshResumeProbeCommand(sessionId: sessionId);
      case SshTaskCommandKind.reconnect:
        return SshReconnectCommand(sessionId: sessionId);
      case SshTaskCommandKind.setActive:
        return SshSetActiveCommand(
          active: json['active'] as bool,
          activeSessionId: json['activeSessionId'] as String?,
          activeHost: json['activeHost'] as String?,
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
      case SshTaskCommandKind.sftpUpload:
        return SftpUploadCommand(
          sessionId: sessionId,
          requestId: json['requestId'] as String,
          path: json['path'] as String,
          bytes: Uint8List.fromList(base64Decode(json['bytes'] as String)),
        );
      case SshTaskCommandKind.controlCommand:
        return SshControlCommand(
          sessionId: sessionId,
          command: json['command'] as String,
        );
      case SshTaskCommandKind.tmuxGesture:
        final gestureRaw = json['gesture'] as String;
        return SshTmuxGestureCommand(
          sessionId: sessionId,
          gesture: TmuxWindowGesture.values.firstWhere(
            (g) => g.name == gestureRaw,
            orElse: () => throw FormatException(
                'SshTmuxGestureCommand: unknown gesture "$gestureRaw"'),
          ),
          statusCol: (json['statusCol'] as int?) ?? 0,
          statusCols: (json['statusCols'] as int?) ?? 0,
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

/// UI → task: WHOLE-FILE upload of [bytes] to the remote file at [path] (#892).
/// The task opens the resolved path `write | create | truncate` and writes the
/// bytes, then replies with a terminal [SftpUploadDoneEvent] (or [SftpErrorEvent]
/// on failure), all keyed by [requestId]. Mirrors [SftpDownloadCommand]. Chunked
/// upload is a later slice — text files are small enough to carry inline.
class SftpUploadCommand extends SshTaskCommand {
  SftpUploadCommand({
    required String sessionId,
    required this.requestId,
    required this.path,
    required this.bytes,
  }) : super(sessionId);

  final String requestId;
  final String path;
  final Uint8List bytes;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.sftpUpload;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'sessionId': sessionId,
    'requestId': requestId,
    'path': path,
    'bytes': base64Encode(bytes),
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
    this.controlMode = false,
  }) : super(sessionId);

  final String host;
  final int port;
  final String username;

  /// Auth payload, opaque to this module. The task-side router converts it
  /// back to `SshConnectParams.auth`. Keeping it as a map lets us evolve the
  /// auth shape without breaking the wire contract.
  final Map<String, dynamic> authJson;
  final String? title;

  /// Whether the session should enter tmux control mode (`tmux -CC`) on shell
  /// open (#911). The `tmuxControlMode` flag is a per-ISOLATE global; the host
  /// runs in the foreground-task isolate, so a flag flipped in the UI isolate
  /// (settings toggle, or the emulator parity tests) never reaches it. This
  /// carries the UI-isolate's desired state across the gateway so the host
  /// isolate enters control mode for THIS session. Defaults false so the
  /// shipped scrape path is unchanged unless the UI explicitly opts in.
  final bool controlMode;

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
    if (controlMode) 'controlMode': true,
  };
}

class SshDisconnectCommand extends SshTaskCommand {
  const SshDisconnectCommand({required String sessionId}) : super(sessionId);

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.disconnect;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
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
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
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

/// UI → task: a fresh UI-side gateway asks the (already-running) task to
/// re-announce its readiness (#731). When the foreground service OUTLIVES the
/// UI process, a new cold launch builds a not-ready [TaskSshGateway] but
/// `KeepaliveController._startIfStopped` sees the service already running and
/// skips (re)start — so the task's `onStart` never re-fires and no
/// [SshTaskReadyEvent] reaches the new gateway, leaving every `connect`
/// buffered forever. This command is sent via `sendControl` (bypassing the
/// not-ready buffer) so the live task can re-emit [SshTaskReadyEvent] and flip
/// the fresh gateway to ready. Task-global, so [sessionId] is the empty
/// sentinel (mirrors [SshTaskReadyEvent]). Handling on the task side is
/// idempotent — safe to send even when the gateway is already ready.
///
/// [SYNC] paired with [SshTaskReadyEvent] (the task → UI response). The wire
/// contract is single-codebase (both isolates are this Dart module), so the
/// round-trip `toJson`/`fromJson` test in `task_ipc_test.dart` is the sync
/// check — keep this command and its handlers (KeepaliveTaskHandler.onReceiveData,
/// SessionHost._dispatch) in step.
class SshUiHelloCommand extends SshTaskCommand {
  const SshUiHelloCommand() : super('');

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.uiHello;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
}

/// UI → task: actively verify the session's socket is still alive after a
/// background → resume cycle (#737). The task-side `SessionHost` routes this to
/// the hosted controller's `probeLiveness()` — an SSH keepalive ping with a
/// short timeout. A zombie-`connected` session whose socket died half-open
/// during Doze times out → transitions to `softDisconnected` → the existing
/// #517/#590 reconnect path re-opens the shell. A live session replies promptly
/// and stays connected. Per-session, so [sessionId] identifies which session.
class SshResumeProbeCommand extends SshTaskCommand {
  const SshResumeProbeCommand({required String sessionId}) : super(sessionId);

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.resumeProbe;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
}

/// UI → task: user tapped Reconnect on a dropped session (#817). Maps task-side
/// to `SshSessionController.reconnectNow()` — a FORCE reconnect from held params
/// (no auth re-supply) that ignores the resume staleness threshold and overrides
/// a prior user disconnect. Per-session, so [sessionId] identifies which session.
class SshReconnectCommand extends SshTaskCommand {
  const SshReconnectCommand({required String sessionId}) : super(sessionId);

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.reconnect;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
}

/// UI → task: the UI moved to the foreground ([active] = true) or background
/// ([active] = false) (#806). The task-side `SessionHost` gates its periodic
/// snapshot timer on this: backgrounded, the UI is `unbind()`-ed and discards
/// every snapshot, so the unconditional 2s push (a per-session `SshSnapshotEvent`
/// including a ~4KB scrollback UTF-8 decode shipped cross-isolate) is wasted
/// battery. On `active: false` the host stops the timer; on `active: true` it
/// restores the 2s timer AND emits one fresh full snapshot immediately so the
/// UI repaints from current state. Task-global, so [sessionId] is the empty
/// sentinel (mirrors [SshUiHelloCommand]).
class SshSetActiveCommand extends SshTaskCommand {
  const SshSetActiveCommand({
    required this.active,
    this.activeSessionId,
    this.activeHost,
  }) : super('');

  /// True = UI foregrounded (resume periodic snapshots); false = backgrounded
  /// (stop the periodic timer until the next resume). This IS the "foregrounded"
  /// signal the #847 host-level attention policy consumes — the app is
  /// foreground exactly when its periodic-snapshot gate is open.
  final bool active;

  /// The currently front-most (active) session id, or null when none / unknown
  /// (#840 Slice 2). The host uses this together with [active] to SUPPRESS an
  /// attention notification for the session the user is already looking at.
  /// Optional + back-compatible: an older UI that omits it leaves the host's
  /// active-session unknown, which only means it never suppresses (safe).
  final String? activeSessionId;

  /// The HOST of the currently front-most (active) session (#847). The unit of
  /// attention is the HOST (the Claude), not the individual session: while the
  /// app is foregrounded on ANY session to this host, an attention bell from ANY
  /// (possibly different) session to the SAME host is suppressed — the user is
  /// already looking at that Claude. Null when none / unknown (older UI), which
  /// degrades safely to "never host-suppress". Carries no port/auth material.
  final String? activeHost;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.setActive;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'sessionId': sessionId,
    'active': active,
    if (activeSessionId != null) 'activeSessionId': activeSessionId,
    if (activeHost != null) 'activeHost': activeHost,
  };
}

/// UI → task: a FULL tmux `-CC` control-command line, delivered ATOMICALLY
/// (#911, Part C Step 1). The host writes [command] as ONE framed
/// `transport.send` terminated with a single newline, so a multi-token command
/// survives the UI→isolate gateway intact (Part B found a fragmented command's
/// tail hit the pane shell). [command] carries NO trailing newline — the host's
/// `TmuxControlChannel.controlCommand` adds exactly one. Per-session.
class SshControlCommand extends SshTaskCommand {
  const SshControlCommand({required String sessionId, required this.command})
      : super(sessionId);

  /// The complete `-CC` command line (no trailing newline), e.g.
  /// `select-window -t @1` or `next-window`.
  final String command;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.controlCommand;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'command': command,
      };
}

/// UI → task: a high-level tmux WINDOW gesture (#911, Part C Step 2). The host
/// resolves it against the channel's authoritative ordered window list and
/// issues the right control command atomically. [statusCol]/[statusCols] carry
/// the 1-based tap column + the status-line width for [TmuxWindowGesture.
/// tapStatusCol] (ignored for next/previous). Per-session.
class SshTmuxGestureCommand extends SshTaskCommand {
  const SshTmuxGestureCommand({
    required String sessionId,
    required this.gesture,
    this.statusCol = 0,
    this.statusCols = 0,
  }) : super(sessionId);

  final TmuxWindowGesture gesture;

  /// 1-based tap column over the status line (only for [TmuxWindowGesture.
  /// tapStatusCol]).
  final int statusCol;

  /// The status-line width in columns at tap time (only for tapStatusCol).
  final int statusCols;

  @override
  SshTaskCommandKind get kind => SshTaskCommandKind.tmuxGesture;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'sessionId': sessionId,
        'gesture': gesture.name,
        'statusCol': statusCol,
        'statusCols': statusCols,
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
      case SshTaskEventKind.shellReady:
        return SshShellReadyEvent(sessionId: sessionId);
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
      case SshTaskEventKind.sftpUploadDone:
        return SftpUploadDoneEvent(
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
      case SshTaskEventKind.lifecycle:
        return SshLifecycleEvent(line: json['line'] as String);
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
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
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
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
}

/// Task → UI: the PTY shell for [sessionId] is open + writable (#619). Emitted
/// by `SessionHost._ensureShell` right after the shell transport is attached
/// and its output subscription is wired. The UI proxy turns this into a
/// `shellReady` stream tick that the run-on-connect initial command gates on —
/// sending the command on the bare `connected` STATE raced ahead of the shell
/// on slow hosts (ra-server), and `_handleInput` dropped the bytes to
/// scrollback instead of the (not-yet-open) shell.
class SshShellReadyEvent extends SshTaskEvent {
  const SshShellReadyEvent({required String sessionId}) : super(sessionId);

  @override
  SshTaskEventKind get kind => SshTaskEventKind.shellReady;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.name, 'sessionId': sessionId};
}

/// Task → UI: one already-formatted lifecycle telemetry line (#759/#766).
///
/// The lifecycle ring (`clifecycle` / `lifecycleLog`) is written ONLY in the
/// foreground-task isolate (resume-liveness probe outcomes, reconnect
/// decisions). Its ring is a per-isolate static, so the copy the UI-side
/// feedback bundle reads is otherwise EMPTY — the #766 meta-bug where every
/// real device report shipped with NO lifecycle log. The task forwards each
/// `clifecycle` line as one of these events; the UI-side gateway records it
/// into the UI isolate's lifecycle ring so the bundle (assembled in the UI
/// isolate) actually carries it.
///
/// [line] is the fully-formatted ring line (`HH:mm:ss.SSS [where] msg`). It is
/// recorded verbatim on the UI side rather than re-timestamped so the original
/// task-side timestamp is preserved. Task-global, so [sessionId] is the empty
/// sentinel (mirrors [SshTaskReadyEvent]).
///
/// [SYNC] single-codebase wire contract (both isolates are this Dart module);
/// the round-trip test in `task_ipc_test.dart` is the sync check. Keep the
/// forwarder (SessionHost) and the UI-side recorder (FlutterForegroundSshGateway)
/// in step.
class SshLifecycleEvent extends SshTaskEvent {
  const SshLifecycleEvent({required this.line}) : super('');

  /// The fully-formatted lifecycle ring line, preserved verbatim.
  final String line;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.lifecycle;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'sessionId': sessionId,
    'line': line,
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

/// Task → UI: a whole-file upload completed successfully (#892). [totalBytes]
/// is the number of bytes written; the writer seam completes its future on
/// this. Mirrors [SftpDownloadDoneEvent].
class SftpUploadDoneEvent extends SshTaskEvent {
  const SftpUploadDoneEvent({
    required String sessionId,
    required this.requestId,
    required this.totalBytes,
  }) : super(sessionId);

  final String requestId;
  final int totalBytes;

  @override
  SshTaskEventKind get kind => SshTaskEventKind.sftpUploadDone;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'sessionId': sessionId,
    'requestId': requestId,
    'totalBytes': totalBytes,
  };
}

/// Task → UI: an SFTP list/download/upload op failed. Scoped to [requestId] so
/// it surfaces as an in-browser error (snackbar) without disturbing the SSH
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
