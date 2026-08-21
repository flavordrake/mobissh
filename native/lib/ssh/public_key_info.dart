// Public-key derivation for library keys (#1122). Parses a private key PEM
// (dartssh2) and derives the NON-secret identification triple stored in key
// metadata: the OpenSSH public line, the `SHA256:` fingerprint, and a short
// algorithm name. After a phone migration only this metadata survives, so it
// is what lets the user match a library entry against ~/.ssh/authorized_keys.
//
// SECURITY: best-effort ONLY — any parse failure (garbage, unsupported format,
// missing/wrong passphrase) returns null so the caller's import/restore is
// never blocked, and neither the PEM nor the passphrase is ever logged.

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:dartssh2/dartssh2.dart';

/// The derived, NON-secret identity of a private key.
class PublicKeyInfo {
  const PublicKeyInfo({
    required this.algorithm,
    required this.publicKeyLine,
    required this.fingerprint,
  });

  /// Short algorithm name for the row subtitle, e.g. `ed25519`, `rsa`.
  final String algorithm;

  /// The full `ssh-ed25519 AAAA…` OpenSSH public line (no comment).
  final String publicKeyLine;

  /// `SHA256:` + unpadded base64 of SHA-256 over the public-key wire blob —
  /// the standard OpenSSH fingerprint (`ssh-keygen -lf`).
  final String fingerprint;
}

/// Derive [PublicKeyInfo] from a private key [pem] (+ optional [passphrase]),
/// or null when the key cannot be parsed. Never throws.
PublicKeyInfo? derivePublicKeyInfo(String pem, {String? passphrase}) {
  try {
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) return null;
    // The wire blob is the SSH encoding (string algo-name + algo fields) —
    // exactly what the OpenSSH line base64s and the fingerprint hashes over.
    final blob = pairs.first.toPublicKey().encode();
    final type = _wireType(blob);
    if (type == null) return null;
    final digest = const DartSha256().hashSync(blob).bytes;
    return PublicKeyInfo(
      algorithm: _shortAlgorithm(type),
      publicKeyLine: '$type ${base64.encode(blob)}',
      // OpenSSH prints the digest base64 WITHOUT trailing '=' padding.
      fingerprint: 'SHA256:${base64.encode(digest).replaceAll('=', '')}',
    );
  } catch (_) {
    // Deliberately swallowed: derivation is opportunistic; the import/restore
    // proceeds with name-only metadata. Never log the PEM or passphrase.
    return null;
  }
}

/// Read the leading algo-name string of an SSH wire blob (uint32 length +
/// ASCII bytes), or null if malformed.
String? _wireType(List<int> blob) {
  if (blob.length < 4) return null;
  final len = (blob[0] << 24) | (blob[1] << 16) | (blob[2] << 8) | blob[3];
  if (len <= 0 || len > 64 || blob.length < 4 + len) return null;
  return ascii.decode(blob.sublist(4, 4 + len), allowInvalid: false);
}

/// Map a wire algo name to the short display form used in the keys screen.
String _shortAlgorithm(String type) {
  if (type == 'ssh-ed25519') return 'ed25519';
  if (type == 'ssh-rsa' || type.startsWith('rsa-sha2-')) return 'rsa';
  if (type.startsWith('ecdsa-')) return 'ecdsa';
  return type;
}
