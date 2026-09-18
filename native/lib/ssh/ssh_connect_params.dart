// SSH connection parameters and authentication sum type.
//
// Phase 1 (#501): pure data classes used by SshSessionController. No
// persistence yet — Phase 3 will wire profiles + flutter_secure_storage.

import 'dart:typed_data';

/// Authentication strategy for an SSH connection.
///
/// `SshAuth.password` — password authentication.
/// `SshAuth.key` — public key authentication (PEM-encoded private key, with
/// optional passphrase if the key is encrypted).
sealed class SshAuth {
  const SshAuth();

  const factory SshAuth.password(String password) = SshAuthPassword;

  const factory SshAuth.key(Uint8List pem, {String? passphrase}) = SshAuthKey;
}

class SshAuthPassword extends SshAuth {
  final String password;
  const SshAuthPassword(this.password);
}

class SshAuthKey extends SshAuth {
  final Uint8List pem;
  final String? passphrase;
  const SshAuthKey(this.pem, {this.passphrase});
}

/// Immutable parameters describing a single connect attempt.
class SshConnectParams {
  final String host;
  final int port;
  final String username;
  final SshAuth auth;

  /// Jump hops to dial before the target, OUTERMOST-FIRST (#1183, R7). Each
  /// carries its OWN identity and its OWN resolved credentials (R8) — a hop is
  /// transport, not a session, so it never gets its own [SshConnectParams]
  /// entry anywhere else. Empty (the default) = today's direct dial.
  final List<SshConnectParams> jumpHops;

  const SshConnectParams({
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    this.jumpHops = const [],
  });

  /// Stable identifier for host-key lookups.
  String get hostKey => '$host:$port';
}
