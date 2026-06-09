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

  /// Server-initiated clean transport close while we were `connected` (#551).
  /// Distinct from a socket error: the connection was working, the peer closed
  /// it. The controller auto-schedules a reconnect immediately after emitting
  /// this so the user feels "always connected as long as creds are valid".
  softDisconnected,

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
typedef SshSocketOpener =
    Future<SSHSocket> Function(String host, int port, {Duration? timeout});

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

/// Optional override for the application-layer liveness probe (#737, test seam).
/// Production sends `client.ping()` (an SSH keepalive global-request that awaits
/// the server's reply). On a half-open socket (Doze) the reply never comes, so
/// the caller wraps this in a short timeout. Tests inject a completer they
/// control to simulate a live (resolves) or dead (never resolves / throws) link.
typedef LivenessProbe = Future<void> Function();

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
    this.maxReconnectAttempts = 10,
    this.maxUnreachableReconnectAttempts = 60,
    this.reconnectBackoffCap = const Duration(seconds: 30),
    this.unreachableReconnectInterval = const Duration(milliseconds: 1500),
    ReconnectAttempt? reconnectAttemptOverride,
    LivenessProbe? livenessProbeOverride,
  }) : _hostKeyStore = hostKeyStore ?? HostKeyStore(),
       _openSocket = socketOpener ?? _defaultSocketOpener,
       _reconnectAttempt = reconnectAttemptOverride,
       _livenessProbe = livenessProbeOverride;

  final HostKeyStore _hostKeyStore;
  final SshSocketOpener _openSocket;
  final ReconnectAttempt? _reconnectAttempt;
  final LivenessProbe? _livenessProbe;

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

  /// Base delay for the exponential transient-reconnect backoff (#551).
  /// Attempt `n` (0-based) waits `min(reconnectDelay * 1.5^n, reconnectBackoffCap)`.
  /// The PWA reaches the same 2s→30s schedule in `scheduleReconnect`.
  final Duration reconnectDelay;

  /// Ceiling for the exponential transient backoff. Delays never exceed this
  /// regardless of attempt count (#551).
  final Duration reconnectBackoffCap;

  /// Fixed retry interval for an unreachable host (#551). No backoff — a
  /// sleeping Tailscale peer or a network that's about to come back benefits
  /// from a tight, constant cadence rather than progressive slowdown.
  final Duration unreachableReconnectInterval;

  /// Maximum number of consecutive reconnect attempts after a NON-unreachable
  /// transient close. Once exhausted, transition to `failed` so the UI can
  /// surface the modal-style error (#551: 10).
  final int maxReconnectAttempts;

  /// Maximum number of consecutive reconnect attempts when the last error was
  /// classified as host-unreachable (#551: 60 → ~90s of fixed 1.5s retries).
  final int maxUnreachableReconnectAttempts;

  final StreamController<SshSessionData> _stateCtrl =
      StreamController<SshSessionData>.broadcast();

  SshSessionData _data = const SshSessionData();
  SSHClient? _client;
  SSHSocket? _socket;
  Completer<bool>? _hostKeyCompleter;
  SshConnectParams? _lastParams;
  int _reconnectAttempts = 0;

  /// The single authoritative "user intent suppresses auto-reconnect" bit
  /// (#813). Set by [disconnect], reset by [connect]. This is the one bit the
  /// issue permits ("keep at most ONE explicit user-intent bit"): the
  /// `disconnected` state alone is AMBIGUOUS — both a user ✕ (suppress) and an
  /// involuntary clean close while not-connected (don't suppress) land there —
  /// so a bit is genuinely required to discriminate them. Read it only through
  /// [_autoReconnectSuppressed]; the order-dependent CHECK sites (transport
  /// close, probe, reconnect timer) read STATE, not this flag (per
  /// `rules/state-management.md`).
  bool _userDisconnected = false;
  Timer? _reconnectTimer;
  Timer? _readyTimer;

  /// Whether the USER explicitly disconnected, suppressing auto-reconnect
  /// (#813). The owner's rule: ✕/Disconnect is a deliberate "forget" that must
  /// never be auto-revived. Backed by the single [_userDisconnected] bit and
  /// kept in lockstep with the state machine — when set, the session is always
  /// in the `disconnected` terminal state (asserted in
  /// [_assertSuppressConsistent]).
  bool get _autoReconnectSuppressed => _userDisconnected;

  /// Read-only view of the user-intent bit (#838). The disconnect-cause
  /// classifier reads this to label a drop as user-initiated (✕/Disconnect) vs.
  /// involuntary, since the `disconnected` state alone is ambiguous between the
  /// two. Pure telemetry — no behaviour depends on this getter.
  bool get userInitiatedDisconnect => _userDisconnected;

  /// Debug-only invariant: when the user-intent bit is set, the session MUST be
  /// in the `disconnected` terminal state. (The converse does NOT hold —
  /// `disconnected` is also reached by an involuntary clean close.) Guards
  /// against a future transition setting the bit without driving the state, or
  /// leaving it set after re-entering a live phase. No-op in release builds.
  void _assertSuppressConsistent() {
    assert(
      !_userDisconnected || _data.state == SshSessionState.disconnected,
      'user-intent bit set but state=${_data.state.name} (expected disconnected)',
    );
  }

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

  /// Wall-clock timestamp (ms since epoch) the session entered its current
  /// terminal-drop state (`failed` or involuntary `disconnected`), or null when
  /// not in such a state. Drives the staleness check in [resumeReconnectIfStale]
  /// (#813).
  int? _terminalSinceMs;

  /// Whether the most recent reconnect-triggering error was classified as a
  /// host-unreachable condition (no route, refused, timed out, "no SSH
  /// response"). Drives the fixed-interval fast-retry policy and is surfaced to
  /// the Connection Audit screen via `SessionMetrics` (#551).
  bool get lastErrorUnreachable => _lastErrorUnreachable;
  bool _lastErrorUnreachable = false;

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
        _data.state == SshSessionState.softDisconnected ||
        _data.state == SshSessionState.reconnecting) {
      ctrace('task.ssh', 'connect: no-op (state=${_data.state.name})');
      return;
    }

    // Fresh user-initiated connect — clear the user-intent bit so we'll
    // reconnect again if the socket later flakes (#517). The `connecting` emit
    // below moves state off `disconnected`, keeping the bit and the state-
    // derived suppress predicate in lockstep (#813).
    _userDisconnected = false;
    _lastParams = params;

    ctrace(
      'task.ssh',
      'connect: ${params.host}:${params.port} → opening socket',
    );
    _emit(
      SshSessionData(
        state: SshSessionState.connecting,
        host: params.host,
        port: params.port,
        username: params.username,
      ),
    );
    _armReadyTimer();

    // Hydrate persisted host-key trust before the handshake so the verify
    // callback sees previously-accepted fingerprints and never re-prompts for
    // a known host:port (#565). Cheap (a SharedPreferences read) and only the
    // first connect pays it; subsequent connects find it already hydrated.
    if (!_hostKeyStore.isHydrated) {
      await _hostKeyStore.ready;
    }

    // Fail fast on an unusable private key BEFORE touching the network. A
    // passphrase-encrypted key with the wrong passphrase (or a blob mangled on
    // the vault/import round-trip) makes `SSHKeyPair.fromPem` throw. Previously
    // `_identitiesFor` swallowed that to `null`; for key auth there's no
    // password fallback, so dartssh2 was handed no auth method and
    // `client.authenticated` hung forever — host key accepted, login never
    // completed (the device key-auth hang). Parse here, reuse below, and on
    // failure surface a clear `failed` instead of a silent hang.
    List<SSHKeyPair>? identities;
    final auth = params.auth;
    if (auth is SshAuthKey) {
      try {
        identities = SSHKeyPair.fromPem(
          String.fromCharCodes(auth.pem),
          auth.passphrase,
        );
      } catch (e) {
        _readyTimer?.cancel();
        _readyTimer = null;
        ctrace('task.ssh', 'connect: key parse FAILED — $e');
        _emit(
          _data.copyWith(
            state: SshSessionState.failed,
            error:
                'Could not load private key — wrong passphrase or '
                'unsupported key format ($e)',
          ),
        );
        return;
      }
      if (identities.isEmpty) {
        _readyTimer?.cancel();
        _readyTimer = null;
        _emit(
          _data.copyWith(
            state: SshSessionState.failed,
            error: 'Private key contained no usable identity',
          ),
        );
        return;
      }
    }

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
      _emit(
        _data.copyWith(
          state: SshSessionState.failed,
          error: 'TCP connect failed: $e',
        ),
      );
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
        identities: identities,
        onUserauthBanner: (banner) {
          bannerBuffer.write(banner);
          _emit(_data.copyWith(banner: bannerBuffer.toString()));
        },
      );
      _client = client;
    } catch (e) {
      _emit(
        _data.copyWith(
          state: SshSessionState.failed,
          error: 'SSHClient construction failed: $e',
        ),
      );
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
        _emit(
          _data.copyWith(
            state: SshSessionState.failed,
            error: 'Authentication failed: $e',
          ),
        );
      }
      try {
        client.close();
      } catch (_) {
        /* ignore */
      }
      return;
    }

    ctrace('task.ssh', 'connect: authenticated → CONNECTED');
    _emit(
      _data.copyWith(
        state: SshSessionState.connected,
        remoteVersion: client.remoteVersion,
        clearError: true,
      ),
    );

    // Wire close notification. `handleTransportClosed` classifies the cause
    // and either reconnects (transient socket error) or transitions to the
    // appropriate terminal state.
    final closedClient = client;
    unawaited(
      closedClient.done
          .then((_) => handleTransportClosed(null))
          .catchError((e) => handleTransportClosed(e)),
    );
  }

  /// Actively verify the socket is still alive (#737 — wake-from-sleep freeze).
  ///
  /// During Doze the SSH TCP socket can die HALF-OPEN: no clean close ever
  /// reaches the app, and the 15s keepalive timer is frozen by the OS. On
  /// resume the session is therefore still `connected` over a DEAD socket — the
  /// UI forwards input into a dead pipe, nothing comes back, and the
  /// transport's `done` future never resolves so the #517/#590 reconnect path
  /// is never armed. The session is a zombie.
  ///
  /// This sends an immediate application-layer SSH keepalive ping
  /// (`client.ping()`, a global-request that AWAITS the server's reply) with a
  /// SHORT [timeout]. If the reply doesn't arrive in time — or the ping throws
  /// (broken pipe) — the socket is declared dead NOW (not "never"): the session
  /// transitions `connected → softDisconnected` and the existing reconnect path
  /// re-opens the shell. A live link replies promptly and the session stays
  /// `connected`, so a normal wake never triggers a spurious reconnect.
  ///
  /// No-op unless currently `connected` (nothing to probe otherwise) or if the
  /// user has disconnected. Safe to call repeatedly (e.g. on every resume).
  ///
  /// Returns `true` when the transport ping replied (link answered — the
  /// session is left `connected`), `false` when the ping failed/timed out and
  /// the session was driven into the reconnect path (#737). The caller
  /// ([SessionHost]) uses the return value to decide whether to escalate to the
  /// END-TO-END nudge check (#759): a ping that answers does NOT prove the
  /// REMOTE shell/tmux is responsive — only that SSH is up — so when the session
  /// was already stale going into resume the host nudges the channel and watches
  /// for fresh remote bytes.
  Future<bool> probeLiveness({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    _assertSuppressConsistent();
    // #813: the resume entry point also re-arms a STALE dropped session. A
    // `failed` (or involuntary-`disconnected`) session has no live socket to
    // ping — instead of skipping it (the zombie-tile bug), re-enter the
    // reconnect path from held params. A user disconnect is excluded inside
    // [resumeReconnectIfStale]. We return false (not alive) for these.
    if (_data.state == SshSessionState.failed ||
        _data.state == SshSessionState.disconnected) {
      await resumeReconnectIfStale();
      return false;
    }
    // A user-disconnected session is `disconnected`, never `connected`, so the
    // state guard alone excludes it (#813 — read state, not the flag).
    if (_data.state != SshSessionState.connected) return false;
    if (_lastParams == null) return false;

    final probe = _livenessProbe ?? _defaultLivenessProbe;
    var alive = false;
    try {
      await probe().timeout(timeout);
      alive = true;
    } catch (e) {
      // TimeoutException (half-open socket — no reply) or a transport error
      // (broken pipe). Either way the link is dead.
      clifecycle('task.ssh', 'probeLiveness: ping-failed → reconnect ($e)');
    }
    if (alive) {
      // Transport answered. This is NOT proof the remote shell is live (#759);
      // the host decides whether to escalate to the nudge check. Stay connected.
      ctrace('task.ssh', 'probeLiveness: ping-alive (transport answered)');
      return true;
    }
    // Re-check state: a real transport close (or a user disconnect → the
    // `disconnected` state) could have raced in while we awaited the probe and
    // already moved us off `connected`.
    if (_data.state != SshSessionState.connected) {
      return false;
    }
    _lastErrorUnreachable = false;
    _emit(_data.copyWith(state: SshSessionState.softDisconnected));
    _scheduleReconnect(null);
    return false;
  }

  /// Declare the current `connected` session STALE/DEAD at the APPLICATION layer
  /// (#759) and drive it through the existing reconnect path. Used by
  /// [SessionHost] when the transport ping answered but an end-to-end nudge
  /// produced NO fresh remote bytes (a frozen tmux/shell over a live socket).
  ///
  /// No-op unless currently `connected` (the ping-fail path in [probeLiveness]
  /// may already have moved us off `connected`) or if the user disconnected.
  /// Reuses the same `connected → softDisconnected → reconnect` machinery as a
  /// clean server close, so #517/#590 reconnect behaviour is unchanged.
  void softDisconnectForResume() {
    _assertSuppressConsistent();
    // `connected` precondition already excludes a user-disconnected
    // (`disconnected`) session (#813 — state, not flag).
    if (_data.state != SshSessionState.connected) return;
    if (_lastParams == null) return;
    clifecycle(
      'task.ssh',
      'probeLiveness: STALE(no-bytes-after-nudge) → reconnect',
    );
    _lastErrorUnreachable = false;
    _emit(_data.copyWith(state: SshSessionState.softDisconnected));
    _scheduleReconnect(null);
  }

  /// Re-arm reconnect for a STALE dropped session on app-resume (#813).
  ///
  /// The PWA's `visibilitychange` retry re-attempts a session that gave up
  /// (`failed`) or dropped involuntarily (`disconnected` reached without a user
  /// ✕) once it's been dead longer than [staleThreshold]. Native previously
  /// SKIPPED `failed` on resume, leaving a zombie tile that needed a manual ✕.
  /// This closes that gap by re-entering the existing reconnect path from the
  /// controller's held [_lastParams].
  ///
  /// Gated on STATE, with the single user-intent bit as the only discriminator:
  ///  - Only `failed` or `disconnected` re-arm (a live/connecting/reconnecting
  ///    session is already healthy or trying — nothing to re-arm).
  ///  - A USER disconnect must never be auto-revived (the owner's "✕ is forget"
  ///    rule). The `disconnected` state is ambiguous — a user ✕ and an
  ///    involuntary clean close both land there — so the one permitted
  ///    user-intent bit ([_autoReconnectSuppressed]) discriminates them: re-arm
  ///    a `disconnected` session ONLY when it is NOT user-suppressed.
  ///  - The drop must be at least [staleThreshold] old ([_terminalSinceMs]).
  ///
  /// No-op when there are no params to reconnect with. Reuses [_scheduleReconnect]
  /// so backoff/ceiling/telemetry are identical to a transient drop.
  Future<void> resumeReconnectIfStale({
    Duration staleThreshold = const Duration(seconds: 8),
  }) async {
    _assertSuppressConsistent();
    final state = _data.state;
    final isDrop =
        state == SshSessionState.failed ||
        state == SshSessionState.disconnected;
    if (!isDrop) return;
    // A user disconnect is a deliberate "forget" — never auto-revive it.
    if (_autoReconnectSuppressed) return;
    if (_lastParams == null) return;
    final since = _terminalSinceMs;
    if (since != null) {
      final age = DateTime.now().millisecondsSinceEpoch - since;
      if (age < staleThreshold.inMilliseconds) return;
    }
    clifecycle(
      'task.ssh',
      'resume: stale ${state.name} → re-arm reconnect',
    );
    // Reset the attempt counter so the re-arm gets a full reconnect budget
    // rather than inheriting the exhausted count that drove us to `failed`.
    _reconnectAttempts = 0;
    _lastErrorUnreachable = false;
    _scheduleReconnect(null);
  }

  /// User-initiated FORCE reconnect (#817, Active Sessions UI Reconnect button).
  ///
  /// Unlike [resumeReconnectIfStale] (the app-resume re-arm), this:
  ///  - ignores the staleness threshold — the user tapped Reconnect, so retry
  ///    NOW rather than waiting for a drop to age past 8s,
  ///  - clears the user-suppressed bit — tapping Reconnect IS an explicit
  ///    "revive this session" intent, so it overrides a prior user ✕/Disconnect
  ///    (`disconnected` by user). The ✕ remains the "forget" action; Reconnect
  ///    is the "bring it back" action,
  ///  - and for a session already mid-reconnect (`softDisconnected` /
  ///    `reconnecting`) it cancels the pending backoff timer and retries
  ///    immediately ("force now").
  ///
  /// Re-enters the existing reconnect path from the controller's held
  /// [_lastParams] — so NO auth is re-supplied UI-side (creds live task-side).
  /// No-op for a healthy/connecting session (nothing to reconnect) or when there
  /// are no params to reconnect with (never reached `connected`).
  void reconnectNow() {
    final state = _data.state;
    final canReconnect =
        state == SshSessionState.failed ||
        state == SshSessionState.disconnected ||
        state == SshSessionState.softDisconnected ||
        state == SshSessionState.reconnecting;
    if (!canReconnect) return;
    if (_lastParams == null) return;
    // Explicit revive: overrides a prior user disconnect. Keep the bit and the
    // state-derived suppress predicate consistent — the `reconnecting` emit in
    // [_scheduleReconnect] moves state off `disconnected`/`failed` (#813).
    _userDisconnected = false;
    // Force-now: drop any pending backoff timer and restart with a full budget.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _lastErrorUnreachable = false;
    clifecycle('task.ssh', 'reconnectNow: user-forced ${state.name} → reconnect');
    _scheduleReconnect(null);
  }

  Future<void> _defaultLivenessProbe() async {
    final client = _client;
    if (client == null) {
      // No live client but state says connected — treat as dead.
      throw StateError('no client to ping');
    }
    await client.ping();
  }

  /// Called when the SSH client's transport future resolves — either cleanly
  /// (`error == null`) or with a thrown error. Classifies the cause and
  /// drives the state machine. Public for testing; production callers should
  /// not invoke this directly.
  @visibleForTesting
  void handleTransportClosed(Object? error) {
    _assertSuppressConsistent();
    // Ignore stale done-futures from a previously-torn-down client. A user
    // disconnect lands in `disconnected`; a prior failure lands in `failed` —
    // both terminal. The state check subsumes the old `_userDisconnected` guard
    // (#813): disconnect() drives `disconnected`, so a late close is ignored.
    if (_data.state == SshSessionState.disconnected ||
        _data.state == SshSessionState.failed) {
      return;
    }

    if (error == null) {
      // Clean transport close. If we were `connected`, the server (or a clean
      // network teardown) dropped a working session — surface
      // `softDisconnected` and auto-reconnect so the user feels "always
      // connected as long as creds are valid" (#551). Any other state (never
      // reached `connected`, or already mid-reconnect) is a real close.
      if (_data.state == SshSessionState.connected && _lastParams != null) {
        _lastErrorUnreachable = false;
        _emit(_data.copyWith(state: SshSessionState.softDisconnected));
        _scheduleReconnect(null);
        return;
      }
      _emit(_data.copyWith(state: SshSessionState.disconnected));
      return;
    }

    final transient = isTransientSocketError(error);
    if (transient && _lastParams != null) {
      _lastErrorUnreachable = isUnreachableError(error);
      _scheduleReconnect(error);
      return;
    }

    _emit(
      _data.copyWith(
        state: SshSessionState.failed,
        error: 'Transport error: $error',
      ),
    );
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

  /// Classify whether [error] indicates the host is unreachable rather than a
  /// mid-session blip (#551). Unreachable errors get a fixed fast-retry cadence
  /// (a sleeping Tailscale peer / network coming back benefits from a tight,
  /// constant interval) with a much higher attempt ceiling than a generic
  /// transient drop. Matches on errno (no-route / refused / timed-out / net-
  /// unreach) AND on message text so the `readyTimeout` "No SSH response"
  /// failure and bare `SSHSocketError`s without an OSError are caught. Public
  /// for testing.
  static bool isUnreachableError(Object error) {
    if (error is SSHSocketError) {
      final inner = error.error;
      if (inner is SocketException) {
        final code = inner.osError?.errorCode;
        if (code != null) {
          // 101 ENETUNREACH, 110 ETIMEDOUT, 111 ECONNREFUSED, 113 EHOSTUNREACH
          const unreachableCodes = <int>{101, 110, 111, 113};
          return unreachableCodes.contains(code);
        }
      }
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('unreachable') ||
        msg.contains('no ssh response') ||
        msg.contains('no route to host') ||
        msg.contains('econnrefused') ||
        msg.contains('connection refused') ||
        msg.contains('etimedout');
  }

  /// Compute the reconnect delay for [attempt] (0-based) under the #551 policy.
  /// Unreachable → fixed [unreachableReconnectInterval]; otherwise exponential
  /// `reconnectDelay * 1.5^attempt` clamped to [reconnectBackoffCap]. Public
  /// for testing the backoff progression without real wall-clock timers.
  @visibleForTesting
  Duration reconnectDelayFor(int attempt, {required bool unreachable}) {
    if (unreachable) return unreachableReconnectInterval;
    final baseMs = reconnectDelay.inMilliseconds;
    final scaled = baseMs * _pow1_5(attempt);
    final capped = scaled > reconnectBackoffCap.inMilliseconds
        ? reconnectBackoffCap.inMilliseconds
        : scaled.round();
    return Duration(milliseconds: capped);
  }

  static double _pow1_5(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 1.5;
    }
    return v;
  }

  void _scheduleReconnect(Object? error) {
    final params = _lastParams;
    if (params == null) {
      _emit(
        _data.copyWith(
          state: SshSessionState.failed,
          error: 'Transport error: $error',
        ),
      );
      return;
    }

    final unreachable = _lastErrorUnreachable;
    final ceiling = unreachable
        ? maxUnreachableReconnectAttempts
        : maxReconnectAttempts;
    if (_reconnectAttempts >= ceiling) {
      _emit(
        _data.copyWith(
          state: SshSessionState.failed,
          error:
              'reconnect exhausted after $ceiling attempts: '
              '${error ?? 'server disconnect'}',
        ),
      );
      return;
    }

    final delay = reconnectDelayFor(
      _reconnectAttempts,
      unreachable: unreachable,
    );
    _emit(_data.copyWith(state: SshSessionState.reconnecting));
    _lastReconnectAtMs = DateTime.now().millisecondsSinceEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      // disconnect() cancels this timer, so reaching here while suppressed
      // should be impossible — but read the state-derived predicate (not the
      // flag) as the consistency guard (#813).
      if (_autoReconnectSuppressed) return;
      _reconnectAttempts += 1;
      // Detach the now-dead client so a fresh connect() can run.
      _client = null;
      // Reset to a state from which connect() will proceed.
      _data = _data.copyWith(state: SshSessionState.idle);
      final ok = await _runReconnectAttempt(params);
      if (!ok && !_autoReconnectSuppressed) {
        // Attempt failed — re-schedule directly (not via handleTransportClosed,
        // whose null-error path would treat the idle reset as a clean close and
        // bail). The counter keeps climbing under the same ceiling/backoff until
        // we settle on `failed`. Preserves `_lastErrorUnreachable` so the policy
        // (fixed-interval vs. exponential) stays stable across attempts.
        _scheduleReconnect(error);
      } else if (ok) {
        _reconnectAttempts = 0;
        _lastErrorUnreachable = false;
      }
    });
  }

  Future<bool> _runReconnectAttempt(SshConnectParams params) async {
    final override = _reconnectAttempt;
    if (override != null) {
      final ok = await override(params);
      if (ok) {
        _emit(
          _data.copyWith(state: SshSessionState.connected, clearError: true),
        );
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
    _emit(
      _data.copyWith(
        state: SshSessionState.authenticating,
        clearPendingHostKey: true,
      ),
    );
    completer.complete(true);
  }

  /// Resolve a pending host-key prompt with `false` (reject + abort).
  void rejectHostKey() {
    final completer = _hostKeyCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    _emit(
      _data.copyWith(
        state: SshSessionState.failed,
        error: 'Host key rejected by user',
        clearPendingHostKey: true,
      ),
    );
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
    _lastErrorUnreachable = false;
    _socket = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
        await client.done;
      } catch (_) {
        /* ignore */
      }
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
    _emit(
      SshSessionData(
        state: SshSessionState.connected,
        host: params.host,
        port: params.port,
        username: params.username,
      ),
    );
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
    // Manage the machine-paced phase deadline timer per transition.
    //
    // `connecting` and `authenticating` are BOTH machine-paced phases that must
    // be bounded: the handshake (#542) and userauth (#563) can each stall after
    // a half-open path is established (TCP SYN accepted but no SSH bytes flow,
    // or auth negotiation never completes). The previous design cancelled the
    // timer on entry to ANY non-`connecting` state — including `authenticating`
    // — so a userauth that stalled AFTER host-key accept hung forever (#563).
    //
    // `awaitingHostKey` is HUMAN-paced — the user may deliberate at the Trust
    // dialog indefinitely — so it must NEVER time out. Terminal/steady states
    // (`connected`, `failed`, `disconnected`, `softDisconnected`,
    // `reconnecting`, `idle`) also cancel.
    //
    // Rules:
    //   - entering `connecting` or `authenticating`: (re-)arm the timer.
    //     `_armReadyTimer()` cancels any existing timer first, so arming is
    //     idempotent (connect() still calls it explicitly after the connecting
    //     emit; harmless).
    //   - any other state: cancel.
    final armPhase =
        next.state == SshSessionState.connecting ||
        next.state == SshSessionState.authenticating;
    if (armPhase) {
      _armReadyTimer();
    } else if (_readyTimer != null) {
      ctrace('task.ssh', 'readyTimer: cancelled (state→${next.state.name})');
      _readyTimer!.cancel();
      _readyTimer = null;
    }
    // Stamp when the session enters a terminal involuntary state (`failed`) or
    // any `disconnected` so the resume re-arm (#813) can tell a STALE dropped
    // session from a just-now drop. Cleared on every other transition so a
    // session that reconnects doesn't carry an old timestamp.
    if (next.state == SshSessionState.failed ||
        next.state == SshSessionState.disconnected) {
      _terminalSinceMs ??= DateTime.now().millisecondsSinceEpoch;
    } else {
      _terminalSinceMs = null;
    }
    _data = next;
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(next);
    }
  }

  /// Arm the machine-paced phase deadline. If the session is STILL `connecting`
  /// (handshake never completed, #542) OR `authenticating` (userauth stalled
  /// after host-key accept, #563) when it fires, force-close the client +
  /// socket and surface `failed`. `awaitingHostKey` cancels this timer (see
  /// `_emit`), so the human-paced host-key prompt is never timed out.
  void _armReadyTimer() {
    _readyTimer?.cancel();
    final secs = readyTimeout.inMilliseconds / 1000;
    ctrace('task.ssh', 'readyTimer: armed (${secs}s)');
    _readyTimer = Timer(readyTimeout, () {
      _readyTimer = null;
      if (_data.state != SshSessionState.connecting &&
          _data.state != SshSessionState.authenticating) {
        return;
      }
      ctrace(
        'task.ssh',
        'readyTimer: FIRED while still ${_data.state.name} → force-fail',
      );
      _forceCloseTransport();
      _emit(
        _data.copyWith(
          state: SshSessionState.failed,
          error:
              'No SSH response in ${secs.round()}s — host may be '
              'unreachable or asleep',
        ),
      );
    });
  }

  void _forceCloseTransport() {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {
        /* ignore */
      }
    }
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.destroy();
      } catch (_) {
        /* ignore */
      }
    }
  }

  Future<bool> _onVerifyHostKey(
    SshConnectParams params,
    String type,
    Uint8List fingerprint,
  ) async {
    final hex = _fingerprintHex(fingerprint);
    // Persisted trust is hydrated in connect() (before the SSHClient is built),
    // so by the time dartssh2 invokes this callback the in-memory map already
    // reflects previously-accepted fingerprints (#565). This method stays
    // synchronous in its emit timing — it must reach `awaitingHostKey` in the
    // same turn so the connecting-phase timer is cancelled (#542).
    if (_hostKeyStore.isTrusted(params.host, params.port, hex)) {
      _emit(_data.copyWith(state: SshSessionState.authenticating));
      return true;
    }

    final completer = Completer<bool>();
    _hostKeyCompleter = completer;
    _emit(
      _data.copyWith(
        state: SshSessionState.awaitingHostKey,
        pendingHostKey: PendingHostKey(
          host: params.host,
          port: params.port,
          keyType: type,
          fingerprint: hex,
        ),
      ),
    );
    return completer.future;
  }

  FutureOr<String?> _onPasswordRequest(SshConnectParams params) {
    final auth = params.auth;
    if (auth is SshAuthPassword) return auth.password;
    return null;
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
