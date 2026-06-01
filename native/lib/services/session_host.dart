// Task-side session host (#524).
//
// Owns `Map<sessionId, SshSessionController>` and routes UI commands +
// session-controller events through a [TaskSshGateway]. The architectural
// intent (per docs/native-rewrite-lessons-from-pwa.md §3) is that this host
// runs inside the foreground task isolate so the OS holds the controllers
// alive while the UI isolate is paused/swapped away.
//
// In this PR the host lives in the same Dart isolate as the UI (see plan in
// `.traces/trace-issue-524-task-isolate-move-160402/strategy/initial_plan.md`)
// — the gateway abstraction makes the future isolate split a transport-only
// change. From the UI proxy's perspective the host is already "the thing
// across the wire."
//
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:dartssh2/dartssh2.dart';

import '../diagnostics/connect_trace.dart';
import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import '../ssh/sftp_session.dart';
import 'session_messages.dart';
import 'session_notification.dart';
import 'session_notification_poster.dart';
import 'session_signal_detector.dart';
import 'task_ssh_gateway.dart';

/// Factory injected by the UI / tests. Production uses the default which
/// returns a real `SshSessionController` with the default socket opener.
typedef SshControllerFactory = SshSessionController Function();

/// Opens a PTY shell transport over an authenticated client. Production uses
/// [openSshShellTransportSized]; tests inject a fake so the output→event and
/// input→shell wiring runs without a real socket. Returns null if no shell
/// could be opened (caller leaves the terminal idle).
typedef HostShellOpener =
    Future<SshShellTransport?> Function(SSHClient client, int cols, int rows);

Future<SshShellTransport?> _defaultShellOpener(
  SSHClient client,
  int cols,
  int rows,
) => openSshShellTransportSized(client, width: cols, height: rows);

SshSessionController _defaultControllerFactory() => SshSessionController();

/// Holds live SSH controllers, ingests commands from the UI side of the
/// gateway, and emits state/output/snapshot events back.
class SessionHost {
  SessionHost({
    required TaskSshGateway gateway,
    SshControllerFactory? controllerFactory,
    SftpSessionOpener? sftpOpener,
    HostShellOpener? shellOpener,
    SessionNotificationPoster? notificationPoster,
    this.snapshotInterval = const Duration(seconds: 2),
  }) : _gateway = gateway,
       _factory = controllerFactory ?? _defaultControllerFactory,
       _sftpOpener = sftpOpener,
       _shellOpener = shellOpener ?? _defaultShellOpener,
       _notificationPoster = notificationPoster {
    _commandSub = _gateway.incoming.listen(_dispatch);
    _snapshotTimer = Timer.periodic(snapshotInterval, (_) => _pushSnapshots());
    ctrace('task.host', 'ctor: listening; sending SshTaskReadyEvent');
    // Announce readiness as the FIRST task → UI payload (#539). The host is the
    // component that actually consumes commands, so its existence is the true
    // "ready" signal. The UI-side gateway buffers outbound commands until it
    // sees this and then flushes them in order — without it a connect sent
    // during task-isolate spin-up is dropped and the session deadlocks at idle.
    _gateway.send(const SshTaskReadyEvent().toJson());
  }

  final TaskSshGateway _gateway;
  final SshControllerFactory _factory;

  /// Opens an [SftpSession] for a session id (#559). Null in production →
  /// [_defaultSftpOpener] opens an SFTP subsystem over the live `SSHClient`.
  /// Tests inject a fake so the handlers run without a real socket.
  final SftpSessionOpener? _sftpOpener;

  /// Opens the PTY shell once a session reaches `connected`.
  final HostShellOpener _shellOpener;

  /// Surfaces tappable session notifications (#575). Null in tests / on
  /// platforms without a foreground service — the host then runs without
  /// notifications.
  final SessionNotificationPoster? _notificationPoster;

  /// How often a snapshot is pushed to the UI side. Tests use a short
  /// interval; production defaults to two seconds.
  final Duration snapshotInterval;

  StreamSubscription<Map<String, dynamic>>? _commandSub;
  Timer? _snapshotTimer;
  bool _disposed = false;

  final Map<String, _HostedSession> _sessions = {};

  /// Sessions visible to tests + the future audit screen wiring.
  Iterable<String> get sessionIds => _sessions.keys;

