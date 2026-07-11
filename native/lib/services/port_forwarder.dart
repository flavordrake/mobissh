// SSH LOCAL port-forward engine (ssh -L semantics, #1047).
//
// Task-isolate-side: forwards live beside the SSH client (the dart:io
// ServerSocket must be owned where the `SSHClient` is — the foreground task
// isolate, which the #1018/#1021 keepalive hold keeps alive). Each accepted
// local connection opens a `direct-tcpip` channel to the remote target and
// pipes bidirectionally until either side closes.
//
// The tunnel type is dartssh2's [SSHSocket] — exactly the interface
// `SSHClient.forwardLocal` returns (`SSHForwardChannel implements SSHSocket`),
// so production injects `client.forwardLocal` and tests inject an in-memory
// fake without touching a real socket.
//
// SECURITY (.claude/rules/security.md): listeners bind 127.0.0.1 ONLY — the
// forward is for THIS device (in-app + sibling apps via the shared loopback),
// never an open relay on the LAN. No remote→local (-R) in v1.

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;

/// Opens the remote leg of one forwarded connection — production wraps
/// `SSHClient.forwardLocal(remoteHost, remotePort)`; tests inject a fake.
/// Throwing signals a channel-open refusal for THAT connection only.
typedef ForwardTunnelOpener =
    Future<SSHSocket> Function(String remoteHost, int remotePort);

/// One forward's configuration: listen on 127.0.0.1:[localPort], tunnel each
/// connection to [remoteHost]:[remotePort] as reachable FROM the SSH server.
class PortForwardConfig {
  const PortForwardConfig({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  /// The device-side listen port. 0 asks the OS for an ephemeral port (tests);
  /// user-facing forwards always carry an explicit port.
  final int localPort;
  final String remoteHost;
  final int remotePort;
}

/// A live ssh -L listener: one bound ServerSocket + the set of live pipes.
///
/// Lifecycle: [start] binds (throws [SocketException] on port-in-use — the
/// caller surfaces that as the forward's error status); [close] tears down the
/// listener AND every live pipe in both directions. A per-connection
/// channel-open failure closes that connection only and reports through
/// [onChannelError] — the listener keeps accepting, matching `ssh -L` (which
/// logs "channel open failed" per attempt and stays up).
class PortForwardListener {
  PortForwardListener._(this.config, this._server, this._open, this.onChannelError) {
    _server.listen(_handleAccept, onError: (_) {}, cancelOnError: false);
  }

  final PortForwardConfig config;
  final ServerSocket _server;
  final ForwardTunnelOpener _open;

  /// Invoked with a short description each time a connection's direct-tcpip
  /// channel open is refused (session down, remote refused, prohibited).
  final void Function(String error)? onChannelError;

  final Set<Socket> _liveSockets = {};
  final Set<SSHSocket> _liveTunnels = {};
  bool _closed = false;

  /// The actually-bound port (== `config.localPort` unless it was 0).
  int get boundPort => _server.port;

  static Future<PortForwardListener> start({
    required PortForwardConfig config,
    required ForwardTunnelOpener openTunnel,
    void Function(String error)? onChannelError,
  }) async {
    // SECURITY: loopback ONLY (.claude/rules/security.md) — never 0.0.0.0.
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      config.localPort,
    );
    return PortForwardListener._(config, server, openTunnel, onChannelError);
  }

  Future<void> _handleAccept(Socket socket) async {
    if (_closed) {
      socket.destroy();
      return;
    }
    _liveSockets.add(socket);
    final SSHSocket tunnel;
    try {
      tunnel = await _open(config.remoteHost, config.remotePort);
    } catch (e) {
      // Channel refused for THIS connection: close it, keep listening.
      onChannelError?.call(
        'channel to ${config.remoteHost}:${config.remotePort} failed: $e',
      );
      _liveSockets.remove(socket);
      socket.destroy();
      return;
    }
    if (_closed) {
      // close() raced the channel open — tear the fresh tunnel down too.
      _liveSockets.remove(socket);
      socket.destroy();
      tunnel.destroy();
      return;
    }
    _liveTunnels.add(tunnel);

    // remote → local: when the tunnel's read side ends (remote closed), flush
    // what we have and drop the local socket.
    unawaited(() async {
      try {
        await socket.addStream(tunnel.stream);
        await socket.flush();
      } catch (_) {
        // Local socket gone mid-write — the other direction's teardown runs.
      } finally {
        _liveSockets.remove(socket);
        socket.destroy();
      }
    }());

    // local → remote: when the local socket's read side ends (app closed),
    // close our end of the channel so the remote sees EOF.
    unawaited(() async {
      try {
        await tunnel.sink.addStream(socket);
      } catch (_) {
        // Tunnel gone mid-write — the other direction's teardown runs.
      } finally {
        _liveTunnels.remove(tunnel);
        try {
          await tunnel.close();
        } catch (_) {
          /* already closed */
        }
      }
    }());
  }

  /// Stop accepting AND tear down every live pipe (both directions). Safe to
  /// call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final s in _liveSockets.toList()) {
      s.destroy();
    }
    _liveSockets.clear();
    for (final t in _liveTunnels.toList()) {
      t.destroy();
    }
    _liveTunnels.clear();
  }
}
