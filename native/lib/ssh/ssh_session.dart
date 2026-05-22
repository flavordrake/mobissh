// SSH session lifecycle + state machine.
//
// Phase 1 (#501): connect, host-key verify (trust-on-first-use prompt),
// password/key auth, capture banner, expose state transitions. No shell
// or PTY (Phase 2). No persistence (Phase 3).

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

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
  })  : _hostKeyStore = hostKeyStore ?? HostKeyStore(),
        _openSocket = socketOpener ?? _defaultSocketOpener;

  final HostKeyStore _hostKeyStore;
  final SshSocketOpener _openSocket;

  /// Timeout for the underlying TCP + SSH handshake.
  final Duration handshakeTimeout;

  final StreamController<SshSessionData> _stateCtrl =
      StreamController<SshSessionData>.broadcast();

  SshSessionData _data = const SshSessionData();
  SSHClient? _client;
  Completer<bool>? _hostKeyCompleter;

  /// Most recent state snapshot. Always non-null.
  SshSessionData get data => _data;

  /// Stream of state changes. Emits the current snapshot on every transition.
  Stream<SshSessionData> get stream => _stateCtrl.stream;

  /// Underlying dartssh2 client once authenticated. Phase 2 will use this
  /// to open a shell session.
  SSHClient? get client => _client;

  /// Host-key trust store. Exposed for tests + future Phase 3 wiring.
  HostKeyStore get hostKeyStore => _hostKeyStore;

  /// Start a connect attempt. Safe to call only from [SshSessionState.idle],
  /// [SshSessionState.failed], or [SshSessionState.disconnected]. If already
  /// connecting/connected this is a no-op.
  Future<void> connect(SshConnectParams params) async {
    if (_data.state == SshSessionState.connecting ||
        _data.state == SshSessionState.authenticating ||
        _data.state == SshSessionState.connected ||
        _data.state == SshSessionState.awaitingHostKey) {
      return;
    }

    _emit(SshSessionData(
      state: SshSessionState.connecting,
      host: params.host,
      port: params.port,
      username: params.username,
    ));

    SSHSocket socket;
    try {
      socket = await _openSocket(
        params.host,
        params.port,
        timeout: handshakeTimeout,
      );
    } catch (e) {
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

    _emit(_data.copyWith(
      state: SshSessionState.connected,
      remoteVersion: client.remoteVersion,
      clearError: true,
    ));

    // Wire close notification.
    unawaited(client.done.then((_) {
      if (_data.state == SshSessionState.connected) {
        _emit(_data.copyWith(state: SshSessionState.disconnected));
      }
    }).catchError((e) {
      _emit(_data.copyWith(
        state: SshSessionState.failed,
        error: 'Transport error: $e',
      ));
    }));
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

  // --- private helpers ---

  void _emit(SshSessionData next) {
    _data = next;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(next);
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