  /// Per-session metrics. Returns null when the session isn't hosted.
  SessionMetrics? metricsOf(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) return null;
    return s.metrics;
  }

  void _dispatch(Map<String, dynamic> payload) {
    if (_disposed) return;
    ctrace('task.host', 'dispatch type=${payload['type'] ?? '?'}');
    SshTaskCommand cmd;
    try {
      cmd = SshTaskCommand.fromJson(payload);
    } catch (e) {
      ctrace('task.host', 'dispatch: malformed — $e');
      // Unknown shape — surface via error event so the UI side can log.
      final sid = payload['sessionId'] as String? ?? '';
      _gateway.send(
        SshErrorEvent(
          sessionId: sid,
          message: 'malformed command: $e',
        ).toJson(),
      );
      return;
    }
    switch (cmd) {
      case SshConnectCommand():
        _handleConnect(cmd);
      case SshDisconnectCommand():
        _handleDisconnect(cmd);
      case SshInputCommand():
        _handleInput(cmd);
      case SshResizeCommand():
        final s = _sessions[cmd.sessionId];
        if (s != null) {
          s.metrics.lastCols = cmd.cols;
          s.metrics.lastRows = cmd.rows;
          // Resize the live PTY so the remote shell wraps to the viewport.
          try {
            s.shell?.resize(cmd.cols, cmd.rows);
          } catch (_) {
            // dartssh2 throws on non-positive dims; the next real resize fixes it.
          }
        }
      case SshRequestSnapshotCommand():
        final s = _sessions[cmd.sessionId];
        if (s != null) _emitSnapshot(cmd.sessionId, s);
      case SshHostKeyDecisionCommand():
        _handleHostKeyDecision(cmd);
      case SftpListCommand():
        _handleSftpList(cmd);
      case SftpDownloadCommand():
        _handleSftpDownload(cmd);
    }
  }

  void _handleHostKeyDecision(SshHostKeyDecisionCommand cmd) {
    final hosted = _sessions[cmd.sessionId];
    if (hosted == null) return;
    // The controller owns the pending Completer + trust-on-first-use store;
    // forward the user's decision so it can resolve `onVerifyHostKey`.
    if (cmd.accepted) {
      hosted.controller.acceptHostKey();
    } else {
      hosted.controller.rejectHostKey();
    }
  }

  void _handleConnect(SshConnectCommand cmd) {
    if (_sessions.containsKey(cmd.sessionId)) {
      // Already hosted — emit the current state so the UI can sync.
      _emitState(cmd.sessionId, _sessions[cmd.sessionId]!.controller);
      return;
    }
    final controller = _factory();
    // Human label for notifications (#575): prefer the saved profile title, fall
    // back to user@host:port (mirrors SessionEntry.label).
    final label = (cmd.title != null && cmd.title!.isNotEmpty)
        ? cmd.title!
        : '${cmd.username}@${cmd.host}:${cmd.port}';
    final hosted = _HostedSession(controller: controller, label: label);
    // Detector scans this session's PTY output for OSC-9/BEL "ready" signals.
    hosted.signalDetector = SessionSignalDetector(
      onSignal: (signal) => _onSessionSignal(cmd.sessionId, hosted, signal),
    );
    _sessions[cmd.sessionId] = hosted;

    // Forward state transitions back as events.
    var prevState = SshSessionState.idle;
    hosted.stateSub = controller.stream.listen((data) {
      hosted.metrics.state = data.state.name;
      if (data.state == SshSessionState.reconnecting) {
        hosted.metrics.reconnectCount += 1;
        hosted.metrics.lastReconnectAtMs =
            DateTime.now().millisecondsSinceEpoch;
      }
      // Surface the unreachable classification for the audit screen (#551).
      hosted.metrics.lastErrorUnreachable = controller.lastErrorUnreachable;
      _maybeEmitHostKeyChallenge(cmd.sessionId, hosted, data);
      _emitStateData(cmd.sessionId, data);
      // Verbose connect logging in the terminal itself: surface each phase so
      // a stall shows WHERE it stopped instead of a blank cursor.
      if (data.state != prevState) {
        _emitConnectStatus(cmd.sessionId, data);
        // #575: a session that STOPS (disconnected/failed) posts a "disconnected"
        // notification so the user knows it dropped even while in another app.
        if (data.state == SshSessionState.disconnected ||
            data.state == SshSessionState.failed) {
          _postSessionNotification(
            cmd.sessionId,
            hosted,
            SessionSignalKind.stopped,
          );
        }
        prevState = data.state;
      }
      // Drop the prior shell the instant the transport leaves `connected`
      // (reconnecting / softDisconnected / failed / disconnected). The old PTY
      // belongs to a dead `SSHClient`; relying on the async `transport.done`
      // callback to clear `hosted.shell` is a RACE — on auto-reconnect the new
      // `connected` can arrive before that microtask runs, so `_ensureShell`
      // sees a non-null (dead) handle, no-ops, and zero bytes flow while the
      // UI shows `connected` (#590, the stale-shell dead-terminal). Clearing
      // here, synchronously, guarantees the next `connected` opens a FRESH
      // shell whose output re-pipes to the terminal.
      if (data.state != SshSessionState.connected) {
        _dropShell(hosted);
      }
      // Open the PTY shell the first time we reach `connected` (and re-open
      // after a reconnect, which re-enters `connected`). Without this the
      // terminal screen mounts but never receives a single byte — the device
      // "blank terminal with a cursor" hang. The in-UI SshShell path was
      // disabled by the #533 task-isolate migration and the task-side shell
      // was never wired until now.
      if (data.state == SshSessionState.connected) {
        unawaited(_ensureShell(cmd.sessionId, hosted));
      }
    });

    final params = SshConnectParams(
      host: cmd.host,
      port: cmd.port,
      username: cmd.username,
      auth: _decodeAuth(cmd.authJson),
    );
    // Fire connect; failures surface through the state stream.
    ctrace(
      'task.host',
      'connect sid=${cmd.sessionId} → controller.connect(${cmd.host}:${cmd.port})',
    );
    unawaited(controller.connect(params));
  }

  void _handleDisconnect(SshDisconnectCommand cmd) {
    final hosted = _sessions.remove(cmd.sessionId);
    if (hosted == null) return;
    unawaited(_teardown(cmd.sessionId, hosted));
  }

  void _handleInput(SshInputCommand cmd) {
    final hosted = _sessions[cmd.sessionId];
    if (hosted == null) return;
    hosted.metrics.bytesOut += cmd.bytes.length;
    // Write keystrokes to the live PTY. Before the shell is open we drop into
    // the scrollback "echo" so the audit still shows activity.
    final shell = hosted.shell;
    if (shell != null) {
      shell.send(cmd.bytes);
    } else {
      hosted.appendScrollback(cmd.bytes);
    }
  }

  Future<void> _teardown(String sessionId, _HostedSession hosted) async {
    await hosted.stateSub?.cancel();
    hosted.stateSub = null;
    await hosted.shellSub?.cancel();
    hosted.shellSub = null;
    final shell = hosted.shell;
    hosted.shell = null;
    if (shell != null) {
      try {
        shell.close();
      } catch (_) {
        /* ignore */
      }
    }
    final sftp = hosted.sftp;
    hosted.sftp = null;
    if (sftp != null) {
      try {
        await sftp.close();
      } catch (_) {
        /* ignore */
      }
    }
    try {
      await hosted.controller.dispose();
    } catch (_) {
      /* ignore */
    }
    _gateway.send(SshClosedEvent(sessionId: sessionId).toJson());
  }

  /// Synchronously drop the live shell handle for [hosted] when the session
  /// leaves `connected`. Cancels the output subscription and closes the PTY so
  /// the NEXT `connected` (auto-reconnect) re-opens a fresh shell via
  /// [_ensureShell] instead of reusing a dead handle (#590). Idempotent: a
  /// no-op when no shell is open. `shellOpening` is also cleared so an in-flight
  /// open from the prior connection can't win a late race and re-attach a stale
  /// transport.
  void _dropShell(_HostedSession hosted) {
    hosted.shellOpening = false;
    // Invalidate any in-flight open: a `_shellOpener` await that started under
    // the prior connection must NOT attach its (now stale) transport after we
    // reconnect. `_ensureShell` re-checks the generation after its await.
    hosted.shellGeneration += 1;
    final sub = hosted.shellSub;
    hosted.shellSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    final shell = hosted.shell;
    hosted.shell = null;
    if (shell != null) {
      try {
        shell.close();
      } catch (_) {
        /* ignore */
      }
    }
  }

  /// Open the PTY shell for [sessionId] once authenticated, and pipe its
  /// output back to the UI terminal as [SshOutputEvent]s. Idempotent: a second
  /// call while a shell is open or opening is a no-op (covers the reconnect
  /// re-enter-connected case). On open failure the error is surfaced in the
  /// terminal so the user sees it instead of a blank cursor.
  Future<void> _ensureShell(String sessionId, _HostedSession hosted) async {
    if (hosted.shell != null || hosted.shellOpening) return;
    final client = hosted.controller.client;
    if (client == null) return;
    hosted.shellOpening = true;
    final openGen = hosted.shellGeneration;
    try {
      final cols = hosted.metrics.lastCols ?? 80;
      final rows = hosted.metrics.lastRows ?? 24;
      final transport = await _shellOpener(client, cols, rows);
      if (transport == null) {
        _emitStatus(sessionId, '\r\n[mobissh] no shell channel available\r\n');
        return;
      }
      // The session may have been torn down — or dropped + reconnected (#590) —
      // while we awaited the channel. If the generation moved, this transport
      // belongs to a connection that's already gone: close it and bail so the
      // post-reconnect `_ensureShell` opens the live one.
      if (!_sessions.containsKey(sessionId) ||
          hosted.shellGeneration != openGen) {
        try {
          transport.close();
        } catch (_) {
          /* ignore */
        }
        return;
      }
      hosted.shell = transport;
      hosted.shellSub = transport.output.listen(
        (bytes) {
          hosted.metrics.bytesIn += bytes.length;
          hosted.appendScrollback(bytes);
          // #575: scan PTY output for OSC-9/BEL "ready for review" signals.
          hosted.signalDetector?.feed(bytes);
          _gateway.send(
            SshOutputEvent(sessionId: sessionId, bytes: bytes).toJson(),
          );
        },
        onError: (Object e, StackTrace st) {
          _emitStatus(sessionId, '\r\n[mobissh] shell stream error: $e\r\n');
        },
      );
      // Drop the shell when the remote channel closes so a reconnect re-opens.
      // Guard with the generation: a late `done` from THIS transport must not
      // null out a shell that a subsequent reconnect already re-opened (#590).
      final doneGen = hosted.shellGeneration;
      unawaited(
        transport.done.then((_) {
          if (hosted.shellGeneration != doneGen) return;
          hosted.shellSub?.cancel();
          hosted.shellSub = null;
          hosted.shell = null;
        }),
      );
    } catch (e) {
      _emitStatus(sessionId, '\r\n[mobissh] could not open shell: $e\r\n');
    } finally {
      hosted.shellOpening = false;
    }
  }

  /// Emit a human-readable status line into the terminal stream (verbose
  /// connect logging). Routed through [SshOutputEvent] so it appears in the
  /// UI terminal exactly where the shell output would.
  void _emitStatus(String sessionId, String text) {
    _gateway.send(
      SshOutputEvent(
        sessionId: sessionId,
        bytes: Uint8List.fromList(utf8.encode(text)),
      ).toJson(),
    );
  }

  /// One concise terminal line per connect phase so a stall is visible.
  void _emitConnectStatus(String sessionId, SshSessionData data) {
    final String? line;
    switch (data.state) {
      case SshSessionState.connecting:
        line =
            '[mobissh] connecting to ${data.host ?? '?'}:${data.port ?? '?'}…';
      case SshSessionState.authenticating:
        line = '[mobissh] host key OK — authenticating…';
      case SshSessionState.connected:
        line = '[mobissh] authenticated — opening shell…';
      case SshSessionState.reconnecting:
        line = '[mobissh] connection dropped — reconnecting…';
      case SshSessionState.failed:
        line = '[mobissh] failed: ${data.error ?? 'unknown error'}';
      default:
        line = null;
    }
    if (line != null) _emitStatus(sessionId, '$line\r\n');
  }

  /// A detector fired a "ready" signal from this session's PTY output (#575).
  void _onSessionSignal(
    String sessionId,
    _HostedSession hosted,
    SessionSignal signal,
  ) {
    _postSessionNotification(
      sessionId,
      hosted,
      signal.kind,
      message: signal.message,
    );
  }

  /// Post a tappable notification for [sessionId] (#575). No-op when no poster
  /// is wired (tests / desktop). Errors are swallowed — a failed notification
  /// must never disturb the SSH session.
  void _postSessionNotification(
    String sessionId,
    _HostedSession hosted,
    SessionSignalKind kind, {
    String? message,
  }) {
    final poster = _notificationPoster;
    if (poster == null) return;
    unawaited(
      poster
          .notify(
            sessionId: sessionId,
            label: hosted.label,
            kind: kind,
            message: message,
          )
          .catchError((Object e) {
            ctrace('task.host', 'notify FAILED sid=$sessionId — $e');
          }),
    );
  }

  // -------------------------------------------------------------------------
  // SFTP region (#559) — additive. Sits alongside the connect/keepalive/
  // reconnect handlers above and never mutates the SSH lifecycle state machine.
  // Each op opens (lazily) an [SftpSession] over the session's authenticated
  // `SSHClient` and routes results back as request-id-scoped events so a failed
  // list/download surfaces in the browser without disturbing the live shell.
  // -------------------------------------------------------------------------

  /// Open (or reuse) the [SftpSession] for [sessionId]. Returns null if the
  /// session isn't hosted or has no authenticated client yet.
  Future<SftpSession?> _ensureSftp(String sessionId) async {
    final hosted = _sessions[sessionId];
    if (hosted == null) return null;
    if (hosted.sftp != null) return hosted.sftp;
    final opener = _sftpOpener ?? _defaultSftpOpener;
    final session = await opener(sessionId);
    // Re-check: an interleaved open could have set it; the controller may also
    // have been torn down while we awaited. Prefer the already-cached one.
    if (hosted.sftp != null) {
      if (session != null) await session.close();
      return hosted.sftp;
    }
    hosted.sftp = session;
    return session;
  }

  /// Default opener: grab the authenticated `SSHClient` from the controller and
  /// open an SFTP subsystem channel over it. Returns null when the session
  /// isn't connected (no client) so the caller emits a friendly error.
  Future<SftpSession?> _defaultSftpOpener(String sessionId) async {
    final hosted = _sessions[sessionId];
    final client = hosted?.controller.client;
    if (client == null) return null;
    final SftpClient sftp = await client.sftp();
    return DartSshSftpSession(sftp);
  }

  Future<void> _handleSftpList(SftpListCommand cmd) async {
    try {
      final sftp = await _ensureSftp(cmd.sessionId);
      if (sftp == null) {
        _emitSftpError(cmd.sessionId, cmd.requestId, 'Session not connected');
        return;
      }
      final entries = await sftp.list(cmd.path);
      if (_disposed) return;
      _gateway.send(
        SftpListingEvent(
          sessionId: cmd.sessionId,
          requestId: cmd.requestId,
          path: cmd.path,
          entries: entries,
        ).toJson(),
      );
    } catch (e) {
      ctrace('task.host', 'sftp ls FAILED path=${cmd.path} — $e');
      _emitSftpError(cmd.sessionId, cmd.requestId, 'List failed: $e');
    }
  }

  Future<void> _handleSftpDownload(SftpDownloadCommand cmd) async {
    try {
      final sftp = await _ensureSftp(cmd.sessionId);
      if (sftp == null) {
        _emitSftpError(cmd.sessionId, cmd.requestId, 'Session not connected');
        return;
      }
      // Resolve the size up front so the UI can render a determinate bar; a
      // null size just means an indeterminate spinner.
      final totalBytes = await sftp.sizeOf(cmd.path);
      final written = await sftp.download(
        cmd.path,
        onChunk: (chunk, offset) {
          if (_disposed) return;
          _gateway.send(
            SftpDownloadChunkEvent(
              sessionId: cmd.sessionId,
              requestId: cmd.requestId,
              bytes: chunk,
              offset: offset,
              totalBytes: totalBytes,
            ).toJson(),
          );
        },
      );
      if (_disposed) return;
      _gateway.send(
        SftpDownloadDoneEvent(
          sessionId: cmd.sessionId,
          requestId: cmd.requestId,
          totalBytes: written,
        ).toJson(),
      );
    } catch (e) {
      ctrace('task.host', 'sftp download FAILED path=${cmd.path} — $e');
      _emitSftpError(cmd.sessionId, cmd.requestId, 'Download failed: $e');
    }
  }

  void _emitSftpError(String sessionId, String requestId, String message) {
    if (_disposed) return;
    _gateway.send(
      SftpErrorEvent(
        sessionId: sessionId,
        requestId: requestId,
        message: message,
      ).toJson(),
    );
  }

  /// Emit a host-key challenge to the UI when the controller surfaces a fresh
  /// untrusted key (#536). Deduped per pending fingerprint so a single
  /// awaitingHostKey transition produces exactly one challenge — repeated
  /// state emits (e.g. banner updates) don't re-prompt.
  void _maybeEmitHostKeyChallenge(
    String sessionId,
    _HostedSession hosted,
    SshSessionData data,
  ) {
    final pending = data.pendingHostKey;
    if (pending == null) {
      hosted.challengedFingerprint = null;
      return;
    }
    if (hosted.challengedFingerprint == pending.fingerprint) return;
    hosted.challengedFingerprint = pending.fingerprint;
    _gateway.send(
      SshHostKeyChallengeEvent(
        sessionId: sessionId,
        host: pending.host,
        port: pending.port,
        keyType: pending.keyType,
        fingerprint: pending.fingerprint,
      ).toJson(),
    );
  }

  void _emitState(String sessionId, SshSessionController controller) {
    _emitStateData(sessionId, controller.data);
  }

  void _emitStateData(String sessionId, SshSessionData data) {
    _gateway.send(
      SshStateEvent(
        sessionId: sessionId,
        state: data.state.name,
        error: data.error,
        host: data.host,
        port: data.port,
        username: data.username,
      ).toJson(),
    );
  }

  void _pushSnapshots() {
    if (_disposed) return;
    for (final entry in _sessions.entries) {
      _emitSnapshot(entry.key, entry.value);
    }
  }

  void _emitSnapshot(String sessionId, _HostedSession hosted) {
    _gateway.send(
      SshSnapshotEvent(
        sessionId: sessionId,
        state: hosted.controller.data.state.name,
        bytesIn: hosted.metrics.bytesIn,
        bytesOut: hosted.metrics.bytesOut,
        lastKeepaliveRttMs: hosted.metrics.lastKeepaliveRttMs,
        reconnectCount: hosted.metrics.reconnectCount,
        lastReconnectAtMs: hosted.metrics.lastReconnectAtMs,
        scrollbackTail: hosted.scrollbackTailString(),
      ).toJson(),
    );
  }

  /// Inject output bytes from the SSH session's PTY into the host so the
  /// scrollback cache fills + the audit metrics tick. Phase 2's SshShell
  /// would wire its output stream through here in the foreground-task port.
  /// Exposed for tests.
  void ingestOutputForTest(String sessionId, Uint8List bytes) {
    final hosted = _sessions[sessionId];
    if (hosted == null) return;
    hosted.metrics.bytesIn += bytes.length;
    hosted.appendScrollback(bytes);
    _gateway.send(SshOutputEvent(sessionId: sessionId, bytes: bytes).toJson());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    await _commandSub?.cancel();
    _commandSub = null;
    for (final entry in _sessions.entries) {
      await _teardown(entry.key, entry.value);
    }
    _sessions.clear();
  }

  /// Synchronously cancel the periodic snapshot timer + drop hosted
  /// controllers without awaiting any inner async teardown. Exists for
  /// widget tests that can't safely `await dispose()` inside the testWidgets
  /// body (the test framework's pending-timer invariant fires before async
  /// teardowns complete). Production code uses [dispose].
  @visibleForTesting
  void disposeSyncForTest() {
    _disposed = true;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _commandSub?.cancel();
    _commandSub = null;
    for (final hosted in _sessions.values) {
      hosted.stateSub?.cancel();
      hosted.stateSub = null;
      // Cancel the controller's own timers (ready/reconnect) so the framework's
      // pending-timer invariant doesn't fire. `disconnect()` is sync when no
      // live SSHClient exists (the stub factory's socket never opens), so the
      // fire-and-forget is safe and complete by the time the test body ends.
      unawaited(hosted.controller.disconnect());
    }
    _sessions.clear();
  }

  static SshAuth _decodeAuth(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == 'password') {
      final pw = json['password'] as String;
      // Presence trace (length only — never the value): confirms the password
      // survived the UI→task IPC. Compare against ui.form's pwLen (#542/#543).
      ctrace('task.host', 'decodeAuth password pwLen=${pw.length}');
      return SshAuth.password(pw);
    }
    if (type == 'key') {
      final pemB64 = json['pem'] as String;
      final pem = Uint8List.fromList(base64Decode(pemB64));
      ctrace('task.host', 'decodeAuth key pemBytes=${pem.length}');
      return SshAuth.key(pem, passphrase: json['passphrase'] as String?);
    }
    throw FormatException('unknown auth type: $type');
  }

  /// Encode an [SshAuth] back to the wire format. Public for tests + the
  /// UI proxy.
  static Map<String, dynamic> encodeAuth(SshAuth auth) {
    if (auth is SshAuthPassword) {
      return {'type': 'password', 'password': auth.password};
    }
    if (auth is SshAuthKey) {
      return {
        'type': 'key',
        'pem': base64Encode(auth.pem),
        if (auth.passphrase != null) 'passphrase': auth.passphrase,
      };
    }
    throw ArgumentError('unsupported SshAuth: $auth');
  }
}

