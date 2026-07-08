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

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../diagnostics/connect_trace.dart';
import '../services/session_host.dart';
import '../services/session_messages.dart';
import '../services/task_ssh_gateway.dart';
import '../terminal/tmux_control_mode_flag.dart';
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
  SshSessionProxy({required this.sessionId, required this.gateway}) {
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
  ProxySnapshot _snapshot = const ProxySnapshot(state: SshSessionState.idle);
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  bool _bound = false;
  bool _disposed = false;

  /// The PTY grid dimensions LAST SENT for this session via [sendResize] (#848).
  /// `null` until the first resize. The no-op guard drops a resize whose
  /// (cols, rows) match these — re-sending identical dims to the PTY is wasteful
  /// AND makes tmux redraw (the duplicated/ghosted content in the keyboard-hide
  /// resize storm). One pair per proxy → the guard is inherently per-session.
  int? _lastSentCols;
  int? _lastSentRows;

  /// One-shot bypass for the [sendResize] no-op guard (#848/#666). The #666
  /// connect-resync drives `terminal.resize` with the SAME dims to re-sync a
  /// stale remote; that fires `onResize` → `sendResize` (sessions.dart) with no
  /// `force` argument of its own. Arming this just before that `terminal.resize`
  /// lets the resulting `sendResize` punch through the guard exactly once.
  bool _forceNextResize = false;

  /// Most recent state snapshot. Always non-null.
  SshSessionData get data => _data;

  /// Stream of state changes. Emits the current snapshot on every transition.
  Stream<SshSessionData> get stream => _dataCtrl.stream;

  /// PTY output bytes streamed from the task side. Subscribers feed these
  /// into `Terminal.write(...)`.
  Stream<Uint8List> get output => _outputCtrl.stream;

  /// TEST-ONLY (paint replay harness): inject [bytes] into the SAME [output]
  /// stream real PTY bytes arrive on, so a recorded bug-report byte trace can
  /// be replayed through the full production write→damage→paint path
  /// (recorder → controller.write → notify → frame sync → paint) with the
  /// terminal view none the wiser. Dropped after close, like a real event.
  @visibleForTesting
  void debugInjectOutput(Uint8List bytes) {
    if (!_outputCtrl.isClosed) _outputCtrl.add(bytes);
  }

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

  /// Ask the task side to actively verify this session's socket is still alive
  /// (#737). Sent on `AppLifecycleState.resumed` alongside [rebind]: a session
  /// whose socket died half-open during Doze is still cached as `connected`, so
  /// rebind alone re-attaches to a dead pipe (input in, nothing out — frozen).
  /// The task pings with a short timeout; a dead probe drives the session to
  /// `softDisconnected` → reconnect, a live one stays connected.
  void probeLiveness() {
    if (_disposed) return;
    gateway.send(SshResumeProbeCommand(sessionId: sessionId).toJson());
  }

  /// Tell the task side whether the UI is foregrounded (#806). Sent on
  /// `AppLifecycleState` transitions (paused → false, resumed → true) so the
  /// task can gate its periodic snapshot timer — backgrounded, the UI is
  /// unbound and discards snapshots, so the 2s push (incl. a ~4KB scrollback
  /// decode) is wasted battery. Task-global: the command carries the empty
  /// sentinel sessionId, so calling it on ONE proxy suffices (all proxies share
  /// the gateway). On resume the task re-emits a fresh snapshot itself; the
  /// proxy's own [rebind] still runs for the cached-frame repaint.
  /// [activeSessionId] (#840 Slice 2) tells the task which session is front-most
  /// so it can SUPPRESS an attention notification for the session the user is
  /// already looking at (active + foreground). Optional + back-compatible.
  /// [activeHost] (#847) carries the front-most session's HOST so the task can
  /// suppress an attention bell from ANY session to the SAME host (the unit of
  /// attention is the host/Claude, not the individual session).
  void setActive(bool active, {String? activeSessionId, String? activeHost}) {
    if (_disposed) return;
    // #840 telemetry: log the UI-side SEND of every setActive (paired with the
    // task-isolate APPLY log in session_host). A device capture can then show
    // whether the UI sent foreground=true + the right activeHost, and whether
    // the task received it — pinning any per-isolate propagation gap.
    clifecycle(
      'ui.attention',
      'setActive send active=$active activeSessionId=$activeSessionId '
          'host=$activeHost',
    );
    gateway.send(
      SshSetActiveCommand(
        active: active,
        activeSessionId: activeSessionId,
        activeHost: activeHost,
      ).toJson(),
    );
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
    gateway.send(
      SshConnectCommand(
        sessionId: sessionId,
        host: params.host,
        port: params.port,
        username: params.username,
        authJson: SessionHost.encodeAuth(params.auth),
        title: title,
        // #911: carry the UI-isolate control-mode flag across the gateway so the
        // (separate) foreground-task isolate that opens the shell enters `tmux
        // -CC`. A per-isolate global set in the UI never reaches the task host.
        controlMode: tmuxControlMode,
      ).toJson(),
    );
  }

  /// Send a disconnect command.
  void disconnect() {
    gateway.send(SshDisconnectCommand(sessionId: sessionId).toJson());
  }

  /// Force-reconnect a dropped session (#817, Active Sessions UI). The task-side
  /// host maps this to `SshSessionController.reconnectNow()`, which re-enters the
  /// reconnect path from its held params — so NO auth is re-supplied here (creds
  /// live task-side). State updates (`reconnecting` → `connected` / `failed`)
  /// arrive asynchronously through [stream]. No-op for a healthy session
  /// (handled controller-side).
  void reconnect() {
    if (_disposed) return;
    gateway.send(SshReconnectCommand(sessionId: sessionId).toJson());
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
    gateway.send(
      SshHostKeyDecisionCommand(
        sessionId: sessionId,
        accepted: accepted,
      ).toJson(),
    );
    // Optimistically clear the prompt; the authoritative state (authenticating
    // / failed) arrives as a follow-up state event from the task side.
    _data = _data.copyWith(clearPendingHostKey: true);
    if (!_dataCtrl.isClosed) _dataCtrl.add(_data);
  }

  /// Send keystroke / paste bytes to the remote PTY through the gateway.
  void sendInput(Uint8List bytes) {
    gateway.send(SshInputCommand(sessionId: sessionId, bytes: bytes).toJson());
  }

  /// Send a FULL tmux `-CC` control-command LINE for ATOMIC delivery (#911 Part
  /// C). Unlike [sendInput] (keystroke bytes that can fragment across the gateway
  /// and land in the pane shell), this travels as ONE command envelope and the
  /// host writes it as a single framed line — so a multi-token command survives
  /// intact. [command] carries NO trailing newline; the host adds exactly one.
  /// A no-op on the task side unless control mode is ON for this session.
  void sendControlCommand(String command) {
    gateway.send(
      SshControlCommand(sessionId: sessionId, command: command).toJson(),
    );
  }

  /// Issue a high-level tmux WINDOW gesture (#911 Part C) — the host resolves it
  /// against its authoritative ordered window list and delivers the matching
  /// `next-window` / `previous-window` / `select-window -t @<id>` atomically. For
  /// [TmuxWindowGesture.tapStatusCol] pass the 1-based [statusCol] and the
  /// status-line width [statusCols]; ignored for next/previous.
  void sendTmuxGesture(
    TmuxWindowGesture gesture, {
    int statusCol = 0,
    int statusCols = 0,
  }) {
    gateway.send(
      SshTmuxGestureCommand(
        sessionId: sessionId,
        gesture: gesture,
        statusCol: statusCol,
        statusCols: statusCols,
      ).toJson(),
    );
  }

  /// Scroll the tmux `-CC` scrollback view by [deltaLines] (#906 Stage 2) —
  /// positive scrolls BACK into history (a downward swipe), negative toward live.
  /// The host advances the channel's scroll offset and captures the matching
  /// history window; the rendered response arrives on [output] as the scrollback
  /// view. A no-op on the task side unless control mode is ON for this session.
  void sendTmuxScroll(int deltaLines) {
    gateway.send(
      SshTmuxScrollCommand(
        sessionId: sessionId,
        deltaLines: deltaLines,
      ).toJson(),
    );
  }

  /// Request a directory listing over SFTP (#559). The matching
  /// [SftpListingEvent] (or [SftpErrorEvent]) arrives on [sftpEvents] with the
  /// same [requestId].
  void sftpList({required String requestId, required String path}) {
    gateway.send(
      SftpListCommand(
        sessionId: sessionId,
        requestId: requestId,
        path: path,
      ).toJson(),
    );
  }

  /// Request a single-file download over SFTP (#559). Chunks + completion
  /// arrive on [sftpEvents] keyed by [requestId].
  void sftpDownload({required String requestId, required String path}) {
    gateway.send(
      SftpDownloadCommand(
        sessionId: sessionId,
        requestId: requestId,
        path: path,
      ).toJson(),
    );
  }

  /// Request a WHOLE-FILE upload over SFTP (#892). [bytes] are written to the
  /// remote file at [path] (write|create|truncate). The terminal
  /// [SftpUploadDoneEvent] (or [SftpErrorEvent]) arrives on [sftpEvents] keyed
  /// by [requestId]. Foundation for in-app file editing.
  void sftpUpload({
    required String requestId,
    required String path,
    required Uint8List bytes,
  }) {
    gateway.send(
      SftpUploadCommand(
        sessionId: sessionId,
        requestId: requestId,
        path: path,
        bytes: bytes,
      ).toJson(),
    );
  }

  /// Request a chunked, RESUMABLE upload of the LOCAL file at [localPath] to
  /// [remotePath] (#960). The task streams the file to a `.part` temp + atomic
  /// rename, resuming from any existing `.part`. [SftpUploadProgressEvent]s and
  /// the terminal [SftpUploadDoneEvent] (or [SftpErrorEvent]) arrive on
  /// [sftpEvents] keyed by [requestId]. Large files never cross the IPC.
  void sftpUploadFile({
    required String requestId,
    required String localPath,
    required String remotePath,
  }) {
    gateway.send(
      SftpUploadFileCommand(
        sessionId: sessionId,
        requestId: requestId,
        localPath: localPath,
        remotePath: remotePath,
      ).toJson(),
    );
  }

  /// Probe whether a remote path exists over SFTP (#990). The
  /// [SftpStatResultEvent] arrives on [sftpEvents] keyed by [requestId] —
  /// ALWAYS a result (errors collapse to `exists=false`, fail-open). Used by
  /// the path-anchor verifier to upgrade a detected path to the verified shade.
  void sftpStat({required String requestId, required String path}) {
    gateway.send(
      SftpStatCommand(
        sessionId: sessionId,
        requestId: requestId,
        path: path,
      ).toJson(),
    );
  }

  /// Send a PTY resize to the remote.
  ///
  /// #848 — NO-OP GUARD: a resize whose (cols, rows) are IDENTICAL to the last
  /// grid sent for this session is DROPPED (no PTY write, no gateway log). On
  /// keyboard hide the fit/resize path re-fired the same dimensions on every
  /// animation frame, for every session; each identical resize made tmux redraw
  /// (the duplicated content) and flooded the connect ring. Deduping at the
  /// emission point kills most of the storm at the source.
  ///
  /// Pass [force] to bypass the guard and re-send identical dims — the #666
  /// connect-resync deliberately re-pushes the SAME size to re-sync a remote
  /// that attached at the stale default before layout settled.
  void sendResize(
    int cols,
    int rows, {
    int pixelWidth = 0,
    int pixelHeight = 0,
    bool force = false,
  }) {
    final bypass = force || _forceNextResize;
    _forceNextResize = false;
    if (!bypass && cols == _lastSentCols && rows == _lastSentRows) {
      return;
    }
    _lastSentCols = cols;
    _lastSentRows = rows;
    gateway.send(
      SshResizeCommand(
        sessionId: sessionId,
        cols: cols,
        rows: rows,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ).toJson(),
    );
  }

  /// Arm a ONE-SHOT bypass of the [sendResize] no-op guard (#848/#666). The
  /// next `sendResize` for this session — even with identical dims — is forwarded
  /// to the PTY, then the arm clears. Used by the connect-fit force-resync path,
  /// which drives `terminal.resize` (→ `onResize` → `sendResize`) to re-sync a
  /// stale remote without the fit code threading a `force` flag through xterm.
  void armForceResize() {
    _forceNextResize = true;
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
      case SshLifecycleEvent():
        // Task-global lifecycle telemetry (#766). The UI-side gateway already
        // recorded it into the lifecycle ring before _incoming, so a per-session
        // proxy has nothing to do — handle it for switch exhaustiveness only.
        break;
      case SshControlModeTraceEvent():
        // Task-global control-mode telemetry (#906). The UI-side gateway already
        // recorded it into the control-mode ring before _incoming; a per-session
        // proxy has nothing to do — handle it for switch exhaustiveness only.
        break;
      case SftpListingEvent():
      case SftpDownloadChunkEvent():
      case SftpDownloadDoneEvent():
      case SftpUploadDoneEvent():
      case SftpUploadProgressEvent():
      case SftpStatResultEvent():
      case SftpErrorEvent():
        // SFTP results (#559/#892/#960) — forward to the file browser / writer
        // seam, which match by request id. They never touch the SSH lifecycle.
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
