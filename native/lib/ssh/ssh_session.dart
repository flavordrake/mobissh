// SSH session lifecycle + state machine.
//
// Phase 1 (#501): connect, host-key verify (trust-on-first-use prompt),
// password/key auth, capture banner, expose state transitions. No shell
// or PTY (Phase 2). No persistence (Phase 3).
//
// #517: application-layer keepalive + reconnect-on-transient-socket-error so
// the user doesn't see raw `SSHSocketError(... errno = 103)` after returning
// from an app swap. dartssh2 sends keepalive pings; `handleTransportClosed`
// classifies the close cause and either reconnects (transient) or surfaces
// the appropriate terminal state.

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics/connect_trace.dart';
import 'host_key_store.dart';
import 'ssh_connect_params.dart';

/// Discrete lifecycle states for an SSH session. UI watches this directly
/// rather than inferring from boolean combinations.
enum SshSessionState {
  /// No connect attempt active.
  idle,

  /// TCP + SSH handshake in progress.
  connecting,

  /// Host key received but not trusted — waiting for user decision.
  awaitingHostKey,

  /// Host key trusted; userauth in progress.
  authenticating,

  /// Auth succeeded, transport open.
  connected,

  /// Transient socket error after `connected`; controller is auto-retrying.
  /// UI should show "Reconnecting…" rather than the raw socket error (#517).
  reconnecting,

  /// Auth or transport error — see [SshSessionData.error].
  failed,

  /// Session closed cleanly (user disconnect or remote close).
  disconnected,
}

/// Pending host-key verification details surfaced to the UI.
class PendingHostKey {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;

  const PendingHostKey({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });
}

/// Immutable snapshot of session state for Riverpod consumers.
class SshSessionData {
  final SshSessionState state;
  final String? error;
  final PendingHostKey? pendingHostKey;
  final String? banner;
  final String? remoteVersion;
  final String? host;
  final int? port;
  final String? username;

  const SshSessionData({
    this.state = SshSessionState.idle,
    this.error,
    this.pendingHostKey,
    this.banner,
    this.remoteVersion,
    this.host,
    this.port,
    this.username,
  });

  SshSessionData copyWith({
    SshSessionState? state,
    String? error,
    PendingHostKey? pendingHostKey,
    String? banner,
    String? remoteVersion,
    String? host,
    int? port,
    String? username,
    bool clearError = false,
    bool clearPendingHostKey = false,
    bool clearBanner = false,
  }) {
    return SshSessionData(
      state: state ?? this.state,
      error: clearError ? null : (error ?? this.error),
      pendingHostKey: clearPendingHostKey
          ? null
          : (pendingHostKey ?? this.pendingHostKey),
      banner: clearBanner ? null : (banner ?? this.banner),
      remoteVersion: remoteVersion ?? this.remoteVersion,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
    );
  }
}

/// Function signature for opening the raw SSH socket. Override in tests to
/// avoid real network IO.
typedef SshSocketOpener = Future<SSHSocket> Function(
  String host,
  int port, {
  Duration? timeout,
});

Future<SSHSocket> _defaultSocketOpener(
  String host,
  int port, {
  Duration? timeout,
}) {
  return SSHSocket.connect(host, port, timeout: timeout);
}

/// Optional override for the reconnect attempt itself (test seam).
/// Returning `true` indicates the reconnect completed successfully and the
/// controller should resume `connected`. Returning `false` indicates failure
/// and the controller should count the attempt + retry until exhausted.
typedef ReconnectAttempt = Future<bool> Function(SshConnectParams params);