/// Mutable per-session telemetry. Visible for tests + the Connection Audit
/// screen.
class SessionMetrics {
  String state = 'idle';
  int bytesIn = 0;
  int bytesOut = 0;
  int? lastKeepaliveRttMs;
  int reconnectCount = 0;
  int? lastReconnectAtMs;

  /// Whether the most recent reconnect was triggered by a host-unreachable
  /// error (no route / refused / timed out / "no SSH response"). The audit
  /// screen distinguishes "host asleep, fast-retrying" from a generic blip (#551).
  bool lastErrorUnreachable = false;
  int? lastCols;
  int? lastRows;
}

class _HostedSession {
  _HostedSession({required this.controller, this.label = ''});

  final SshSessionController controller;

  /// Human label for notifications (#575): profile title or user@host:port.
  final String label;

  /// Per-session PTY signal scanner (#575). Null until a connect sets it.
  SessionSignalDetector? signalDetector;

  StreamSubscription<SshSessionData>? stateSub;
  final SessionMetrics metrics = SessionMetrics();

  /// Lazily-opened SFTP subsystem over this session's `SSHClient` (#559).
  /// Opened on the first list/download command, reused after, closed on
  /// teardown. Null until the first SFTP op.
  SftpSession? sftp;

  /// Live PTY shell channel, opened on first `connected`. Output is piped to
  /// the UI terminal via SshOutputEvent; input commands write here. Null until
  /// the shell is open (and again after the channel closes).
  SshShellTransport? shell;
  StreamSubscription<Uint8List>? shellSub;
  bool shellOpening = false;

