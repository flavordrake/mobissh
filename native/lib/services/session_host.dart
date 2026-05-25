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

import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import 'session_messages.dart';
import 'task_ssh_gateway.dart';

/// Factory injected by the UI / tests. Production uses the default which
/// returns a real `SshSessionController` with the default socket opener.
typedef SshControllerFactory = SshSessionController Function();

SshSessionController _defaultControllerFactory() => SshSessionController();

/// Holds live SSH controllers, ingests commands from the UI side of the
/// gateway, and emits state/output/snapshot events back.
class SessionHost {
  SessionHost({
    required TaskSshGateway gateway,
    SshControllerFactory? controllerFactory,
    this.snapshotInterval = const Duration(seconds: 2),
  })  : _gateway = gateway,
        _factory = controllerFactory ?? _defaultControllerFactory {
    _commandSub = _gateway.incoming.listen(_dispatch);
    _snapshotTimer = Timer.periodic(snapshotInterval, (_) => _pushSnapshots());
    // Announce readiness as the FIRST task → UI payload (#539). The host is the
    // component that actually consumes commands, so its existence is the true
    // "ready" signal. The UI-side gateway buffers outbound commands until it
    // sees this and then flushes them in order — without it a connect sent
    // during task-isolate spin-up is dropped and the session deadlocks at idle.
    _gateway.send(const SshTaskReadyEvent().toJson());
  }

  final TaskSshGateway _gateway;
  final SshControllerFactory _factory;

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
    SshTaskCommand cmd;
    try {
      cmd = SshTaskCommand.fromJson(payload);
    } catch (e) {
      // Unknown shape — surface via error event so the UI side can log.
      final sid = payload['sessionId'] as String? ?? '';
      _gateway.send(SshErrorEvent(
        sessionId: sid,
        message: 'malformed command: $e',
      ).toJson());
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
        // Resize commands are accepted but the actual PTY plumbing is a
        // follow-up; the host records the last requested dims so the audit
        // snapshot can show them.
        final s = _sessions[cmd.sessionId];
        if (s != null) {
          s.metrics.lastCols = cmd.cols;
          s.metrics.lastRows = cmd.rows;
        }
      case SshRequestSnapshotCommand():
        final s = _sessions[cmd.sessionId];
        if (s != null) _emitSnapshot(cmd.sessionId, s);
      case SshHostKeyDecisionCommand():
        _handleHostKeyDecision(cmd);
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
    final hosted = _HostedSession(controller: controller);
    _sessions[cmd.sessionId] = hosted;

    // Forward state transitions back as events.
    hosted.stateSub = controller.stream.listen((data) {
      hosted.metrics.state = data.state.name;
      if (data.state == SshSessionState.reconnecting) {
        hosted.metrics.reconnectCount += 1;
        hosted.metrics.lastReconnectAtMs =
            DateTime.now().millisecondsSinceEpoch;
      }
      _maybeEmitHostKeyChallenge(cmd.sessionId, hosted, data);
      _emitStateData(cmd.sessionId, data);
    });

    final params = SshConnectParams(
      host: cmd.host,
      port: cmd.port,
      username: cmd.username,
      auth: _decodeAuth(cmd.authJson),
    );
    // Fire connect; failures surface through the state stream.
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
    // Track bytes-out and record into scrollback "echo" so the audit can
    // surface activity even before a PTY pipe is wired through the gateway.
    hosted.metrics.bytesOut += cmd.bytes.length;
    hosted.appendScrollback(cmd.bytes);
  }

  Future<void> _teardown(String sessionId, _HostedSession hosted) async {
    await hosted.stateSub?.cancel();
    hosted.stateSub = null;
    try {
      await hosted.controller.dispose();
    } catch (_) {/* ignore */}
    _gateway.send(SshClosedEvent(sessionId: sessionId).toJson());
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
    _gateway.send(SshHostKeyChallengeEvent(
      sessionId: sessionId,
      host: pending.host,
      port: pending.port,
      keyType: pending.keyType,
      fingerprint: pending.fingerprint,
    ).toJson());
  }

  void _emitState(String sessionId, SshSessionController controller) {
    _emitStateData(sessionId, controller.data);
  }

  void _emitStateData(String sessionId, SshSessionData data) {
    _gateway.send(SshStateEvent(
      sessionId: sessionId,
      state: data.state.name,
      error: data.error,
      host: data.host,
      port: data.port,
      username: data.username,
    ).toJson());
  }

  void _pushSnapshots() {
    if (_disposed) return;
    for (final entry in _sessions.entries) {
      _emitSnapshot(entry.key, entry.value);
    }
  }

  void _emitSnapshot(String sessionId, _HostedSession hosted) {
    _gateway.send(SshSnapshotEvent(
      sessionId: sessionId,
      state: hosted.controller.data.state.name,
      bytesIn: hosted.metrics.bytesIn,
      bytesOut: hosted.metrics.bytesOut,
      lastKeepaliveRttMs: hosted.metrics.lastKeepaliveRttMs,
      reconnectCount: hosted.metrics.reconnectCount,
      lastReconnectAtMs: hosted.metrics.lastReconnectAtMs,
      scrollbackTail: hosted.scrollbackTailString(),
    ).toJson());
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
    _gateway.send(SshOutputEvent(
      sessionId: sessionId,
      bytes: bytes,
    ).toJson());
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
      // Don't await controller.dispose — let GC handle it. Tests that
      // construct controllers via the stub factory have no live SSHClient
      // anyway.
    }
    _sessions.clear();
  }

  static SshAuth _decodeAuth(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == 'password') {
      return SshAuth.password(json['password'] as String);
    }
    if (type == 'key') {
      final pemB64 = json['pem'] as String;
      final pem = Uint8List.fromList(base64Decode(pemB64));
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
  int? lastCols;
  int? lastRows;
}

class _HostedSession {
  _HostedSession({required this.controller});

  final SshSessionController controller;
  StreamSubscription<SshSessionData>? stateSub;
  final SessionMetrics metrics = SessionMetrics();

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