/// Drives a single SSH session through its lifecycle.
///
/// Designed to be wrapped by a Riverpod `NotifierProvider` (see
/// `state/connection_providers.dart`). Exposes state via [stream] and the
/// current snapshot via [data]; mutation methods emit new immutable
/// snapshots.
class SshSessionController {
  SshSessionController({
    HostKeyStore? hostKeyStore,
    SshSocketOpener? socketOpener,
    this.handshakeTimeout = const Duration(seconds: 15),
    this.readyTimeout = const Duration(seconds: 25),
    this.keepAliveInterval = const Duration(seconds: 15),
    this.reconnectDelay = const Duration(seconds: 2),
    this.maxReconnectAttempts = 5,
    ReconnectAttempt? reconnectAttemptOverride,
  })  : _hostKeyStore = hostKeyStore ?? HostKeyStore(),
        _openSocket = socketOpener ?? _defaultSocketOpener,
        _reconnectAttempt = reconnectAttemptOverride;

  final HostKeyStore _hostKeyStore;
  final SshSocketOpener _openSocket;
  final ReconnectAttempt? _reconnectAttempt;

  /// Timeout for the underlying TCP connect (`SSHSocket.connect`).
  final Duration handshakeTimeout;

  /// Connecting-phase deadline: how long the session may sit in `connecting`
  /// (TCP open, SSH key-exchange + userauth in flight) before being force-
  /// failed. Bounds the half-open Tailscale path where TCP SYN is accepted but
  /// no SSH bytes ever flow — `client.authenticated` would otherwise hang
  /// forever (#542). Cancelled the instant state leaves `connecting`, so the
  /// human-paced host-key prompt (`awaitingHostKey`) is never timed out.
  /// Mirrors the PWA bridge's `readyTimeout` (`server/index.js`).
  final Duration readyTimeout;

  /// Interval at which dartssh2 sends application-layer keepalive pings to
  /// the server. 15s matches the PWA bridge (`server/index.js`) and is
  /// aggressive enough to keep NAT/Tailscale paths warm during background
  /// app swaps (#517).
  final Duration keepAliveInterval;

  /// Delay between transient-socket-error reconnect attempts. Short, fixed —
  /// the issue's acceptance criteria asks for "Reconnecting…" recovery
  /// within seconds, not exponential backoff (the PWA reaches the same
  /// conclusion in `scheduleReconnect`).
  final Duration reconnectDelay;

  /// Maximum number of consecutive reconnect attempts after a transient
  /// close. Once exhausted, transition to `failed` so the UI can surface
  /// the modal-style error.
  final int maxReconnectAttempts;

  final StreamController<SshSessionData> _stateCtrl =
      StreamController<SshSessionData>.broadcast();

  SshSessionData _data = const SshSessionData();
  SSHClient? _client;
  SSHSocket? _socket;
  Completer<bool>? _hostKeyCompleter;
  SshConnectParams? _lastParams;
  int _reconnectAttempts = 0;
  bool _userDisconnected = false;
  Timer? _reconnectTimer;
  Timer? _readyTimer;

  /// Most recent state snapshot. Always non-null.
  SshSessionData get data => _data;

  /// Stream of state changes. Emits the current snapshot on every transition.
  Stream<SshSessionData> get stream => _stateCtrl.stream;

  /// Underlying dartssh2 client once authenticated. Phase 2 will use this
  /// to open a shell session.
  SSHClient? get client => _client;

  /// Total number of consecutive transient-reconnect attempts since the last
  /// successful connect. Visible for the Connection Audit screen (#524).
  int get reconnectAttempts => _reconnectAttempts;

  /// Wall-clock timestamp (ms since epoch) of the most recent transition into
  /// `reconnecting`, or null if none has occurred. Visible for the
  /// Connection Audit screen (#524).
  int? get lastReconnectAtMs => _lastReconnectAtMs;
  int? _lastReconnectAtMs;

  /// Host-key trust store. Exposed for tests + future Phase 3 wiring.
  HostKeyStore get hostKeyStore => _hostKeyStore;

