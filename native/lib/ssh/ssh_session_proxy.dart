// UI-side proxy for a task-isolate-hosted SSH session (#524).
//
// Mirrors the public surface of [SshSessionController] (data, stream,
// connect/disconnect, etc.) but does not own the underlying `SSHClient`.
// All commands forward through a [TaskSshGateway]; all state arrives as
// events through the same gateway.
//
// The proxy caches the latest [SshSessionData] + last snapshot so the UI can
// rebind in <500ms after `AppLifecycleState.resumed` — the snapshot's
// `scrollbackTail` becomes the initial render frame.

import 'dart:async';
import 'dart:typed_data';

import '../services/session_host.dart';
import '../services/session_messages.dart';
import '../services/task_ssh_gateway.dart';
import 'ssh_connect_params.dart';
import 'ssh_session.dart';

/// Cached snapshot the proxy holds across UI pause/resume.
class ProxySnapshot {
  const ProxySnapshot({
    required this.state,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.lastKeepaliveRttMs,
    this.reconnectCount = 0,
    this.lastReconnectAtMs,
    this.scrollbackTail = '',
  });

  final SshSessionState state;
  final int bytesIn;
  final int bytesOut;
  final int? lastKeepaliveRttMs;
  final int reconnectCount;
  final int? lastReconnectAtMs;
  final String scrollbackTail;
}

/// UI-side proxy. One instance per `sessionId`.
class SshSessionProxy {
  SshSessionProxy({
    required this.sessionId,
    required this.gateway,
  }) {
    _bind();
  }

  final String sessionId;
  final TaskSshGateway gateway;

  final StreamController<SshSessionData> _dataCtrl =
      StreamController<SshSessionData>.broadcast();
  final StreamController<Uint8List> _outputCtrl =
      StreamController<Uint8List>.broadcast();

  /// Shell-ready ticks (#619). Emits once each time the task side opens the
  /// PTY shell (initial connect + every reconnect re-open). The run-on-connect
  /// initial command gates on this, NOT the bare `connected` state, so the
  /// command can't race ahead of a slow host's shell-open and get dropped.
  final StreamController<void> _shellReadyCtrl =
      StreamController<void>.broadcast();

  /// SFTP events (#559): directory listings, download chunks/done, errors —
  /// all keyed by `requestId`. The file browser subscribes and filters by its
  /// own in-flight request id.
  final StreamController<SshTaskEvent> _sftpCtrl =
      StreamController<SshTaskEvent>.broadcast();

  SshSessionData _data = const SshSessionData();
  ProxySnapshot _snapshot =
      const ProxySnapshot(state: SshSessionState.idle);
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  bool _bound = false;
  bool _disposed = false;

  /// Most recent state snapshot. Always non-null.
  SshSessionData get data => _data;

  /// Stream of state changes. Emits the current snapshot on every transition.
  Stream<SshSessionData> get stream => _dataCtrl.stream;

  /// PTY output bytes streamed from the task side. Subscribers feed these
  /// into `Terminal.write(...)`.
  Stream<Uint8List> get output => _outputCtrl.stream;

  /// Fires when the task side reports the PTY shell is open + writable (#619).
  /// One tick per shell open. The run-on-connect [InitialCommandRunner] listens
  /// here instead of on the `connected` state so the command lands in the live
  /// shell rather than racing ahead of it on a slow host.
  Stream<void> get shellReady => _shellReadyCtrl.stream;

  /// SFTP events from the task side (#559). Emits [SftpListingEvent],
  /// [SftpDownloadChunkEvent], [SftpDownloadDoneEvent], [SftpErrorEvent].
  /// The file browser filters by request id.
  Stream<SshTaskEvent> get sftpEvents => _sftpCtrl.stream;

  /// Latest snapshot received from the task side. Used by the audit screen
  /// and by `rebind()` to redraw without waiting for the next emit.
  ProxySnapshot get snapshot => _snapshot;

  /// Subscribe to incoming events from the task side. Idempotent.
  void _bind() {
    if (_bound || _disposed) return;
    _bound = true;
    _eventSub = gateway.incoming.listen(_handleEvent);
  }

  /// Stop listening for events. The task continues running; the UI just
  /// drops its subscription so it doesn't accumulate updates while paused.
  ///
  /// Synchronous-by-design: `cancel()` is fire-and-forget so the
  /// lifecycle-state listener can call this without awaiting (the widget
  /// framework dispatches lifecycle changes synchronously).
  void unbind() {
    if (!_bound) return;
    _bound = false;
    _eventSub?.cancel();
    _eventSub = null;
  }

  /// Re-subscribe to events and request a fresh snapshot. Called on
  /// `AppLifecycleState.resumed`. Yields the cached `data` immediately so
  /// the UI can paint within the 500ms budget regardless of how long the
  /// snapshot round-trip takes.
  void rebind() {
    if (_disposed) return;
    _bind();
    gateway.send(SshRequestSnapshotCommand(sessionId: sessionId).toJson());
    // Re-emit the cached snapshot so listeners (e.g. the terminal screen)
    // immediately repaint with whatever we last knew.
    if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
  }

  /// Send a connect command across the gateway. The task-side host turns
  /// this into `SshSessionController.connect(...)`.
  ///
  /// Returns a `Future<void>` that completes synchronously — the gateway is
  /// fire-and-forget; state updates arrive asynchronously through [stream].
  /// The `Future`-shaped return keeps the proxy drop-in compatible with
  /// `SshSessionController.connect`, so call sites that previously awaited
  /// the controller call continue to compile (#533).
  Future<void> connect(SshConnectParams params, {String? title}) async {
    gateway.send(SshConnectCommand(
      sessionId: sessionId,
      host: params.host,
      port: params.port,
      username: params.username,
      authJson: SessionHost.encodeAuth(params.auth),
      title: title,
    ).toJson());
  }

