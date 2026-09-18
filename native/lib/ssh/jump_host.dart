// Jump host (ProxyJump) — chain resolution, transport composition and per-hop
// auth (#1183, spec docs/jump-host.md slice 1, R1-R13).
//
// A jump connection is NOT a second session (D3): it is an [SshSocketOpener]
// that dials the bastion(s) first and hands the target session the forwarded
// `direct-tcpip` channel. dartssh2's `SSHForwardChannel implements SSHSocket`,
// so the session state machine, reconnect policy, keepalive and SFTP paths
// need no change at all.
//
// This file is where `SavedProfile`, `SshSocketOpener`, `SshConnectParams` and
// `ProfileCredentials` meet — `storage/` deliberately imports no ssh types, so
// the hop-auth resolution lives here rather than in the store.
//
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../storage/profiles_store.dart';
import '../storage/secrets_store.dart';
import 'ssh_connect_params.dart';
import 'ssh_session.dart';

/// Maximum number of intermediate hops between the device and the target
/// (R3). A deeper chain fails closed rather than silently truncating.
const int kMaxJumpHops = 3;

/// Why a chain could not be resolved (R3, R4).
enum JumpChainErrorReason {
  /// More than [kMaxJumpHops] hops between the device and the target.
  tooDeep,

  /// A profile is reachable from itself through `jumpIdentityKey`.
  cycle,
}

/// Fail-closed chain-resolution error. Silently truncating a too-deep chain or
/// looping forever on a cycle would both connect through the WRONG path, so
/// both throw.
class JumpChainError implements Exception {
  const JumpChainError({
    required this.reason,
    required this.identityKey,
    required this.message,
  });

  final JumpChainErrorReason reason;

  /// The offending profile's `identityKey` — the cycle member, or the target
  /// whose chain ran too deep.
  final String identityKey;

  final String message;

  @override
  String toString() => 'JumpChainError(${reason.name}): $message';
}

/// Resolve [target]'s jump chain from [all], OUTERMOST-FIRST (index 0 is the
/// hop dialled first, R7). The target itself is never in the result.
///
/// A DANGLING reference (no profile matches) is "no jump host" (R1: absent /
/// unknown / corrupt → none) — a hop the user deleted must not brick the
/// connect path. A cycle (R4) or a chain deeper than [kMaxJumpHops] (R3)
/// throws [JumpChainError]; the cycle diagnosis wins because it is the more
/// specific and more actionable of the two.
List<SavedProfile> resolveJumpChain(
  SavedProfile target,
  List<SavedProfile> all,
) {
  final byIdentity = <String, SavedProfile>{};
  for (final p in all) {
    byIdentity.putIfAbsent(p.identityKey, () => p);
  }

  // Innermost-first while walking; reversed on return.
  final walked = <SavedProfile>[];
  final visited = <String>{target.identityKey};
  var current = target;

  while (true) {
    final ref = current.jumpIdentityKey;
    if (ref == null || ref.isEmpty) break;
    if (visited.contains(ref)) {
      throw JumpChainError(
        reason: JumpChainErrorReason.cycle,
        identityKey: ref,
        message:
            'jump host cycle: $ref is reached from itself via '
            '${target.identityKey}',
      );
    }
    final next = byIdentity[ref];
    // Dangling: the referenced profile is gone. The reachable part stands.
    if (next == null) break;
    visited.add(ref);
    walked.add(next);
    if (walked.length > kMaxJumpHops) {
      throw JumpChainError(
        reason: JumpChainErrorReason.tooDeep,
        identityKey: target.identityKey,
        message:
            'jump chain for ${target.host} is longer than the maximum of '
            '$kMaxJumpHops hops',
      );
    }
    current = next;
  }

  return walked.reversed.toList(growable: false);
}

/// The profiles [target] may legally use as its jump host (R15): every OTHER
/// profile from which [target] is NOT already reachable. Offering a
/// cycle-closer would let the user save a chain that R4 rejects, so the editor
/// simply never lists one.
List<SavedProfile> jumpHostCandidates(
  SavedProfile target,
  List<SavedProfile> all,
) {
  final byIdentity = <String, SavedProfile>{};
  for (final p in all) {
    byIdentity.putIfAbsent(p.identityKey, () => p);
  }
  final targetKey = target.identityKey;

  bool reachesTarget(SavedProfile from) {
    final seen = <String>{from.identityKey};
    var current = from;
    while (true) {
      final ref = current.jumpIdentityKey;
      if (ref == null || ref.isEmpty) return false;
      if (ref == targetKey) return true;
      if (!seen.add(ref)) return false; // pre-existing cycle: not our problem
      final next = byIdentity[ref];
      if (next == null) return false;
      current = next;
    }
  }

  return <SavedProfile>[
    for (final p in all)
      if (p.identityKey != targetKey && !reachesTarget(p)) p,
  ];
}

/// A hop failed. The message NAMES the hop (R11) so the failure never reads as
/// if the TARGET refused the connection.
class JumpHopError implements Exception {
  const JumpHopError(this.hopLabel, this.message);

