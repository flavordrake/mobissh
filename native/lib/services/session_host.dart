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
import '../ssh/da2_responder.dart';
import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import '../ssh/sftp_session.dart';
import 'session_messages.dart';
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
    this.snapshotInterval = const Duration(seconds: 2),
    this.resumeProbeTimeout = const Duration(seconds: 2),
    this.resumeStaleThreshold = const Duration(seconds: 20),
    this.resumeNudgeWindow = const Duration(seconds: 2),
    int Function()? nowMs,
  }) : _gateway = gateway,
       _factory = controllerFactory ?? _defaultControllerFactory,
       _sftpOpener = sftpOpener,
       _shellOpener = shellOpener ?? _defaultShellOpener,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _commandSub = _gateway.incoming.listen(_dispatch);
    _snapshotTimer = Timer.periodic(snapshotInterval, (_) => _pushSnapshots());
    // #766: arm the lifecycle forwarder so every `clifecycle` line written in
    // THIS (task) isolate is shipped across the gateway to the UI isolate, where
    // it lands in the UI-side lifecycle ring the feedback bundle actually reads.
    // Without this, the bundle (assembled UI-side) ships an EMPTY lifecycle log
    // even though the task isolate recorded the probe outcomes — the meta-bug.
    // Held in [_lifecycleForward] so dispose can detach exactly our closure.
    _lifecycleForward = (line) {
      if (_disposed) return;
      _gateway.send(SshLifecycleEvent(line: line).toJson());
    };
    lifecycleForwarder = _lifecycleForward;
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

  /// How often a snapshot is pushed to the UI side. Tests use a short
  /// interval; production defaults to two seconds.
  final Duration snapshotInterval;

  /// Timeout for the resume liveness probe (#737). A `connected` session whose
  /// ping doesn't reply within this window is declared dead → reconnect. Short
  /// so a frozen wake recovers in a few seconds, not "never". Tests shrink it.
  /// Shortened 4s → 2s (#759) so detection is faster and the stale window does
  /// not let a green dot sit over frozen content for long.
  final Duration resumeProbeTimeout;

  /// How long with NO fresh remote bytes before a session is considered "stale
  /// going into resume" (#759). Only a session that is BOTH stale-before AND
  /// unresponsive to the nudge is reconnected — a session that produced fresh
  /// bytes within this window is left connected even if the nudge is silent
  /// (conservative gate against churning a healthy idle session).
  final Duration resumeStaleThreshold;

  /// How long to wait after sending the end-to-end nudge (a benign channel
  /// resize that makes a live tmux/shell REDRAW) for fresh remote bytes to
  /// arrive (#759). Bounded so the resume decision resolves quickly. If no fresh
  /// bytes arrive in this window the session is declared STALE → reconnect.
  final Duration resumeNudgeWindow;

  /// Injectable monotonic-ish clock (ms since epoch). Real production uses
  /// `DateTime.now()`; tests inject a controllable clock so the staleness gate
  /// is deterministic under `fakeAsync` (#759).
  final int Function() _nowMs;

  StreamSubscription<Map<String, dynamic>>? _commandSub;
  Timer? _snapshotTimer;
  bool _disposed = false;

  /// Whether the UI is foregrounded (#806). The UI sends `SshSetActiveCommand`
  /// on `AppLifecycleState` transitions. While `false` the UI is `unbind()`-ed
  /// and discards snapshots, so the periodic timer is stopped — the on-demand
  /// `SshRequestSnapshotCommand` path still answers (audit live view / resume
  /// rebind). Starts `true`: the host is built when a session connects, which
  /// only happens with the UI foregrounded, and resume re-asserts it anyway.
  bool _active = true;

  /// The exact lifecycle-forwarder closure this host installed into the global
  /// [lifecycleForwarder] (#766). Held so dispose detaches OUR closure only —
  /// it won't clobber a forwarder a different host installed afterward (matters
  /// for the desktop / in-process path where hosts share one isolate).
  void Function(String line)? _lifecycleForward;

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
        // On-demand (audit live view / resume rebind): always answer, and
        // include the scrollback tail — this is the path that hydrates the
        // terminal/audit, so it carries the full payload (#806 C).
        if (s != null) _emitSnapshot(cmd.sessionId, s, includeScrollback: true);
      case SshSetActiveCommand():
        _handleSetActive(cmd.active);
      case SshHostKeyDecisionCommand():
        _handleHostKeyDecision(cmd);
      case SshUiHelloCommand():
        // #731: a fresh UI gateway asking the live task to re-announce
        // readiness. The Android task isolate normally intercepts this in
        // `KeepaliveTaskHandler.onReceiveData` (before delivery), so the host
        // only sees it on the in-process desktop path where the gateway is
        // always ready and this can't trigger — but handle it defensively by
        // re-emitting ready so the contract is honoured everywhere.
        _gateway.send(const SshTaskReadyEvent().toJson());
      case SshResumeProbeCommand():
        // #737/#759: actively verify the session survived Doze rather than
        // trusting the cached `connected` state. Transport ping (#737) PLUS an
        // end-to-end nudge check (#759) for the transport-alive-but-shell-frozen
        // case a ping cannot catch.
        _handleResumeProbe(cmd.sessionId);
      case SshReconnectCommand():
        // #817: user tapped Reconnect on a dropped session row. Force re-enter
        // the reconnect path from held params (no auth re-supply). No-op when
        // the session isn't hosted (already forgotten) or isn't in a drop state.
        _sessions[cmd.sessionId]?.controller.reconnectNow();
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

  /// End-to-end resume liveness (#759).
  ///
  /// The #737 transport ping answers whenever SSH is up — but after deep Doze
  /// the link can be a zombie that still ACKs at the transport layer while the
  /// remote tmux/shell is FROZEN, or the real link dropped and a stale socket
  /// lingers. A transport ping cannot catch an app-level freeze. So:
  ///
  ///   1. Capture the fresh-remote-byte counter + whether the session was STALE
  ///      going into resume (no remote output for [resumeStaleThreshold]).
  ///   2. Run the transport ping ([SshSessionController.probeLiveness]). If it
  ///      FAILS the controller already drove softDisconnected → reconnect
  ///      (#737) — done. Telemetry: `ping-failed → reconnect`.
  ///   3. Ping answered. If the session was NOT stale (produced fresh bytes
  ///      recently) leave it connected — `alive(recent-bytes)`. (Conservative:
  ///      never churn a healthy idle session.)
  ///   4. Ping answered AND stale-before: send a benign NUDGE (a no-op channel
  ///      resize that makes a live tmux/shell REDRAW → fresh bytes) and wait
  ///      [resumeNudgeWindow]:
  ///        - fresh bytes arrived → `alive(fresh-bytes-after-nudge)`, stay.
  ///        - NO fresh bytes → STALE/FROZEN → `softDisconnectForResume()` drives
  ///          softDisconnected → reconnect. Telemetry:
  ///          `STALE(no-bytes-after-nudge) → reconnect`.
  ///
  /// Only the (stale-before AND no-bytes-after-nudge) combination triggers the
  /// NEW reconnect path; everything else stays connected. Reconnect is cheap for
  /// tmux (re-attach) but we deliberately do not churn responsive sessions.
  Future<void> _handleResumeProbe(String sessionId) async {
    final hosted = _sessions[sessionId];
    if (hosted == null) return;
    final controller = hosted.controller;

    final countBefore = hosted.remoteByteEvents;
    final lastByteAt = hosted.lastRemoteByteAtMs;
    final now = _nowMs();
    // Stale-before: never saw a remote byte, OR the last one is older than the
    // threshold. A brand-new connection with no output yet counts as stale (it
    // has nothing to prove it's responsive), but it will answer the nudge if
    // healthy.
    final staleBefore =
        lastByteAt == null ||
        (now - lastByteAt) >= resumeStaleThreshold.inMilliseconds;

    // (1)+(2): transport ping (#737). Returns false when it failed and the
    // session was already driven into reconnect.
    final pingAlive = await controller.probeLiveness(
      timeout: resumeProbeTimeout,
    );
    if (!pingAlive) {
      // Controller emitted the `ping-failed → reconnect` lifecycle line.
      return;
    }

    // (3): ping answered but session was responsive recently — leave connected.
    if (!staleBefore) {
      clifecycle('task.host', 'resume-liveness: alive(recent-bytes)');
      return;
    }

    // The session may have been torn down or moved off connected while we
    // awaited the ping. If it's no longer hosted/connected, nothing to nudge.
    if (!_sessions.containsKey(sessionId) ||
        controller.data.state != SshSessionState.connected) {
      return;
    }

    // Conservative: the end-to-end check needs a live shell channel to nudge and
    // to observe redraw bytes. With no shell open (the session reached connected
    // but the PTY isn't up yet, or this is a #737-style controller-only test)
    // there is nothing to nudge — fall back to the #737 ping-only verdict and
    // leave the (ping-alive) session connected rather than false-reconnecting.
    if (hosted.shell == null) {
      clifecycle('task.host', 'resume-liveness: alive(no-shell, ping-only)');
      return;
    }

    // (4): stale-before — send the end-to-end nudge and watch for fresh bytes.
    _sendLivenessNudge(hosted);
    await Future<void>.delayed(resumeNudgeWindow);

    // Re-resolve: a real close / reconnect could have raced in.
    final after = _sessions[sessionId];
    if (after == null) return;
    if (after.controller.data.state != SshSessionState.connected) return;

    if (after.remoteByteEvents > countBefore) {
      clifecycle(
        'task.host',
        'resume-liveness: alive(fresh-bytes-after-nudge)',
      );
      return;
    }
    // Stale-before AND no fresh bytes after the nudge → frozen/dead end-to-end.
    after.controller.softDisconnectForResume();
  }

  /// Send a benign channel nudge that forces a live remote tmux/shell to redraw
  /// (#759): a window-resize toggling the columns by one and back. Non-intrusive
  /// (no keystrokes injected into the shell, no command run), but a responsive
  /// PTY answers with a repaint → fresh remote bytes the nudge check can see.
  /// A frozen shell / dead link produces nothing. No-op when no shell is open.
  void _sendLivenessNudge(_HostedSession hosted) {
    final shell = hosted.shell;
    if (shell == null) return;
    final cols = hosted.metrics.lastCols ?? 80;
    final rows = hosted.metrics.lastRows ?? 24;
    try {
      // Toggle off-by-one then back to the real dims so the final geometry is
      // unchanged but the remote sees a resize → SIGWINCH → redraw.
      shell.resize(cols + 1, rows);
      shell.resize(cols, rows);
    } catch (_) {
      // dartssh2 throws on non-positive dims / closed channel; a closed channel
      // means the transport is already gone and the controller's own close path
      // will drive reconnect. Swallow — the nudge is best-effort.
    }
  }

  void _handleConnect(SshConnectCommand cmd) {
    final existing = _sessions[cmd.sessionId];
    if (existing != null) {
      // Already hosted. If the session is in a manually-reconnectable DROP state
      // (#817), a re-issued connect IS a Reconnect: force-revive it in place from
      // the controller's held params (no need to rebuild the controller — its
      // creds + state machine are intact). Otherwise just emit the current state
      // so the UI can sync (the original dedup-connect contract). This keeps the
      // UI's Reconnect path uniform: it always re-issues a connect, and the host
      // routes it to reconnectNow() for a live-but-dropped session or to a fresh
      // connect when the session was lost (e.g. the foreground isolate was torn
      // down on the last-session drop and rebuilt empty).
      if (_isReconnectableDrop(existing.controller.data.state)) {
        ctrace(
          'task.host',
          'connect sid=${cmd.sessionId} on dropped session → reconnectNow()',
        );
        existing.controller.reconnectNow();
      } else {
        _emitState(cmd.sessionId, existing.controller);
      }
      return;
    }
    final controller = _factory();
    final hosted = _HostedSession(controller: controller);
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
        // #836: record the transition in the DURABLE lifecycle ring (and forward
        // it UI-side) so a session drop is observable in the connect-log bundle.
        // Previously a transition was only echoed to the TERMINAL bytes via
        // `_emitConnectStatus` — never to the ctrace/lifecycle ring — so a silent
        // mid-session drop left NO trace event, and even a logged one was evicted
        // by the per-frame fit659 offstage flood. `clifecycle` lands in the
        // dedicated ring that survives connect-ring churn and is never collapsed.
        clifecycle(
          'task.host',
          'state: ${prevState.name} → ${data.state.name}'
              '${data.error != null ? ' (${data.error})' : ''}',
        );
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

  /// A drop state the user can manually reconnect from (#817) — mirrors the UI's
  /// `_canReconnect`. A re-issued connect for a session in one of these states is
  /// treated as a force-reconnect rather than a no-op state sync.
  static bool _isReconnectableDrop(SshSessionState state) {
    return state == SshSessionState.softDisconnected ||
        state == SshSessionState.reconnecting ||
        state == SshSessionState.failed ||
        state == SshSessionState.disconnected;
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
      // Fresh attach => fresh DA2 handshake: clear any buffered partial query
      // from a prior shell so we answer THIS attach's `ESC[>c` cleanly (#osc8).
      hosted.da2Responder.reset();
      // Wire the output listener BEFORE announcing shell-ready (#619). The UI's
      // run-on-connect command fires on shell-ready, writes to stdin, and the
      // shell echoes + runs it immediately. If we announced ready first (the
      // original #619 fix did), that first output chunk — the command echo and
      // its stdout — would be produced with no listener attached yet and lost:
      // the command ran on the remote but its output never reached the UI, and
      // any output-asserting test saw nothing. stdin is already writable via
      // `hosted.shell = transport` above, so announcing a few lines later is free.
      hosted.shellSub = transport.output.listen(
        (bytes) {
          hosted.metrics.bytesIn += bytes.length;
          // Record a fresh-remote-byte event for the #759 resume-liveness check.
          // This is the ground truth that the REMOTE (not just the transport) is
          // producing output — the nudge check watches this counter advance.
          hosted.remoteByteEvents += 1;
          hosted.lastRemoteByteAtMs = _nowMs();
          // Intercept tmux's DA2 query and answer as `tmux` so tmux forwards
          // OSC-8 hyperlinks to us (the query is swallowed; our reply goes back
          // over stdin). On non-tmux hosts no query arrives and `forward` is the
          // input untouched. See [Da2HyperlinkResponder].
          final scan = hosted.da2Responder.scan(bytes);
          if (scan.hasReply) {
            final shell = hosted.shell;
            if (shell != null) {
              for (final reply in scan.replies) {
                shell.send(reply);
              }
            }
          }
          final forward = scan.forward;
          if (forward.isEmpty) return;
          hosted.appendScrollback(forward);
          _gateway.send(
            SshOutputEvent(sessionId: sessionId, bytes: forward).toJson(),
          );
        },
        onError: (Object e, StackTrace st) {
          _emitStatus(sessionId, '\r\n[mobissh] shell stream error: $e\r\n');
        },
      );
      // Now that output is wired and stdin is writable, announce shell-ready so
      // the UI's run-on-connect command can fire (gating on the bare `connected`
      // state raced ahead of this open on slow hosts and the bytes were dropped
      // to scrollback by `_handleInput`). Re-emitted on every (re)open; the UI
      // runner is one-shot so a reconnect re-open can't re-run the command.
      _gateway.send(SshShellReadyEvent(sessionId: sessionId).toJson());
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

  /// Handle a UI foreground/background transition (#806). On background
  /// (`active: false`) stop the periodic snapshot timer — the UI is unbound and
  /// discards snapshots, so the 2s push is wasted battery (incl. the ~4KB
  /// scrollback decode). On foreground (`active: true`) restore the 2s timer AND
  /// emit one fresh FULL snapshot per session immediately so the UI repaints
  /// from current state without waiting for the next tick. Idempotent: a repeat
  /// of the current state is a no-op so duplicate lifecycle events don't churn
  /// the timer. Does NOT touch the SSH session, keepalive, or locks.
  void _handleSetActive(bool active) {
    if (_disposed) return;
    if (_active == active) return;
    _active = active;
    if (active) {
      _snapshotTimer?.cancel();
      _snapshotTimer = Timer.periodic(snapshotInterval, (_) => _pushSnapshots());
      // Resume repaint: one fresh full snapshot now (the UI just rebound and
      // its cached frame may be stale). Dirty-check is bypassed — resume must
      // always re-emit (#806 A).
      for (final entry in _sessions.entries) {
        _emitSnapshot(entry.key, entry.value, includeScrollback: true);
      }
    } else {
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
    }
  }

  void _pushSnapshots() {
    if (_disposed) return;
    for (final entry in _sessions.entries) {
      // Dirty-check (#806 B): only ship a periodic snapshot when something the
      // UI renders actually changed since the last periodic push. An idle
      // session emits nothing — no event, no scrollback decode, no IPC copy.
      final hosted = entry.value;
      final sig = hosted.snapshotSignature();
      if (sig == hosted.lastPushedSignature) continue;
      hosted.lastPushedSignature = sig;
      // Periodic payload omits the ~4KB scrollback decode (#806 C): the on-demand
      // SshRequestSnapshotCommand path (resume / audit-open) carries it.
      _emitSnapshot(entry.key, hosted, includeScrollback: false);
    }
  }

  void _emitSnapshot(
    String sessionId,
    _HostedSession hosted, {
    required bool includeScrollback,
  }) {
    // Keep dirty-check honest for any later periodic push: an on-demand emit
    // re-baselines the signature so the next periodic tick doesn't re-send the
    // same state it just shipped on demand.
    hosted.lastPushedSignature = hosted.snapshotSignature();
    _gateway.send(
      SshSnapshotEvent(
        sessionId: sessionId,
        state: hosted.controller.data.state.name,
        bytesIn: hosted.metrics.bytesIn,
        bytesOut: hosted.metrics.bytesOut,
        lastKeepaliveRttMs: hosted.metrics.lastKeepaliveRttMs,
        reconnectCount: hosted.metrics.reconnectCount,
        lastReconnectAtMs: hosted.metrics.lastReconnectAtMs,
        scrollbackTail: includeScrollback ? hosted.scrollbackTailString() : '',
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
    // Mirror the live listener so the #759 resume-liveness check sees fresh
    // remote bytes through the test ingest seam too.
    hosted.remoteByteEvents += 1;
    hosted.lastRemoteByteAtMs = _nowMs();
    hosted.appendScrollback(bytes);
    _gateway.send(SshOutputEvent(sessionId: sessionId, bytes: bytes).toJson());
  }

  /// Detach this host's lifecycle forwarder from the global hook (#766) — but
  /// only if it is still ours (a later host in the same isolate may have armed
  /// its own). Idempotent.
  void _detachLifecycleForwarder() {
    if (identical(lifecycleForwarder, _lifecycleForward)) {
      lifecycleForwarder = null;
    }
    _lifecycleForward = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _detachLifecycleForwarder();
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
    _detachLifecycleForwarder();
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
  _HostedSession({required this.controller});

  final SshSessionController controller;
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

  /// Intercepts tmux's DA2 (Secondary Device Attributes) query in the remote
  /// byte stream and answers as a `tmux`-class terminal so tmux advertises the
  /// `hyperlinks` feature and FORWARDS OSC-8 links (instead of stripping them)
  /// to this client. See [Da2HyperlinkResponder]. Reset per shell open so a
  /// reconnect re-answers the fresh attach's query.
  final Da2HyperlinkResponder da2Responder = Da2HyperlinkResponder();

  /// Monotonic count of remote-output CHUNKS actually received from the shell
  /// (#759). Bumped only by the live shell-output listener (and the test
  /// ingest seam) — NOT by snapshot replay or scrollback hydration — so it is a
  /// faithful "fresh bytes from the remote" signal. The resume-liveness check
  /// captures this before nudging and re-reads it after the nudge window to
  /// decide whether a transport-alive session is actually responsive end-to-end.
  int remoteByteEvents = 0;

  /// Wall-clock (ms since epoch) of the most recent remote-output chunk, or
  /// null if none has arrived yet (#759). Drives the `staleBefore` gate: a
  /// session that produced fresh bytes recently is NOT escalated to the nudge
  /// check on resume (conservative — don't churn a healthy idle session).
  int? lastRemoteByteAtMs;

  /// Monotonic token bumped each time the shell is dropped (#590). An in-flight
  /// [SessionHost._ensureShell] open captures this before awaiting and discards
  /// its transport if the token changed — so a stale open from a dropped
  /// connection can't re-attach after a reconnect.
  int shellGeneration = 0;

  /// Fingerprint of the host-key challenge already forwarded to the UI, so a
  /// single awaitingHostKey transition emits exactly one challenge (#536).
  String? challengedFingerprint;
  final BytesBuilder _scrollback = BytesBuilder(copy: false);

  /// The signature value at the last PERIODIC snapshot push (#806 B). The
  /// dirty-check compares the current [snapshotSignature] against this and skips
  /// the push when nothing the UI renders changed. Re-baselined on every emit
  /// (periodic OR on-demand) so the next periodic tick measures the delta from
  /// what the UI actually last received. Null until the first push.
  String? lastPushedSignature;

  /// Append raw bytes to the scrollback cache and cap the buffer at ~4KB
  /// (the cap is enforced by [scrollbackTailString], not here, so the latest
  /// bytes always win).
  void appendScrollback(Uint8List bytes) {
    _scrollback.add(bytes);
  }

  /// A cheap fingerprint of the snapshot-relevant fields (#806 B). When this is
  /// unchanged since the last periodic push, the periodic snapshot is skipped —
  /// an idle connected session produces no IPC traffic. Uses the scrollback
  /// BYTE LENGTH (not a decode) so the dirty-check itself stays allocation-light:
  /// scrollback only grows via [appendScrollback], so a length change is a
  /// faithful "new bytes arrived" signal without the ~4KB UTF-8 decode.
  String snapshotSignature() {
    final m = metrics;
    return '${controller.data.state.name}|${m.bytesIn}|${m.bytesOut}|'
        '${m.lastKeepaliveRttMs}|${m.reconnectCount}|${m.lastReconnectAtMs}|'
        '${_scrollback.length}';
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
