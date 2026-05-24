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
  void connect(SshConnectParams params, {String? title}) {
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

  /// Send keystroke / paste bytes to the remote PTY through the gateway.
  void sendInput(Uint8List bytes) {
    gateway.send(SshInputCommand(
      sessionId: sessionId,
      bytes: bytes,
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
    }
  }

  static SshSessionState _decodeState(String name) {
    for (final s in SshSessionState.values) {
      if (s.name == name) return s;
    }
    return SshSessionState.idle;
  }
}
