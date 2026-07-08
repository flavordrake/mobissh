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
import '../terminal/tmux_control_channel.dart';
import '../terminal/tmux_control_mode_flag.dart';
import '../ssh/da2_responder.dart';
import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import '../ssh/ssh_shell.dart';
import '../ssh/sftp_session.dart';
import 'attention_signal_scanner.dart';
import 'session_attention_notification.dart';
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

/// #982: how long to wait for the `-CC` handshake (the `\x1bP1000p` DCS) after
/// writing the entry command before declaring control mode FAILED and falling
/// back to the scrape path. Nested tmux / a shell that never enters `-CC` never
/// emits the DCS, so this bounds how long a control-mode connect can look bricked
/// before it degrades to a working scrape session. A few seconds covers a slow
/// login shell + `tmux -CC attach` round-trip over a high-latency link.
const Duration kTmuxHandshakeTimeout = Duration(seconds: 4);

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
    AttentionNotifier? attentionNotifier,
    this.replayWindow = kAttentionReplayWindow,
    this.switchGraceWindow = kAttentionSwitchGraceWindow,
  }) : _gateway = gateway,
       _factory = controllerFactory ?? _defaultControllerFactory,
       _sftpOpener = sftpOpener,
       _shellOpener = shellOpener ?? _defaultShellOpener,
       _attentionNotifier = attentionNotifier,
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

  /// The currently front-most (active) session id, as last reported by the UI
  /// via [SshSetActiveCommand.activeSessionId] (#840 Slice 2). Null when unknown.
  /// Combined with [_active], this drives attention-notification SUPPRESSION:
  /// the session the user is already looking at (active + foreground) does not
  /// get a notification.
  String? _activeSessionId;

  /// The HOST of the currently front-most (active) session (#847), as reported
  /// by the UI via [SshSetActiveCommand.activeHost]. The unit of attention is the
  /// host: while foregrounded on ANY session to this host, a bell from ANY
  /// session to the SAME host is suppressed. Null when unknown (degrades to the
  /// session-id-derived host inside [shouldPostAttention]).
  String? _activeHost;

  /// Host-level cross-session dedup (#847): collapses multiple bells from
  /// multiple sessions to the same host (one Claude event reaching two PTYs)
  /// into ONE notification within [kAttentionDedupWindow]. Shares the host's
  /// injectable clock so tests are deterministic.
  late final AttentionDedupTracker _attentionDedup = AttentionDedupTracker(
    nowMs: _nowMs,
  );

  /// Posts attention notifications when a Slice-1 signal is detected (#840
  /// Slice 2). Null on platforms / tests where no notifier is wired — then the
  /// detection still LOGS to `clifecycle` (Slice 1 behaviour) but posts nothing.
  /// Injected so the task isolate binds `flutter_local_notifications` in
  /// production while tests record posts in memory.
  final AttentionNotifier? _attentionNotifier;

  /// (Re)connect REPLAY-suppression window (#851). An attention signal detected
  /// within this cooldown of the session's most recent `connected` transition
  /// (see [_HostedSession.connectedAtMs], re-stamped on EVERY connected
  /// transition — initial connect AND reconnect/softDisconnected→connected) is
  /// treated as REPLAYED scrollback / catch-up and is NOT posted; only live
  /// output after the window settles posts. Composes with — does not replace —
  /// the #847 foreground host-suppression and cross-session dedup. Injectable so
  /// tests can disable it ([Duration.zero]) or set a deterministic span; the
  /// window is measured against the host's injected [_nowMs] clock.
  final Duration replayWindow;

  /// JUST-SWITCHED grace window (#856). When [_handleSetActive] changes the
  /// active HOST (the user switched TO a session on a different host, or the app
  /// foregrounded onto it), the host arms a short grace for the newly-active
  /// host: an attention signal for that host within the window is the switch
  /// CATCH-UP burst (flushed when the session became front-most), not a live
  /// moment — so it is suppressed (logged `just-switched`) rather than posted.
  /// This closes the activeHost-propagation RACE the #847 host-suppression can't
  /// (the catch-up output is scanned before `setActive` lands) and the SWITCH
  /// case the #851 replay window can't (it only re-arms on a CONNECT, not a
  /// session switch). Stamped per host in [_switchGraceUntilMs] on the active-host
  /// CHANGE only (re-asserting the same active host does NOT re-arm, so the window
  /// can't be extended indefinitely). Composes with — does not replace — #847 +
  /// #851. Injectable + measured against [_nowMs] so tests are deterministic
  /// ([Duration.zero] disables it).
  final Duration switchGraceWindow;

  /// Per-host expiry (ms since epoch, via [_nowMs]) of the just-switched grace
  /// (#856). A signal whose host has an entry here that is still in the future is
  /// suppressed as the switch catch-up burst. Stamped on each active-host change
  /// in [_handleSetActive].
  final Map<String, int> _switchGraceUntilMs = {};

  /// The exact lifecycle-forwarder closure this host installed into the global
  /// [lifecycleForwarder] (#766). Held so dispose detaches OUR closure only —
  /// it won't clobber a forwarder a different host installed afterward (matters
  /// for the desktop / in-process path where hosts share one isolate).
  void Function(String line)? _lifecycleForward;

  /// Minimum spacing between liveness-heartbeat lines per session (#838).
  /// The heartbeat piggybacks the 2s snapshot tick but only emits this often so
  /// the durable lifecycle ring isn't churned by alive-pings — yet a silent drop
  /// is still caught within ~10s by the growing lastActivityAge.
  static const int _heartbeatIntervalMs = 10000;

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
          final tmux = s.tmuxChannel;
          if (tmux != null) {
            // #909 control mode: `refresh-client -C cols,rows` is the SINGLE
            // resize primitive — tmux owns the layout math so the app grid and
            // tmux size cannot diverge. The UI's trailing-edge settle coalescer
            // (GhosttyResizeCoalescer) already debounces flterm's per-frame
            // onResize, but #916 found a SECOND uncoalesced source (the
            // redraw-on-switch) plus the multi-client-clamp feedback storm, so we
            // also debounce TASK-SIDE through the per-session [refreshCoalescer]:
            // a burst of resizes / switches collapses to ONE refresh-client at
            // the settled size (the FINAL size is never dropped — #903/#905). We
            // do NOT also resize the PTY winsize: in -CC the channel runs
            // `tmux -CC`, whose own terminal size is irrelevant; the inner client
            // size is what refresh-client -C sets.
            s.refreshCoalescer?.submit(cmd.cols, cmd.rows);
          } else {
            // Scrape path (default): resize the live PTY so the remote shell
            // wraps to the viewport.
            try {
              s.shell?.resize(cmd.cols, cmd.rows);
            } catch (_) {
              // dartssh2 throws on non-positive dims; the next real resize fixes it.
            }
          }
        }
      case SshRequestSnapshotCommand():
        final s = _sessions[cmd.sessionId];
        // On-demand (audit live view / resume rebind): always answer, and
        // include the scrollback tail — this is the path that hydrates the
        // terminal/audit, so it carries the full payload (#806 C).
        if (s != null) _emitSnapshot(cmd.sessionId, s, includeScrollback: true);
      case SshSetActiveCommand():
        _handleSetActive(cmd.active, cmd.activeSessionId, cmd.activeHost);
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
      case SftpUploadCommand():
        _handleSftpUpload(cmd);
      case SftpUploadFileCommand():
        _handleSftpUploadFile(cmd);
      case SshControlCommand():
        _handleControlCommand(cmd);
      case SshTmuxGestureCommand():
        _handleTmuxGesture(cmd);
      case SshTmuxScrollCommand():
        _handleTmuxScroll(cmd);
    }
  }

  /// #911 Part C Step 1: write a FULL `-CC` control-command line ATOMICALLY.
  ///
  /// The whole line is framed by [TmuxControlChannel.controlCommand] (exactly one
  /// trailing newline) and written in a SINGLE `transport.send`, so a multi-token
  /// command (`select-window -t @1`) can't fragment across the gateway and have
  /// its tail land in the pane shell (the Part B failure). A no-op unless control
  /// mode is ON for this session (`tmuxChannel != null`) — the scrape path never
  /// issues control commands, so the flag-OFF default is provably untouched.
  void _handleControlCommand(SshControlCommand cmd) {
    final hosted = _sessions[cmd.sessionId];
    if (hosted == null) return;
    final tmux = hosted.tmuxChannel;
    if (tmux == null) return; // flag OFF — ignore.
    if (!hosted.tmuxHandshakeConfirmed) return; // #982: no -CC write pre-handshake.
    try {
      // #906: frame through the channel so the command's `%begin…%end` ack is
      // registered in the capture-correlation FIFO.
      hosted.shell?.send(tmux.frameControl(cmd.command));
    } catch (_) {
      // Channel closed mid-command; the next connect re-syncs.
    }
  }

  /// #911 Part C Step 2: resolve a high-level window gesture to a real tmux
  /// control command using the channel's AUTHORITATIVE ordered window list, then
  /// deliver it atomically. Keeping the index lookup here (task-side) means the UI
  /// never holds the window list and a status-bar tap maps with NO pixel guessing
  /// — the wrong-row bug this part dissolves. A no-op unless control mode is ON.
  void _handleTmuxGesture(SshTmuxGestureCommand cmd) {
    final hosted = _sessions[cmd.sessionId];
    if (hosted == null) return;
    final tmux = hosted.tmuxChannel;
    if (tmux == null) return; // flag OFF — ignore.
    if (!hosted.tmuxHandshakeConfirmed) return; // #982: no -CC write pre-handshake.
    final String? line;
    switch (cmd.gesture) {
      case TmuxWindowGesture.nextWindow:
        line = TmuxControlChannel.nextWindowCommand;
      case TmuxWindowGesture.previousWindow:
        line = TmuxControlChannel.previousWindowCommand;
      case TmuxWindowGesture.tapStatusCol:
        line = tmux.selectWindowCommandForStatusCol(
          cmd.statusCol,
          cmd.statusCols,
        );
    }
    if (line == null) return; // no window known yet — nothing to target.
    try {
      hosted.shell?.send(tmux.frameControl(line));
    } catch (_) {
      // Channel closed; reconnect re-syncs.
    }
  }

  /// #906 Stage 2: a vertical swipe under control mode. Advance the channel's
  /// scroll offset by the signed line delta and send the matching `capture-pane`
  /// history window (or a live re-capture when snapped back to bottom). The
  /// rendered response — correlated through the capture FIFO — IS the scrollback
  /// view (control mode emits no `%output` for copy-mode scroll). A no-op unless
  /// control mode is ON. The viewport height comes from the last resize so the
  /// captured window is exactly one screen tall.
  void _handleTmuxScroll(SshTmuxScrollCommand cmd) {
    final hosted = _sessions[cmd.sessionId];
    if (hosted == null) return;
    final tmux = hosted.tmuxChannel;
    if (tmux == null) return; // flag OFF — ignore.
    if (!hosted.tmuxHandshakeConfirmed) return; // #982: no -CC write pre-handshake.
    if (cmd.deltaLines == 0) return;
    final rows = hosted.metrics.lastRows ?? 24;
    try {
      hosted.shell?.send(tmux.frameScroll(cmd.deltaLines, rows));
    } catch (_) {
      // Channel closed; reconnect re-syncs.
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
    // #911: apply the UI-isolate's desired control-mode state to THIS (task)
    // isolate's global before the shell opens. `tmuxControlMode` is a per-isolate
    // global, and the host runs in the foreground-task isolate — a flag flipped
    // in the UI isolate (settings toggle / emulator parity tests) otherwise never
    // reaches `_ensureShell`, so `tmux -CC` is never entered and control commands
    // are dropped. The connect command carries the bit across the gateway.
    tmuxControlMode = cmd.controlMode;
    ctrace('task.host',
        'connect sid=${cmd.sessionId} controlMode=${cmd.controlMode}');

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
        // #838: when this edge is a DROP (left/never-reached `connected` into a
        // disconnect state), emit ONE structured disconnect line carrying the
        // CAUSE, end-time→detection LATENCY, transport/keepalive/attempt/intent
        // context, and a monotonic edge# so a capture reveals double-fires
        // ("cut once"). Telemetry only — drives no behaviour.
        _maybeRecordDisconnect(cmd.sessionId, hosted, prevState, data);
        // #885: a TERMINAL transition (failed / disconnected — NOT the
        // transient reconnecting/softDisconnected drop states, whose
        // auto-reconnect can still revive the session) means this session can
        // never deliver an attention tap again. Cancel the HOST's notification
        // unless a sibling session to the same host is still live (the #857
        // host-fallback can still route the tap there).
        if (_terminalStates.contains(data.state)) {
          _cancelAttentionForDeadHost(cmd.sessionId);
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
        // #838: stamp connect time as a latency fallback for a drop that
        // happens before the remote ever produced a byte.
        hosted.connectedAtMs = _nowMs();
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
    // #885: a user-closed session is terminal, but `_teardown` cancels the
    // state subscription BEFORE the controller emits `disconnected`, so the
    // state listener never sees this death — cancel here instead. The session
    // is already out of [_sessions], so the sibling-live guard only consults
    // the survivors.
    _cancelAttentionForDeadHost(cmd.sessionId);
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
    hosted.tmuxChannel = null; // #909: drop the control-mode adapter on teardown.
    hosted.refreshCoalescer?.cancel(); // #916: drop the refresh-client coalescer.
    hosted.refreshCoalescer = null;
    hosted.tmuxHandshakeTimer?.cancel(); // #982: cancel the handshake fallback timer.
    hosted.tmuxHandshakeTimer = null;
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
    // #909: drop the control-mode adapter with the shell so a reconnect rebuilds
    // a fresh parser/active-window view (no-op when null on the scrape path).
    hosted.tmuxChannel = null;
    // #916: cancel + drop the refresh-client coalescer so no pending write
    // storms a dead/reconnected shell.
    hosted.refreshCoalescer?.cancel();
    hosted.refreshCoalescer = null;
    // #982: reset the handshake gate so a reconnect re-arms it from scratch.
    hosted.tmuxHandshakeTimer?.cancel();
    hosted.tmuxHandshakeTimer = null;
    hosted.tmuxHandshakeConfirmed = false;
    hosted.pendingCcCols = null;
    hosted.pendingCcRows = null;
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

  /// #982: control mode FAILED to hand-shake (nested tmux, no tmux, a shell that
  /// never entered `-CC`) before the bounded timeout. Tear the control-mode
  /// channel down and fall back to the SCRAPE path so the connection WORKS
  /// instead of bricking on a swallowed/leaking channel: the live shell stays
  /// open, its raw bytes now render normally, and resizes drive the PTY winsize.
  /// A PTY resize nudge forces the (nested) remote to redraw so the swallowed
  /// initial screen reappears. No-op if the handshake already confirmed or the
  /// channel is already gone (reconnect raced us).
  void _fallbackToScrape(String sessionId, _HostedSession hosted) {
    if (hosted.tmuxHandshakeConfirmed || hosted.tmuxChannel == null) return;
    ctrace('task.host',
        'control-mode handshake timed out sid=$sessionId → scrape fallback');
    hosted.tmuxHandshakeTimer?.cancel();
    hosted.tmuxHandshakeTimer = null;
    // Drop the -CC adapter + coalescer; the output listener's `tmuxChannel == null`
    // branch now takes the unchanged scrape path for all subsequent bytes.
    hosted.tmuxChannel = null;
    hosted.refreshCoalescer?.cancel();
    hosted.refreshCoalescer = null;
    hosted.pendingCcCols = null;
    hosted.pendingCcRows = null;
    // Force the remote to repaint what -CC swallowed: a winsize resize makes a
    // shell/tmux redraw. dartssh2 rejects non-positive dims, so clamp.
    final cols = hosted.metrics.lastCols ?? 80;
    final rows = hosted.metrics.lastRows ?? 24;
    try {
      hosted.shell?.resize(cols < 1 ? 80 : cols, rows < 1 ? 24 : rows);
    } catch (_) {
      // The next real resize fixes the winsize.
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
      // Fresh attach => fresh attention-signal dedup state (#840).
      hosted.attentionScanner.reset();
      // #909 control mode (flag ON): the freshly-opened login shell is plain;
      // we ENTER tmux control mode by writing `tmux -CC …` into its stdin, then
      // route ALL subsequent output through the per-session TmuxControlChannel.
      // A fresh channel per (re)open mirrors the da2/attention reset above. When
      // the flag is OFF, `tmuxChannel` stays null and the listener below takes
      // the unchanged scrape path — so the shipped path is provably untouched.
      if (tmuxControlMode) {
        final tmux = TmuxControlChannel();
        hosted.tmuxChannel = tmux;
        // #916: the per-session refresh-client coalescer. Its settled emit is the
        // ONLY place a `refresh-client -C` is written to the shell — both the
        // resize handler and the switch-redraw enqueue here, so a burst collapses
        // to one write at the settled size (kills the multi-client-clamp storm).
        // Captured by `transport` so a stale open's coalescer can't write to a
        // reconnected shell (the shellGeneration guard already discarded it).
        hosted.refreshCoalescer = RefreshClientCoalescer(
          onSettled: (cols, rows) {
            // #982: NEVER write a `-CC` command before the handshake is confirmed.
            // A resize that settles right after connect (keyboard/layout) would
            // otherwise leak `refresh-client -C` into a plain/nested shell as
            // text. Buffer the latest size and flush ONE resize on confirm.
            if (!hosted.tmuxHandshakeConfirmed) {
              hosted.pendingCcCols = cols;
              hosted.pendingCcRows = rows;
              return;
            }
            try {
              // #906: frame through the channel so the resize's `%begin…%end` ack
              // is registered in the capture-correlation FIFO (and can't be
              // mistaken for a capture response).
              transport.send(tmux.frameResize(cols, rows));
            } catch (_) {
              // Channel closed; the next connect re-syncs.
            }
          },
        );
        try {
          transport.send(TmuxControlChannel.entryCommand);
          // #982: arm the fallback timer. If the `-CC` handshake (the P1000p DCS)
          // is not confirmed before it fires, control mode FAILED (nested tmux,
          // no tmux) — tear it down and fall back to scrape so the connection
          // still WORKS instead of bricking on a swallowed/leaking channel.
          hosted.tmuxHandshakeTimer?.cancel();
          hosted.tmuxHandshakeTimer = Timer(kTmuxHandshakeTimeout, () {
            if (!hosted.tmuxHandshakeConfirmed) {
              _fallbackToScrape(sessionId, hosted);
            }
          });
        } catch (_) {
          // If the entry write fails the channel is dead; the controller's close
          // path drives reconnect, which re-opens + re-enters control mode.
        }
      } else {
        hosted.tmuxChannel = null;
        hosted.refreshCoalescer = null;
      }
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
          // #909 control mode (flag ON): the raw stream is the `-CC` PROTOCOL,
          // not terminal bytes. Parse + demux per-pane, render only the ACTIVE
          // window's %output, and on an authoritative window switch force a
          // `refresh-client -C` redraw so the grid repaints to the new window.
          // DA2/attention scanning runs on the DEMUXED render bytes (the real
          // terminal content), not the protocol framing.
          final tmux = hosted.tmuxChannel;
          if (tmux != null) {
            final result = tmux.ingest(bytes);
            // #909/#916: control mode ENDED (tmux detached / server died). Surface
            // it as ONE clean shell close so the controller drives a SINGLE
            // reconnect through its normal close path — instead of silently
            // ignoring `%exit` (the prior behaviour) and leaving a half-dead
            // channel that the multi-client-clamp storm could re-trigger into a
            // connect→disconnect→reconnect LOOP (#916 root cause #2). Closing the
            // transport fires `transport.done` → `_dropShell` → the next
            // `connected` re-opens + re-enters control mode exactly once.
            if (result.exited) {
              try {
                hosted.shell?.close();
              } catch (_) {
                /* already closing */
              }
              return;
            }
            // #982: the `-CC` handshake just confirmed. Cancel the fallback
            // timer, mark the session live, and flush ONE buffered resize (the
            // size the UI settled at while we held every write). This is the
            // FIRST allowed `-CC` command — everything before it would have
            // leaked into a not-yet-`-CC` shell.
            if (result.handshakeConfirmed && !hosted.tmuxHandshakeConfirmed) {
              hosted.tmuxHandshakeConfirmed = true;
              hosted.tmuxHandshakeTimer?.cancel();
              hosted.tmuxHandshakeTimer = null;
              final cols =
                  hosted.pendingCcCols ?? hosted.metrics.lastCols ?? 80;
              final rows =
                  hosted.pendingCcRows ?? hosted.metrics.lastRows ?? 24;
              hosted.pendingCcCols = null;
              hosted.pendingCcRows = null;
              try {
                hosted.shell?.send(tmux.frameResize(cols, rows));
              } catch (_) {
                // Channel closed; the next connect re-syncs.
              }
            }
            // #982: still waiting on the handshake — do NOT issue any capture /
            // switch / resize command (it would leak). The buffered resize above
            // flushes once confirmed; capture requests re-fire on the next
            // notification. Render bytes (if any) still pass through below.
            if (!hosted.tmuxHandshakeConfirmed) {
              final render = result.renderBytes;
              if (render.isNotEmpty) {
                _scanAttention(sessionId, hosted, render);
                hosted.appendScrollback(render);
                _gateway.send(
                  SshOutputEvent(sessionId: sessionId, bytes: render).toJson(),
                );
              }
              return;
            }
            if (result.activeWindowChanged) {
              // #916 fix: a window switch must REPAINT the new window PROMPTLY and
              // reliably. The switch-repaint MUST NOT go through the resize
              // coalescer: that path has a 250ms trailing-edge settle AND a
              // same-size dedup, but a window switch re-emits `refresh-client -C`
              // at the SAME dims to force a repaint — so the dedup swallows it (or
              // a burst of switches + the 250ms delay collapses it) and the new
              // window never renders (blank grid — the cc_gestures regression).
              // Write the redraw DIRECTLY here, decoupled from the resize
              // coalescer. The coalescer stays dedicated to RESIZE (a burst of
              // DIFFERING dims → one settled write; same-size dedup is correct
              // there, and is the actual storm fix validated by cc_churn_bounded).
              // We do NOT touch the coalescer here, so any pending resize survives.
              final cols = hosted.metrics.lastCols ?? 80;
              final rows = hosted.metrics.lastRows ?? 24;
              try {
                // #906: frame through the channel (FIFO ack) so the ordering with
                // the following capture request is preserved.
                hosted.shell?.send(tmux.frameResize(cols, rows));
              } catch (_) {
                // Channel closed mid-switch; the next connect re-syncs.
              }
            }
            // #906 Stage 1: ATTACH or SWITCH → request `capture-pane` so the
            // active pane's CURRENT screen renders even with no `%output` (tmux
            // pushes none on attach / an idle switched-to window). Sent AFTER the
            // switch redraw so the capture ack follows the resize ack in the FIFO.
            // The correlated response is rendered by a later `ingest` (clear +
            // write), exactly as a real `-CC` client repaints.
            if (result.captureRequested) {
              try {
                hosted.shell?.send(tmux.frameCapture());
              } catch (_) {
                // Channel closed; the next connect re-syncs.
              }
            }
            final render = result.renderBytes;
            if (render.isNotEmpty) {
              _scanAttention(sessionId, hosted, render);
              hosted.appendScrollback(render);
              _gateway.send(
                SshOutputEvent(sessionId: sessionId, bytes: render).toJson(),
              );
            }
            return;
          }
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
          // Observe (don't alter) the post-DA2-strip bytes for in-band
          // agent-attention signals (#840). Slice 1: log each detection to the
          // durable lifecycle ring so the first on-device awaiting-moment proves
          // which form arrives. Defensive — a malformed sequence must never
          // crash the session.
          _scanAttention(sessionId, hosted, forward);
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

  /// The disconnect / dropped-into states (#838). Entering one of these from a
  /// non-drop state is a single DROP edge — the unit the disconnect telemetry
  /// records once. `reconnecting`/`softDisconnected` are included because they
  /// are the FIRST observable edge of an involuntary drop (the user sees the
  /// session leave `connected`); a later `failed` after reconnect-exhaustion is
  /// a SEPARATE edge and is logged as such, so a capture shows the full chain.
  static const Set<SshSessionState> _dropStates = {
    SshSessionState.softDisconnected,
    SshSessionState.reconnecting,
    SshSessionState.failed,
    SshSessionState.disconnected,
  };

  /// TERMINAL session states (#885) — the session is gone for good (a user
  /// close, an exhausted/aborted reconnect). Deliberately EXCLUDES the
  /// transient drop states (`softDisconnected`/`reconnecting`): their
  /// auto-reconnect can still revive the session, so its host's attention
  /// notification can still deliver and must survive them.
  static const Set<SshSessionState> _terminalStates = {
    SshSessionState.failed,
    SshSessionState.disconnected,
  };

  /// Cancel [sessionId]'s HOST attention notification once the host can no
  /// longer deliver a tap (#885): every hosted session to that host is in a
  /// terminal state (or gone). Skips when ANY sibling session to the same host
  /// is still non-terminal — the #857 host-fallback can still route the tap to
  /// it. The notifier's `cancel` is host-keyed (#847), so cancelling by the
  /// dead session's id clears the host's one shared notification slot.
  /// Best-effort + fire-and-forget: a cancel failure must never break the
  /// session pipeline. No-op when no notifier is wired (desktop / unit tests
  /// without one).
  void _cancelAttentionForDeadHost(String sessionId) {
    final notifier = _attentionNotifier;
    if (notifier == null) return;
    final host = hostOfSessionId(sessionId);
    for (final entry in _sessions.entries) {
      if (entry.key == sessionId) continue;
      if (hostOfSessionId(entry.key) != host) continue;
      if (!_terminalStates.contains(entry.value.controller.data.state)) {
        clifecycle(
          'attention',
          'cancel skipped (host $host still has live session ${entry.key}) '
              'session $sessionId',
        );
        return;
      }
    }
    clifecycle(
      'attention',
      'cancelled (session terminal, host $host dead) session $sessionId',
    );
    unawaited(
      notifier.cancel(sessionId).catchError((Object e) {
        clifecycle('attention', 'cancel-error: $e (session $sessionId)');
      }),
    );
  }

  /// Classify a drop edge's CAUSE from the (prev→new) transition + controller
  /// context (#838). Pure string label for telemetry; no behaviour depends on
  /// it. Cause taxonomy mirrors the Phase-0 disconnect-path map.
  static String _classifyDropCause(
    SshSessionState prev,
    SshSessionData data,
    SshSessionController controller,
  ) {
    final next = data.state;
    if (controller.userInitiatedDisconnect &&
        next == SshSessionState.disconnected) {
      return 'user-disconnect';
    }
    if (next == SshSessionState.failed) {
      final err = data.error ?? '';
      if (err.contains('reconnect exhausted')) return 'reconnect-exhausted';
      if (err.contains('No SSH response')) return 'handshake-timeout';
      if (err.contains('Authentication failed')) return 'auth-failed';
      if (err.contains('Host key rejected')) return 'hostkey-rejected';
      if (err.contains('TCP connect failed')) return 'tcp-connect-failed';
      if (err.contains('Could not load private key') ||
          err.contains('Private key contained no usable identity')) {
        return 'key-load-failed';
      }
      if (err.contains('Transport error')) {
        return controller.lastErrorUnreachable
            ? 'transport-unreachable'
            : 'transport-error';
      }
      return 'failed';
    }
    if (prev == SshSessionState.connected) {
      // Left a working session. softDisconnected = clean server close or a
      // probe/nudge-declared stale link; reconnecting = transient socket error.
      if (next == SshSessionState.softDisconnected) return 'server-or-stale';
      if (next == SshSessionState.reconnecting) {
        return controller.lastErrorUnreachable
            ? 'socket-unreachable'
            : 'socket-transient';
      }
    }
    return 'clean-close';
  }

  /// Emit ONE structured disconnect-cause line per DROP edge (#838).
  ///
  /// Fires only on the FIRST edge into a drop state from a non-drop state — so a
  /// `connected → softDisconnected → reconnecting → failed` chain logs each
  /// distinct edge once (visible as increasing `edge=`), but a repeated emit of
  /// the SAME drop state (e.g. a banner update while `failed`) does NOT re-fire.
  /// This is the "cut once" guard: a true double-fire would show two disconnect
  /// lines with the SAME prev→new at the same instant.
  ///
  /// LATENCY = tDetected − tLastActivity: how long the link was effectively dead
  /// before we noticed. tLastActivity is the last fresh remote byte (the honest
  /// "remote is producing output" signal, #759); when the session never produced
  /// a byte we fall back to the connect time so the number is bounded, flagged
  /// `latencyFrom=connect`. Allocation-light: one formatted string per drop edge.
  void _maybeRecordDisconnect(
    String sessionId,
    _HostedSession hosted,
    SshSessionState prev,
    SshSessionData data,
  ) {
    final next = data.state;
    final isDropEdge = _dropStates.contains(next) && !_dropStates.contains(prev);
    if (!isDropEdge) return;

    hosted.dropEdges += 1;
    final now = _nowMs();
    final lastActivity = hosted.lastRemoteByteAtMs ?? hosted.connectedAtMs;
    final latencyMs = lastActivity == null ? -1 : (now - lastActivity);
    final latencyFrom = hosted.lastRemoteByteAtMs != null
        ? 'lastByte'
        : (hosted.connectedAtMs != null ? 'connect' : 'none');
    final controller = hosted.controller;
    final cause = _classifyDropCause(prev, data, controller);

    clifecycle(
      'task.host',
      'disconnect: cause=$cause ${prev.name}→${next.name} '
          'latencyMs=$latencyMs from=$latencyFrom '
          'transport=${controller.client != null ? 'open' : 'closed'} '
          'attempt=${controller.reconnectAttempts} '
          'intent=${controller.userInitiatedDisconnect ? 'user' : 'auto'} '
          'edge=${hosted.dropEdges}',
    );
  }

  /// Emit a periodic liveness HEARTBEAT for each `connected` session (#838).
  ///
  /// Piggybacks the existing snapshot tick — NO new wakeful timer (battery /
  /// #806). Throttled to [_heartbeatIntervalMs] so it stays allocation-light
  /// even at the 2s snapshot cadence. The line records perceived-alive + the
  /// AGE of the last fresh remote byte: a SILENT drop (no transition fires)
  /// shows up as "heartbeat says alive but lastActivityAgeMs keeps growing" —
  /// exactly the undetected-drop window #766 will close. Skipped while the UI is
  /// backgrounded (the snapshot timer is stopped then anyway).
  void _maybeEmitHeartbeats() {
    final now = _nowMs();
    for (final entry in _sessions.entries) {
      final hosted = entry.value;
      if (hosted.controller.data.state != SshSessionState.connected) continue;
      if (now - hosted.lastHeartbeatAtMs < _heartbeatIntervalMs) continue;
      hosted.lastHeartbeatAtMs = now;
      final lastActivity = hosted.lastRemoteByteAtMs ?? hosted.connectedAtMs;
      final ageMs = lastActivity == null ? -1 : (now - lastActivity);
      clifecycle(
        'task.host',
        'heartbeat: alive state=connected lastActivityAgeMs=$ageMs '
            'edge=${hosted.dropEdges}',
      );
    }
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
      // Keep the raw error (incl. the SftpStatusError code) in the diagnostic
      // log; show the browser a clean empty-state message instead of dumping
      // `SftpStatusError: No such file(code 2)` in the body (#867).
      ctrace('task.host', 'sftp ls FAILED path=${cmd.path} — $e');
      _emitSftpError(
        cmd.sessionId,
        cmd.requestId,
        friendlySftpListError(e, cmd.path),
      );
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

  Future<void> _handleSftpUpload(SftpUploadCommand cmd) async {
    try {
      final sftp = await _ensureSftp(cmd.sessionId);
      if (sftp == null) {
        _emitSftpError(cmd.sessionId, cmd.requestId, 'Session not connected');
        return;
      }
      final written = await sftp.upload(cmd.path, cmd.bytes);
      if (_disposed) return;
      _gateway.send(
        SftpUploadDoneEvent(
          sessionId: cmd.sessionId,
          requestId: cmd.requestId,
          totalBytes: written,
        ).toJson(),
      );
    } catch (e) {
      ctrace('task.host', 'sftp upload FAILED path=${cmd.path} — $e');
      _emitSftpError(cmd.sessionId, cmd.requestId, 'Upload failed: $e');
    }
  }

  Future<void> _handleSftpUploadFile(SftpUploadFileCommand cmd) async {
    try {
      final sftp = await _ensureSftp(cmd.sessionId);
      if (sftp == null) {
        _emitSftpError(cmd.sessionId, cmd.requestId, 'Session not connected');
        return;
      }
      final written = await sftp.uploadFile(
        cmd.localPath,
        cmd.remotePath,
        onProgress: (sent, total) {
          if (_disposed) return;
          _gateway.send(
            SftpUploadProgressEvent(
              sessionId: cmd.sessionId,
              requestId: cmd.requestId,
              sent: sent,
              totalBytes: total,
            ).toJson(),
          );
        },
      );
      if (_disposed) return;
      _gateway.send(
        SftpUploadDoneEvent(
          sessionId: cmd.sessionId,
          requestId: cmd.requestId,
          totalBytes: written,
        ).toJson(),
      );
    } catch (e) {
      ctrace('task.host', 'sftp uploadFile FAILED remote=${cmd.remotePath} — $e');
      _emitSftpError(cmd.sessionId, cmd.requestId, 'Upload failed: $e');
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
  void _handleSetActive(
    bool active, [
    String? activeSessionId,
    String? activeHost,
  ]) {
    if (_disposed) return;
    // #840 telemetry: log every setActive the task isolate APPLIES so a device
    // capture can confirm the UI→task foreground/activeHost propagation actually
    // landed (paired with the UI-side SEND log in main.dart). Pins a stale/null
    // activeHost — the prime suspect for a bell firing while foregrounded.
    clifecycle(
      'attention',
      'setActive active=$active activeSessionId=$activeSessionId '
          'host=$activeHost',
    );
    // Always track the reported active session id (#840 Slice 2) + host (#847) —
    // even when [active] is unchanged the front-most TAB may have switched, and
    // that must update suppression. A null id/host (older UI / none) leaves it
    // unknown (degrades to "never host-suppress").
    final prevActiveHost = _activeHost;
    // #936: a TRANSIENT disconnect blip can push a setActive with BOTH a null
    // id AND a null host while the app is still FOREGROUNDED on that very tab —
    // the UI's front-most session momentarily fails to resolve. With nothing to
    // derive a host from, clobbering the last-known id/host to null opens the
    // suppression gate (`shouldPostAttention` returns true when frontHost is
    // null), so a same-host bell during the blip fires while the user is
    // looking at it. Retain the last-known id/host in that no-info case rather
    // than erasing it. Any usable signal — a non-null id (host derivable via
    // `hostOfSessionId`) or a non-null host — replaces it normally, as does a
    // genuine background (`active:false`).
    final hasUsableActive = (activeHost != null && activeHost.isNotEmpty) ||
        (activeSessionId != null && activeSessionId.isNotEmpty);
    if (active && !hasUsableActive) {
      // Foregrounded with no resolvable front-most session — keep
      // _activeSessionId/_activeHost at their previous values.
    } else {
      _activeSessionId = activeSessionId;
      _activeHost = activeHost;
    }
    // #856: when the active HOST actually CHANGES, arm the just-switched grace
    // for the newly-active host so its switch catch-up burst doesn't post a
    // redundant attention notification. Only on a real change (new != previous)
    // so re-asserting the same active host can't extend the window forever, and
    // only for a known host. The signal-side gate lives in [_maybePostAttention].
    if (activeHost != null &&
        activeHost != prevActiveHost &&
        switchGraceWindow > Duration.zero) {
      _switchGraceUntilMs[activeHost] =
          _nowMs() + switchGraceWindow.inMilliseconds;
    }
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

  /// Observe (don't alter) post-DA2-strip bytes for in-band agent-attention
  /// signals (#840). Slice 1 LOGS each detection to the durable lifecycle ring;
  /// Slice 2 ALSO posts an attention notification (with per-session tag +
  /// suppression). Defensive — a malformed sequence must never crash the
  /// session, so the whole scan is wrapped.
  void _scanAttention(String sessionId, _HostedSession hosted, List<int> bytes) {
    try {
      final signals = hosted.attentionScanner.feed(bytes);
      for (final sig in signals) {
        // Slice 1: durable lifecycle log (kept).
        clifecycle(
          'attention',
          '${sig.kind.name} ${sig.text == null ? '(no text)' : '"${sig.text}"'} '
              '(session $sessionId)',
        );
        // Slice 2: post an attention notification, unless suppressed because
        // the user is already looking at this session (#847) or the signal
        // arrived inside the (re)connect replay window (#851).
        _maybePostAttention(sessionId, hosted, sig);
      }
    } catch (e) {
      clifecycle('attention', 'scan-error: $e (session $sessionId)');
    }
  }

  /// Drive the attention scan + post path from a test, mirroring the live PTY
  /// listener (which `ingestOutputForTest` deliberately does NOT exercise).
  /// Used by the #840 Slice-2 host test + the emulator integration test seam.
  @visibleForTesting
  void feedAttentionForTest(String sessionId, List<int> bytes) {
    final hosted = _sessions[sessionId];
    if (hosted == null) return;
    _scanAttention(sessionId, hosted, bytes);
  }

  /// Post an attention notification for a Slice-1 detection (#840 Slice 2),
  /// honouring the suppression rule: skip when [sessionId] is the active session
  /// AND the app is foregrounded (the user is already looking at it). The
  /// notification is per-session tagged so a repeat from the same session
  /// REPLACES rather than stacks. Defensive — never throws into the output
  /// listener (a post failure must not crash the session). No-op when no
  /// notifier is wired (e.g. desktop / a test that didn't inject one), in which
  /// case the Slice-1 `clifecycle` log is the only effect.
  void _maybePostAttention(
    String sessionId,
    _HostedSession hosted,
    AttentionSignal sig,
  ) {
    final notifier = _attentionNotifier;
    if (notifier == null) return;
    // #851: (re)connect REPLAY suppression. A signal within `replayWindow` of
    // the session's most recent `connected` transition is REPLAYED scrollback /
    // catch-up (tmux re-attach, shell re-init, buffered history), not a live
    // moment — so it must NOT post. `connectedAtMs` is re-stamped on EVERY
    // connected transition (initial AND reconnect/softDisconnected→connected),
    // so the window auto-re-arms per reconnect. This is an ADDITIONAL gate that
    // composes with the #847 foreground-suppression + dedup below.
    final connectedAt = hosted.connectedAtMs;
    if (connectedAt != null && replayWindow > Duration.zero) {
      final sinceConnectedMs = _nowMs() - connectedAt;
      if (sinceConnectedMs < replayWindow.inMilliseconds) {
        clifecycle(
          'attention',
          'suppressed (reconnect-replay ${sinceConnectedMs}ms < '
              '${replayWindow.inMilliseconds}ms) session $sessionId',
        );
        return;
      }
    }
    // #856: JUST-SWITCHED grace. A signal whose host was made active within the
    // grace window (see [_handleSetActive]) is the switch CATCH-UP burst flushed
    // when the user switched TO this session — redundant, since they're now
    // looking at it. Suppress (log) rather than post. Keyed on the signal's HOST
    // to match #847's host unit, and gated on the host's injected clock. This
    // closes the activeHost-propagation race the foreground gate below can't.
    final signalHost = hostOfSessionId(sessionId);
    if (switchGraceWindow > Duration.zero) {
      final graceUntil = _switchGraceUntilMs[signalHost];
      if (graceUntil != null) {
        final nowMs = _nowMs();
        if (nowMs < graceUntil) {
          clifecycle(
            'attention',
            'suppressed (just-switched ${graceUntil - nowMs}ms remaining, host '
                '$signalHost) session $sessionId',
          );
          return;
        }
        // Window elapsed — drop the stale stamp so the map doesn't grow.
        _switchGraceUntilMs.remove(signalHost);
      }
    }
    // #847: host-level suppression — looking at ANY session to this host (incl.
    // a different one) while foregrounded suppresses the bell.
    final post = shouldPostAttention(
      signalSessionId: sessionId,
      activeSessionId: _activeSessionId,
      activeHost: _activeHost,
      foreground: _active,
    );
    if (!post) {
      clifecycle(
        'attention',
        'suppressed (foreground same-host) session $sessionId '
            '[${_attentionDecisionInputs(signalHost)}]',
      );
      return;
    }
    // #847: host-level cross-session dedup — a second bell from another session
    // to the SAME host within the window collapses into the first notification.
    final host = hostOfSessionId(sessionId);
    if (!_attentionDedup.allow(host)) {
      clifecycle(
        'attention',
        'deduped (host $host within window) session $sessionId',
      );
      return;
    }
    try {
      final n = AttentionNotification.build(sessionId: sessionId, signal: sig);
      // Fire-and-forget — the post is async (platform channel) but the output
      // listener is sync; a failure is swallowed (logged) so it can't break the
      // session byte pipeline.
      unawaited(
        notifier.post(n).catchError((Object e) {
          clifecycle('attention', 'post-error: $e (session $sessionId)');
        }),
      );
      // #840: log the FULL decision inputs on a POST so a device capture shows
      // WHY the gate passed — whether the task isolate saw the app as foreground
      // and what activeHost it believed at the moment the bell fired. The
      // suppression branches already log their inputs; this closes the gap for
      // the one path that previously logged only the outcome. No auth material:
      // host LABELS are already in the notification body.
      clifecycle(
        'attention',
        'posted notification session $sessionId '
            '[${_attentionDecisionInputs(signalHost)} reason=not-suppressed]',
      );
    } catch (e) {
      clifecycle('attention', 'build-error: $e (session $sessionId)');
    }
  }

  /// Render the attention-gate decision inputs for a lifecycle log line (#840
  /// telemetry). Shows what the TASK ISOLATE believed at decision time:
  /// `foreground` (the propagated UI foreground flag), the front-most
  /// `activeSessionId`/`activeHost` it last received, and the `signalHost` of the
  /// bell. Host LABELS only — no auth material (they already appear in
  /// notification bodies). `null` is rendered explicitly so a capture can tell a
  /// NEVER-PROPAGATED null apart from a real value.
  String _attentionDecisionInputs(String? signalHost) =>
      'foreground=$_active activeSessionId=$_activeSessionId '
      'activeHost=$_activeHost signalHost=$signalHost';

  void _pushSnapshots() {
    if (_disposed) return;
    // #838: piggyback the existing snapshot tick to emit liveness heartbeats —
    // no extra wakeful timer (battery / #806). Throttled inside.
    _maybeEmitHeartbeats();
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
    // #885: a graceful host dispose (FGS stop) kills every session — no
    // attention notification can deliver afterwards, so cancel each distinct
    // host's slot. One representative sessionId per host suffices (the
    // notifier's cancel is host-keyed, #847). A process death never runs this,
    // so a cold-start tap still finds its notification → the #885 dead-host
    // reconnect path composes.
    final notifier = _attentionNotifier;
    if (notifier != null) {
      final seenHosts = <String>{};
      for (final id in _sessions.keys) {
        if (!seenHosts.add(hostOfSessionId(id))) continue;
        unawaited(
          notifier.cancel(id).catchError((Object e) {
            clifecycle('attention', 'cancel-error: $e (session $id)');
          }),
        );
      }
    }
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

  /// #909: the tmux control-mode (`-CC`) render+resize adapter for this session,
  /// non-null ONLY while [tmuxControlMode] is ON. Created per shell (re)open in
  /// [SessionHost._ensureShell] and cleared with the shell in [SessionHost._dropShell]
  /// so a reconnect re-enters control mode with a fresh parser. Null on the
  /// shipped scrape path (flag OFF), where the output listener and resize handler
  /// take their unchanged branches.
  TmuxControlChannel? tmuxChannel;

  /// #916: trailing-edge-settle coalescer for this session's control-mode
  /// `refresh-client -C` writes. Both the UI resize handler AND the
  /// redraw-on-active-window-switch enqueue here, so a burst (or the multi-client
  /// clamp feedback storm) collapses to ONE write at the settled size — the SAME
  /// taming the PTY path got in #903/#905. Created with the channel in
  /// [SessionHost._ensureShell] (flag ON), cancelled + cleared with the shell in
  /// [SessionHost._dropShell]. Null on the scrape path (flag OFF).
  RefreshClientCoalescer? refreshCoalescer;

  /// #982: whether this session's `-CC` handshake (the `\x1bP1000p` DCS) has been
  /// confirmed. Until it is, NO `-CC` command may be written — in a NESTED tmux
  /// `tmux -CC attach` fails, the DCS never arrives, and any refresh-client /
  /// capture / control write LEAKS into the pane as literal text (the brick).
  /// The entry command is the only allowed pre-handshake write.
  bool tmuxHandshakeConfirmed = false;

  /// #982: the latest (cols,rows) the UI wanted while the handshake was still
  /// pending. Buffered so exactly ONE `refresh-client -C` flushes on confirm
  /// instead of leaking mid-handshake. Null once flushed / never set.
  int? pendingCcCols;
  int? pendingCcRows;

  /// #982: bounded timer armed when the entry command is written. If the `-CC`
  /// handshake is not confirmed before it fires, control mode FAILED (nested/no
  /// tmux) and the host tears the channel down and falls back to the scrape
  /// path. Cancelled on confirm and on shell drop.
  Timer? tmuxHandshakeTimer;

  /// Intercepts tmux's DA2 (Secondary Device Attributes) query in the remote
  /// byte stream and answers as a `tmux`-class terminal so tmux advertises the
  /// `hyperlinks` feature and FORWARDS OSC-8 links (instead of stripping them)
  /// to this client. See [Da2HyperlinkResponder]. Reset per shell open so a
  /// reconnect re-answers the fresh attach's query.
  final Da2HyperlinkResponder da2Responder = Da2HyperlinkResponder();

  /// Observes the remote byte stream for in-band agent-attention signals
  /// (#840): bare BEL, OSC 9, OSC 777, and the `notify-bell.sh` `# <message>`
  /// line. Slice 1 only LOGS detections to the `clifecycle` ring (no
  /// notification yet) so the first on-device awaiting-moment reveals which form
  /// actually arrives. Reset per shell open like [da2Responder]. Observe-only:
  /// it never alters the forwarded bytes. See [AttentionSignalScanner].
  final AttentionSignalScanner attentionScanner = AttentionSignalScanner();

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

  /// Wall-clock (ms since epoch) the session most recently reached `connected`
  /// (#838). Used as the tLastActivity fallback when a drop happens before the
  /// remote ever produced a byte, so the disconnect latency is bounded rather
  /// than -1.
  int? connectedAtMs;

  /// Monotonic count of DROP edges observed for this session (#838). Stamped on
  /// each `disconnect:` line as `edge=N` so a capture reveals double-fires
  /// (a true "cut once" violation = two lines with the same prev→new at once)
  /// and lets the heartbeat correlate to the most recent drop.
  int dropEdges = 0;

  /// Wall-clock (ms since epoch) of the last liveness-heartbeat line (#838).
  /// Throttles the heartbeat to one per [SessionHost._heartbeatIntervalMs]
  /// even though it piggybacks the faster snapshot tick.
  int lastHeartbeatAtMs = 0;

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