  /// Monotonic token bumped each time the shell is dropped (#590). An in-flight
  /// [SessionHost._ensureShell] open captures this before awaiting and discards
  /// its transport if the token changed — so a stale open from a dropped
  /// connection can't re-attach after a reconnect.
  int shellGeneration = 0;

  /// Fingerprint of the host-key challenge already forwarded to the UI, so a
  /// single awaitingHostKey transition emits exactly one challenge (#536).
  String? challengedFingerprint;
  final BytesBuilder _scrollback = BytesBuilder(copy: false);

  /// Append raw bytes to the scrollback cache and cap the buffer at ~4KB
  /// (the cap is enforced by [scrollbackTailString], not here, so the latest
  /// bytes always win).
  void appendScrollback(Uint8List bytes) {
    _scrollback.add(bytes);
  }

  /// Return the last [maxBytes] of scrollback decoded as UTF-8 (malformed
  /// sequences are replaced). When the buffer is truncated, we re-trim at
  /// the first newline so partial escape sequences don't corrupt the cached
  /// view. When the buffer fits whole, the full content is returned.
  String scrollbackTailString({int maxBytes = 4096}) {
    final raw = _scrollback.toBytes();
    if (raw.isEmpty) return '';
    final truncated = raw.length > maxBytes;
    final tail = truncated
        ? Uint8List.sublistView(raw, raw.length - maxBytes)
        : raw;
    var decoded = utf8.decode(tail, allowMalformed: true);
    if (truncated) {
      final firstNl = decoded.indexOf('\n');
      if (firstNl >= 0 && firstNl < decoded.length - 1) {
        decoded = decoded.substring(firstNl + 1);
      }
    }
    return decoded;
  }
}