  /// `host:port` of the hop that failed.
  final String hopLabel;

  final String message;

  @override
  String toString() => '$hopLabel: $message';
}

/// One authenticated hop. The seam that keeps the unit tests off real sockets:
/// production implements it with a nested [SSHClient]
/// ([sshJumpHopConnector]), tests with a recording fake.
abstract class JumpHopConnection {
  /// Open a `direct-tcpip` channel from this hop to `host:port`. The returned
  /// socket is the transport for the NEXT leg (another hop, or the target).
  Future<SSHSocket> forwardLocal(String host, int port);

  /// Tear this hop down.
  Future<void> close();
}

/// Authenticates one hop over an already-open [SSHSocket].
typedef JumpHopConnector =
    Future<JumpHopConnection> Function(
      SavedProfile hop,
      SSHSocket socket, {
      Duration? timeout,
    });

/// The live jump chain behind one session's transport (R12).
///
/// [opener] is an [SshSocketOpener]: it dials the hops outermost-first and
/// returns the forwarded channel for the final leg. The chain OWNS the hop
/// clients and follows the returned socket down — when the session closes its
/// transport (which is what `SshSessionController.disconnect` does via
/// `client.close()`), every hop closes with it. A reconnect calls [opener]
/// again and re-dials the WHOLE chain (R13).
class JumpChain {
  JumpChain({
    required this.hops,
    required SshSocketOpener base,
    required JumpHopConnector connector,
  }) : _base = base,
       _connector = connector;

  /// The hops, OUTERMOST-FIRST (as [resolveJumpChain] returns them).
  final List<SavedProfile> hops;

  final SshSocketOpener _base;
  final JumpHopConnector _connector;

  final List<JumpHopConnection> _live = <JumpHopConnection>[];

  /// The hop clients currently held open. Empty before the first dial, after
  /// [close], and after a failed dial — a half-open chain leaks nothing (R12).
  List<JumpHopConnection> get liveHops => List.unmodifiable(_live);

  /// The [SshSocketOpener] for the target session's transport.
  Future<SSHSocket> opener(String host, int port, {Duration? timeout}) async {
    if (hops.isEmpty) {
      return _base(host, port, timeout: timeout);
    }
    // A re-dial that skipped close() (a reconnect racing a teardown) must not
    // stack chains — R12 is asserted over a 10-reconnect storm.
    if (_live.isNotEmpty) await close();

    final outer = hops.first;
    SSHSocket socket;
    try {
      socket = await _base(outer.host, outer.port, timeout: timeout);
    } catch (e) {
      throw JumpHopError(_label(outer), '$e');
    }
    final baseSocket = socket;

    try {
      for (var i = 0; i < hops.length; i++) {
        final hop = hops[i];
        final JumpHopConnection conn;
        try {
          conn = await _connector(hop, socket, timeout: timeout);
        } catch (e) {
          throw JumpHopError(_label(hop), '$e');
        }
        _live.add(conn);
        // The next leg is the following hop, or the target for the last one.
        final nextHost = i + 1 < hops.length ? hops[i + 1].host : host;
        final nextPort = i + 1 < hops.length ? hops[i + 1].port : port;
        try {
          socket = await conn.forwardLocal(nextHost, nextPort);
        } catch (e) {
          throw JumpHopError(_label(hop), '$e');
        }
      }
    } catch (_) {
      // Half-open: close every hop we did open before surfacing the error, so
      // nothing is left holding the bastion (R13). When the FIRST connector
      // failed, no hop client ever took ownership of the TCP socket we dialled
      // — destroy it here or it stays open for the life of the app.
      final orphanedBaseSocket = _live.isEmpty;
      await close();
      if (orphanedBaseSocket) {
        try {
          baseSocket.destroy();
        } catch (_) {
          /* already gone */
        }
      }
      rethrow;
    }

    // R12 ownership: the socket the session gets OWNS the hops behind it.
    unawaited(socket.done.then((_) => close()).catchError((Object _) {}));
    return socket;
  }

  /// Tear down every live hop. Safe to call repeatedly.
  Future<void> close() async {
    final live = List<JumpHopConnection>.from(_live);
    _live.clear();
    // Innermost-first: the inner hops ride the outer ones' channels.
    for (final conn in live.reversed) {
      try {
        await conn.close();
      } catch (_) {
        /* a hop that is already gone is still closed */
      }
    }
  }

  static String _label(SavedProfile hop) => '${hop.host}:${hop.port}';
}

/// A plain [SshSocketOpener] for [hops]. Callers that need the chain handle
/// (teardown, leak accounting) construct a [JumpChain] directly.
SshSocketOpener jumpSocketOpener({
  required List<SavedProfile> hops,
  required SshSocketOpener base,
  required JumpHopConnector connector,
}) {
  final chain = JumpChain(hops: hops, base: base, connector: connector);
  return chain.opener;
}