  /// Start a connect attempt. Safe to call only from [SshSessionState.idle],
  /// [SshSessionState.failed], or [SshSessionState.disconnected]. If already
  /// connecting/connected this is a no-op.
  Future<void> connect(SshConnectParams params) async {
    if (_data.state == SshSessionState.connecting ||
        _data.state == SshSessionState.authenticating ||
        _data.state == SshSessionState.connected ||
        _data.state == SshSessionState.awaitingHostKey ||
        _data.state == SshSessionState.reconnecting) {
      ctrace('task.ssh', 'connect: no-op (state=${_data.state.name})');
      return;
    }

    // Fresh user-initiated connect — clear the disconnect flag so we'll
    // reconnect again if the socket later flakes (#517).
    _userDisconnected = false;
    _lastParams = params;

    ctrace('task.ssh',
        'connect: ${params.host}:${params.port} → opening socket');
    _emit(SshSessionData(
      state: SshSessionState.connecting,
      host: params.host,
      port: params.port,
      username: params.username,
    ));
    _armReadyTimer();

    SSHSocket socket;
    try {
      socket = await _openSocket(
        params.host,
        params.port,
        timeout: handshakeTimeout,
      );
      _socket = socket;
      ctrace('task.ssh', 'connect: socket open OK → SSHClient handshake');
    } catch (e) {
      ctrace('task.ssh', 'connect: TCP connect FAILED — $e');
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'TCP connect failed: $e',
      ));
      return;
    }

    final bannerBuffer = StringBuffer();
    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: params.username,
        keepAliveInterval: keepAliveInterval,
        onVerifyHostKey: (type, fingerprint) =>
            _onVerifyHostKey(params, type, fingerprint),
        onPasswordRequest: () => _onPasswordRequest(params),
        identities: _identitiesFor(params),
        onUserauthBanner: (banner) {
          bannerBuffer.write(banner);
          _emit(_data.copyWith(banner: bannerBuffer.toString()));
        },
      );
      _client = client;
    } catch (e) {
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'SSHClient construction failed: $e',
      ));
      return;
    }

    try {
      // Authenticated future completes once userauth succeeds. State will
      // transition to `authenticating` from `onVerifyHostKey`'s resolution.
      await client.authenticated;
    } catch (e) {
      // If we already transitioned to `failed` (e.g. user rejected the host
      // key) preserve the more-specific error message rather than overwriting
      // it with a generic "auth aborted" reason.
      ctrace('task.ssh', 'connect: AUTH FAILED — $e');
      if (_data.state != SshSessionState.failed) {
        _emit(_data.copyWith(
          state: SshSessionState.failed,
          error: 'Authentication failed: $e',
        ));
      }
      try {
        client.close();
      } catch (_) {/* ignore */}
      return;
    }

    ctrace('task.ssh', 'connect: authenticated → CONNECTED');
    _emit(_data.copyWith(
      state: SshSessionState.connected,
      remoteVersion: client.remoteVersion,
      clearError: true,
    ));

    // Wire close notification. `handleTransportClosed` classifies the cause
    // and either reconnects (transient socket error) or transitions to the
    // appropriate terminal state.
    final closedClient = client;
    unawaited(closedClient.done
        .then((_) => handleTransportClosed(null))
        .catchError((e) => handleTransportClosed(e)));
  }

  /// Called when the SSH client's transport future resolves — either cleanly
  /// (`error == null`) or with a thrown error. Classifies the cause and
  /// drives the state machine. Public for testing; production callers should
  /// not invoke this directly.
  @visibleForTesting
  void handleTransportClosed(Object? error) {
    // Ignore stale done-futures from a previously-torn-down client (e.g.,
    // user called disconnect() and the old client.done resolves later).
    if (_userDisconnected) return;
    if (_data.state == SshSessionState.disconnected ||
        _data.state == SshSessionState.failed) {
      return;
    }

    if (error == null) {
      _emit(_data.copyWith(state: SshSessionState.disconnected));
      return;
    }

    final transient = isTransientSocketError(error);
    if (transient && _lastParams != null) {
      _scheduleReconnect(error);
      return;
    }

    _emit(_data.copyWith(
      state: SshSessionState.failed,
      error: 'Transport error: $error',
    ));
  }

  /// Classify whether [error] is a transient socket teardown that warrants
  /// an automatic reconnect (#517). Public for testing.
  static bool isTransientSocketError(Object error) {
    if (error is! SSHSocketError) return false;
    final inner = error.error;
    if (inner is SocketException) {
      final code = inner.osError?.errorCode;
      // Common transient codes on Android/Linux:
      //   103 = ECONNABORTED (software caused connection abort)
      //   104 = ECONNRESET
      //   110 = ETIMEDOUT
      //   113 = EHOSTUNREACH
      //   101 = ENETUNREACH
      //    32 = EPIPE
      if (code != null) {
        const transientCodes = <int>{32, 101, 103, 104, 110, 113};
        return transientCodes.contains(code);
      }
    }
    // Generic SSHSocketError without a concrete OSError (transport simply
    // dropped) — treat as transient too. Worst case we burn N reconnect
    // attempts before settling on `failed`.
    return true;
  }

  void _scheduleReconnect(Object error) {
    final params = _lastParams;
    if (params == null) {
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'Transport error: $error',
      ));
      return;
    }

    if (_reconnectAttempts >= maxReconnectAttempts) {
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'reconnect exhausted after $maxReconnectAttempts attempts: '
            '$error',
      ));
      return;
    }

    _emit(_data.copyWith(state: SshSessionState.reconnecting));
    _lastReconnectAtMs = DateTime.now().millisecondsSinceEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () async {
      if (_userDisconnected) return;
      _reconnectAttempts += 1;
      // Detach the now-dead client so a fresh connect() can run.
      _client = null;
      // Reset to a state from which connect() will proceed.
      _data = _data.copyWith(state: SshSessionState.idle);
      final ok = await _runReconnectAttempt(params);
      if (!ok && !_userDisconnected) {
        // Attempt failed — recurse via handleTransportClosed so the counter
        // continues to climb and we eventually settle on `failed`.
        handleTransportClosed(error);
      } else if (ok) {
        _reconnectAttempts = 0;
      }
    });
  }

  Future<bool> _runReconnectAttempt(SshConnectParams params) async {
    final override = _reconnectAttempt;
    if (override != null) {
      final ok = await override(params);
      if (ok) {
        _emit(_data.copyWith(
          state: SshSessionState.connected,
          clearError: true,
        ));
      }
      return ok;
    }
    try {
      await connect(params);
      return _data.state == SshSessionState.connected;
    } catch (_) {
      return false;
    }
  }

  /// Resolve a pending host-key prompt with `true` (trust + continue).
  void acceptHostKey() {
    final pending = _data.pendingHostKey;
    final completer = _hostKeyCompleter;
    if (pending == null || completer == null || completer.isCompleted) {
      return;
    }
    _hostKeyStore.trust(pending.host, pending.port, pending.fingerprint);
    _emit(_data.copyWith(
      state: SshSessionState.authenticating,
      clearPendingHostKey: true,
    ));
    completer.complete(true);
  }

  /// Resolve a pending host-key prompt with `false` (reject + abort).
  void rejectHostKey() {
    final completer = _hostKeyCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    _emit(_data.copyWith(
      state: SshSessionState.failed,
      error: 'Host key rejected by user',
      clearPendingHostKey: true,
    ));
    completer.complete(false);
  }

  /// Disconnect the active session. No-op when not connected.
  Future<void> disconnect() async {
    _userDisconnected = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _readyTimer?.cancel();
    _readyTimer = null;
    _reconnectAttempts = 0;
    _socket = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
        await client.done;
      } catch (_) {/* ignore */}
    }
    _emit(_data.copyWith(state: SshSessionState.disconnected));
  }

  /// Release controller resources. Safe to call multiple times.
  Future<void> dispose() async {
    await disconnect();
    if (!_stateCtrl.isClosed) {
      await _stateCtrl.close();
    }
  }

  /// Seed the controller with a connected state for tests. Production code
  /// reaches `connected` via [connect]; tests need a shortcut so they can
  /// exercise [handleTransportClosed] without standing up a real SSH server.
  @visibleForTesting
  void debugSetConnectedForTest(SshConnectParams params) {
    _userDisconnected = false;
    _lastParams = params;
    _emit(SshSessionData(
      state: SshSessionState.connected,
      host: params.host,
      port: params.port,
      username: params.username,
    ));
  }

  /// Drive the host-key verification path directly, bypassing the real SSH
  /// handshake. Returns the same `Future<bool>` the dartssh2 verify callback
  /// awaits: it resolves once [acceptHostKey] / [rejectHostKey] is called (or
  /// immediately `true` for an already-trusted key). Exists so the IPC
  /// round-trip (#536) can be exercised without a live socket.
  @visibleForTesting
  Future<bool> verifyHostKeyForTest(
    SshConnectParams params,
    String type,
    Uint8List fingerprint,
  ) {
    _lastParams = params;
    return _onVerifyHostKey(params, type, fingerprint);
  }

  // --- private helpers ---

  void _emit(SshSessionData next) {
    // Cancel the connecting-phase timer the instant state leaves `connecting`.
    // Centralizing here covers every transition path (awaitingHostKey,
    // authenticating, connected, failed) — including the human-paced host-key
    // prompt, which must never be timed out (#542). The timer is (re-)armed
    // explicitly in connect() after the `connecting` emit, so cancelling on a
    // `connecting` emit here is harmless.
    if (next.state != SshSessionState.connecting && _readyTimer != null) {
      ctrace('task.ssh',
          'readyTimer: cancelled (state→${next.state.name})');
      _readyTimer!.cancel();
      _readyTimer = null;
    }
    _data = next;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(next);
    }
  }

  /// Arm the connecting-phase deadline. If the session is STILL `connecting`
  /// when it fires, force-close the client + socket and surface `failed` (#542).
  void _armReadyTimer() {
    _readyTimer?.cancel();
    final secs = readyTimeout.inMilliseconds / 1000;
    ctrace('task.ssh', 'readyTimer: armed (${secs}s)');
    _readyTimer = Timer(readyTimeout, () {
      _readyTimer = null;
      if (_data.state != SshSessionState.connecting) return;
      ctrace('task.ssh',
          'readyTimer: FIRED while still connecting → force-fail');
      _forceCloseTransport();
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'No SSH response in ${secs.round()}s — host may be '
            'unreachable or asleep',
      ));
    });
  }

  void _forceCloseTransport() {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {/* ignore */}
    }
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.destroy();
      } catch (_) {/* ignore */}
    }
  }

  Future<bool> _onVerifyHostKey(
    SshConnectParams params,
    String type,
    Uint8List fingerprint,
  ) async {
    final hex = _fingerprintHex(fingerprint);
    if (_hostKeyStore.isTrusted(params.host, params.port, hex)) {
      _emit(_data.copyWith(state: SshSessionState.authenticating));
      return true;
    }

    final completer = Completer<bool>();
    _hostKeyCompleter = completer;
    _emit(_data.copyWith(
      state: SshSessionState.awaitingHostKey,
      pendingHostKey: PendingHostKey(
        host: params.host,
        port: params.port,
        keyType: type,
        fingerprint: hex,
      ),
    ));
    return completer.future;
  }

  FutureOr<String?> _onPasswordRequest(SshConnectParams params) {
    final auth = params.auth;
    if (auth is SshAuthPassword) return auth.password;
    return null;
  }

  List<SSHKeyPair>? _identitiesFor(SshConnectParams params) {
    final auth = params.auth;
    if (auth is! SshAuthKey) return null;
    try {
      final pemString = String.fromCharCodes(auth.pem);
      return SSHKeyPair.fromPem(pemString, auth.passphrase);
    } catch (e) {
      // Defer: surface as auth failure via onPasswordRequest fallback.
      return null;
    }
  }

  static String _fingerprintHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      final h = b.toRadixString(16).padLeft(2, '0');
      sb.write(h);
    }
    return sb.toString();
  }
}