  /// Send a disconnect command.
  void disconnect() {
    gateway.send(SshDisconnectCommand(sessionId: sessionId).toJson());
  }

  /// Accept a pending host-key prompt (#536). Sends a decision command to the
  /// task side (which trusts the key + resolves the controller's verify
  /// callback) and clears the local `pendingHostKey` so the dialog dismisses.
  void acceptHostKey() {
    _sendHostKeyDecision(true);
  }

  /// Reject a pending host-key prompt (#536). The task-side controller aborts
  /// the connect via its existing "Host key rejected" failure path.
  void rejectHostKey() {
    _sendHostKeyDecision(false);
  }

  void _sendHostKeyDecision(bool accepted) {
    if (_disposed) return;
    if (_data.pendingHostKey == null) return;
    gateway.send(SshHostKeyDecisionCommand(
      sessionId: sessionId,
      accepted: accepted,
    ).toJson());
    // Optimistically clear the prompt; the authoritative state (authenticating
    // / failed) arrives as a follow-up state event from the task side.
    _data = _data.copyWith(clearPendingHostKey: true);
    if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
  }

  /// Send keystroke / paste bytes to the remote PTY through the gateway.
  void sendInput(Uint8List bytes) {
    gateway.send(SshInputCommand(
      sessionId: sessionId,
      bytes: bytes,
    ).toJson());
  }

  /// Request a directory listing over SFTP (#559). The matching
  /// [SftpListingEvent] (or [SftpErrorEvent]) arrives on [sftpEvents] with the
  /// same [requestId].
  void sftpList({required String requestId, required String path}) {
    gateway.send(SftpListCommand(
      sessionId: sessionId,
      requestId: requestId,
      path: path,
    ).toJson());
  }

  /// Request a single-file download over SFTP (#559). Chunks + completion
  /// arrive on [sftpEvents] keyed by [requestId].
  void sftpDownload({required String requestId, required String path}) {
    gateway.send(SftpDownloadCommand(
      sessionId: sessionId,
      requestId: requestId,
      path: path,
    ).toJson());
  }

  /// Send a PTY resize to the remote.
  void sendResize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    gateway.send(SshResizeCommand(
      sessionId: sessionId,
      cols: cols,
      rows: rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    ).toJson());
  }

  /// Tear down the proxy. The task-side session continues running unless
  /// the caller also dispatched a [disconnect].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    if (!_dataCtrl.isClosed) await _dataCtrl.close();
    if (!_outputCtrl.isClosed) await _outputCtrl.close();
    if (!_shellReadyCtrl.isClosed) await _shellReadyCtrl.close();
    if (!_sftpCtrl.isClosed) await _sftpCtrl.close();
  }

  void _handleEvent(Map<String, dynamic> payload) {
    if (_disposed) return;
    // Filter to events for this session id (the gateway is broadcast).
    final sid = payload['sessionId'] as String?;
    if (sid != sessionId) return;
    SshTaskEvent event;
    try {
      event = SshTaskEvent.fromJson(payload);
    } catch (_) {
      return;
    }
    switch (event) {
      case SshStateEvent():
        final next = _decodeState(event.state);
        _data = _data.copyWith(
          state: next,
          error: event.error,
          host: event.host,
          port: event.port,
          username: event.username,
        );
        if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
      case SshOutputEvent():
        if (!_outputCtrl.isClosed) _outputCtrl.add(event.bytes);
      case SshSnapshotEvent():
        _snapshot = ProxySnapshot(
          state: _decodeState(event.state),
          bytesIn: event.bytesIn,
          bytesOut: event.bytesOut,
          lastKeepaliveRttMs: event.lastKeepaliveRttMs,
          reconnectCount: event.reconnectCount,
          lastReconnectAtMs: event.lastReconnectAtMs,
          scrollbackTail: event.scrollbackTail,
        );
      case SshClosedEvent():
        _data = _data.copyWith(state: SshSessionState.disconnected);
        if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
      case SshErrorEvent():
        _data = _data.copyWith(
          state: SshSessionState.failed,
          error: event.message,
        );
        if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
      case SshHostKeyChallengeEvent():
        _data = _data.copyWith(
          state: SshSessionState.awaitingHostKey,
          pendingHostKey: PendingHostKey(
            host: event.host,
            port: event.port,
            keyType: event.keyType,
            fingerprint: event.fingerprint,
          ),
        );
        if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
      case SshShellReadyEvent():
        // The task side opened the PTY shell (#619). Tick the shell-ready
        // stream so the run-on-connect command fires now that stdin is wired.
        if (!_shellReadyCtrl.isClosed) _shellReadyCtrl.add(null);
      case SshTaskReadyEvent():
        // Task-global readiness signal (#539). Per-session proxies ignore it —
        // the UI-side gateway already consumed it to flush buffered commands.
        // It only reaches here for the matching (empty) sessionId, which no
        // real proxy uses, but handle it for switch exhaustiveness.
        break;
      case SftpListingEvent():
      case SftpDownloadChunkEvent():
      case SftpDownloadDoneEvent():
      case SftpErrorEvent():
        // SFTP results (#559) — forward to the file browser, which matches by
        // request id. They never touch the SSH lifecycle state.
        if (!_sftpCtrl.isClosed) _sftpCtrl.add(event);
    }
  }

  static SshSessionState _decodeState(String name) {
    for (final s in SshSessionState.values) {
      if (s.name == name) return s;
    }
    return SshSessionState.idle;
  }
}