/// The hop's connect params — the HOP's identity, never the target's. Drives
/// the per-hop host-key lookup (R9: keyed by the hop's own `host:port`) and
/// the prompt's name (R10).
SshConnectParams jumpHopParams(SavedProfile hop, SshAuth auth) =>
    SshConnectParams(
      host: hop.host,
      port: hop.port,
      username: hop.username,
      auth: auth,
    );

/// Resolve the hop's OWN stored credentials into an [SshAuth] (R8).
///
/// Fails CLOSED with a named [JumpHopError] when the hop's secret is missing:
/// no credential is ever reused across hops, and a key-auth hop never falls
/// back to some other secret it happens to have.
SshAuth resolveJumpHopAuth(SavedProfile hop, ProfileCredentials creds) {
  final label = '${hop.host}:${hop.port}';
  final wantsKey =
      hop.authType == 'key' ||
      (hop.authType == null &&
          (creds.privateKey != null ||
              (hop.keyVaultId != null && hop.keyVaultId!.isNotEmpty)));

  if (wantsKey) {
    final pem = creds.privateKey;
    if (pem == null || pem.isEmpty) {
      throw JumpHopError(
        label,
        'no stored private key for this jump host — open its profile and '
        'add one',
      );
    }
    final passphrase = creds.passphrase;
    return SshAuth.key(
      Uint8List.fromList(utf8.encode(pem)),
      passphrase: (passphrase == null || passphrase.isEmpty)
          ? null
          : passphrase,
    );
  }

  final password = creds.password;
  if (password == null || password.isEmpty) {
    throw JumpHopError(
      label,
      'no stored password for this jump host — open its profile and add one',
    );
  }
  return SshAuth.password(password);
}

/// Resolve [profile]'s chain into per-hop connect params, OUTERMOST-FIRST —
/// the single place every connect path builds a chain (#1183, R7/R8).
///
/// Resolution happens UI-side for the same reason the target's auth does: the
/// task isolate has no vault. Throws [JumpChainError] (cycle / too deep) or
/// [JumpHopError] (missing hop secret) — both fail the connect CLOSED, named,
/// because silently connecting DIRECT would route the session the wrong way.
Future<List<SshConnectParams>> resolveJumpHopParams({
  required SavedProfile profile,
  required List<SavedProfile> all,
  required SecretsStore secrets,
}) async {
  if (profile.jumpIdentityKey == null) return const [];
  final hops = resolveJumpChain(profile, all);
  final out = <SshConnectParams>[];
  for (final hop in hops) {
    final creds = await loadProfileCredentials(secrets, hop);
    out.add(jumpHopParams(hop, resolveJumpHopAuth(hop, creds)));
  }
  return out;
}

/// Verifies one hop's host key. Wired to
/// [SshSessionController.verifyHopHostKey] in production so a hop's prompt
/// surfaces in the TARGET session's UI (D3).
typedef JumpHopVerifier =
    Future<bool> Function(
      SshConnectParams hop,
      String type,
      Uint8List fingerprint,
    );

/// THE production connector — the only place a nested [SSHClient] is built.
///
/// [authFor] hands back the hop's own resolved credentials (see
/// [resolveJumpHopAuth]); [verify] runs the hop's key through the SAME
/// [HostKeyStore] and prompt as a target (R9/R10).
JumpHopConnector sshJumpHopConnector({
  required SshAuth Function(SavedProfile hop) authFor,
  required JumpHopVerifier verify,
  Duration keepAliveInterval = const Duration(seconds: 15),
}) {
  return (SavedProfile hop, SSHSocket socket, {Duration? timeout}) async {
    final auth = authFor(hop);
    final params = jumpHopParams(hop, auth);

    List<SSHKeyPair>? identities;
    if (auth is SshAuthKey) {
      try {
        identities = SSHKeyPair.fromPem(
          String.fromCharCodes(auth.pem),
          auth.passphrase,
        );
      } catch (e) {
        throw JumpHopError(
          '${hop.host}:${hop.port}',
          'could not load the stored private key ($e)',
        );
      }
    }

    final client = SSHClient(
      socket,
      username: hop.username,
      keepAliveInterval: keepAliveInterval,
      identities: identities,
      onVerifyHostKey: (type, fingerprint) => verify(params, type, fingerprint),
      onPasswordRequest: () => auth is SshAuthPassword ? auth.password : null,
    );

    try {
      final authed = timeout == null
          ? client.authenticated
          : client.authenticated.timeout(timeout);
      await authed;
    } catch (e) {
      try {
        client.close();
      } catch (_) {
        /* ignore */
      }
      throw JumpHopError('${hop.host}:${hop.port}', '$e');
    }
    return _SshClientJumpHop(client);
  };
}

class _SshClientJumpHop implements JumpHopConnection {
  _SshClientJumpHop(this._client);

  final SSHClient _client;

  @override
  Future<SSHSocket> forwardLocal(String host, int port) =>
      _client.forwardLocal(host, port);

  @override
  Future<void> close() async {
    try {
      _client.close();
      await _client.done;
    } catch (_) {
      /* a hop already gone is still closed */
    }
  }
}
