// Native-side vault decryptor (#510).
//
// Mirrors the PWA's `src/modules/vault.ts` crypto contract for the purpose of
// importing a backup-envelope export. Native does NOT re-implement the full
// vault lifecycle (create/rotate/biometric-enroll) — once decrypted, secrets
// are persisted via `flutter_secure_storage` and the platform vault takes
// over.
//
// Crypto contract (must match PWA exactly):
//   - PBKDF2-HMAC-SHA256, 600_000 iterations, 256-bit key.
//   - 32-byte random salt; base64 encoded in `meta.salt`.
//   - AES-GCM-256 with 12-byte IV everywhere (DEK wrap + per-entry encrypt).
//   - WebCrypto encodes the AES-GCM tag as the LAST 16 bytes of the ciphertext.
//
// Envelope shape (`vault` field of a backup-export):
//   {
//     "encrypted": "<json string of { vaultId: {iv, ct} }>",
//     "meta":      "<json string of { salt, dekPw, dekBio? }>",
//   }
//
// `dekBio` (biometric DEK wrap) is silently ignored — it is bound to the
// source device's WebAuthn credential and cannot be unwrapped here. This
// mirrors the PWA's behavior in `profiles.ts:1144-1156`.
//
// Throws [VaultDecryptException] on wrong password (AES-GCM auth-tag
// mismatch). Throws [VaultEnvelopeException] on malformed envelope/meta.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Iteration count for PBKDF2-HMAC-SHA256. MUST match
/// `PBKDF2_ITERATIONS` in `src/modules/vault.ts`. Reducing this breaks
/// decryption of envelopes produced by the PWA.
const int kVaultPbkdf2Iterations = 600000;

/// Key length in bytes (32 = 256 bits, for AES-256-GCM).
const int kVaultKeyLengthBytes = 32;

/// AES-GCM IV length in bytes (12 = 96 bits, WebCrypto standard).
const int kAesGcmIvLengthBytes = 12;

/// AES-GCM auth tag length in bytes (16 = 128 bits, WebCrypto default).
const int kAesGcmTagLengthBytes = 16;

/// Raised when AES-GCM authentication fails — typically a wrong password
/// (KEK doesn't unwrap the DEK) but also covers tampered ciphertext.
class VaultDecryptException implements Exception {
  VaultDecryptException(this.message);
  final String message;
  @override
  String toString() => 'VaultDecryptException: $message';
}

/// Raised when the envelope's `meta` or `encrypted` strings cannot be parsed,
/// or when required fields are missing. Distinguishes user-correctable
/// envelope errors (paste-wrong-file) from password errors.
class VaultEnvelopeException implements Exception {
  VaultEnvelopeException(this.message);
  final String message;
  @override
  String toString() => 'VaultEnvelopeException: $message';
}

/// One AES-GCM-wrapped value: `iv` (12 bytes) + `ct` (ciphertext with the
/// 16-byte tag appended, per WebCrypto convention). Both base64-encoded in
/// the envelope.
class WrappedBlob {
  WrappedBlob({required this.iv, required this.ct});
  final Uint8List iv;
  final Uint8List ct;

  factory WrappedBlob.fromJson(Object? raw, {required String field}) {
    if (raw is! Map) {
      throw VaultEnvelopeException(
        'meta.$field is not an object (got ${raw.runtimeType})',
      );
    }
    final ivB64 = raw['iv'];
    final ctB64 = raw['ct'];
    if (ivB64 is! String || ctB64 is! String) {
      throw VaultEnvelopeException(
        'meta.$field is missing iv/ct fields',
      );
    }
    try {
      final iv = base64Decode(ivB64);
      final ct = base64Decode(ctB64);
      if (iv.length != kAesGcmIvLengthBytes) {
        throw VaultEnvelopeException(
          'meta.$field.iv has wrong length: ${iv.length} (expected '
          '$kAesGcmIvLengthBytes)',
        );
      }
      if (ct.length < kAesGcmTagLengthBytes) {
        throw VaultEnvelopeException(
          'meta.$field.ct is too short to contain a GCM tag '
          '(${ct.length} < $kAesGcmTagLengthBytes)',
        );
      }
      return WrappedBlob(iv: iv, ct: ct);
    } on FormatException catch (e) {
      throw VaultEnvelopeException(
        'meta.$field has invalid base64: ${e.message}',
      );
    }
  }
}

/// Parsed envelope metadata. `salt`, `dekPw` are required; `dekBio` is
/// stripped on import.
class VaultEnvelopeMeta {
  VaultEnvelopeMeta({
    required this.salt,
    required this.dekPw,
  });

  final Uint8List salt;
  final WrappedBlob dekPw;

  /// Parse `vault.meta` (which is itself a JSON-stringified object) into a
  /// [VaultEnvelopeMeta]. Strips `dekBio` per the PWA contract.
  factory VaultEnvelopeMeta.parse(String metaJson) {
    final Object? parsed;
    try {
      parsed = jsonDecode(metaJson);
    } on FormatException catch (e) {
      throw VaultEnvelopeException('vault.meta is not valid JSON: ${e.message}');
    }
    if (parsed is! Map) {
      throw VaultEnvelopeException(
        'vault.meta is not a JSON object (got ${parsed.runtimeType})',
      );
    }
    final saltB64 = parsed['salt'];
    if (saltB64 is! String || saltB64.isEmpty) {
      throw VaultEnvelopeException('vault.meta missing salt');
    }
    final Uint8List salt;
    try {
      salt = base64Decode(saltB64);
    } on FormatException catch (e) {
      throw VaultEnvelopeException('vault.meta salt is not valid base64: ${e.message}');
    }
    final dekPw = WrappedBlob.fromJson(parsed['dekPw'], field: 'dekPw');
    // dekBio is intentionally NOT read — biometric wraps are device-specific
    // and won't decrypt on another device. See PWA's profiles.ts:1144-1156.
    return VaultEnvelopeMeta(salt: salt, dekPw: dekPw);
  }
}

/// The decrypted contents of a vault envelope: `vaultId -> secret JSON map`.
typedef DecryptedVault = Map<String, Map<String, Object?>>;

/// Stateless decryptor. Construct once; call [decryptEnvelope] per import.
///
/// The constructor takes optional overrides for the underlying cryptography
/// primitives so tests can inject a faster `_TestPbkdf2` if 600k iterations
/// is too slow to run in CI (it is not — PBKDF2 in Dart at 600k is sub-second
/// on modern hardware, but the override keeps the door open).
class VaultDecryptor {
  VaultDecryptor({
    Pbkdf2? pbkdf2,
    AesGcm? aesGcm,
  })  : _pbkdf2 = pbkdf2 ?? _defaultPbkdf2(),
        _aesGcm = aesGcm ?? AesGcm.with256bits();

  final Pbkdf2 _pbkdf2;
  final AesGcm _aesGcm;

  static Pbkdf2 _defaultPbkdf2() => Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: kVaultPbkdf2Iterations,
        bits: kVaultKeyLengthBytes * 8,
      );

  /// Derive the KEK (key-encryption key) from a master password + salt using
  /// PBKDF2-HMAC-SHA256. Internal — exposed via [decryptEnvelope].
  Future<SecretKey> deriveKek(String password, Uint8List salt) async {
    return _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  /// Unwrap the DEK using the KEK. Throws [VaultDecryptException] on
  /// auth-tag mismatch (wrong password).
  Future<SecretKey> _unwrapDek(SecretKey kek, WrappedBlob dekPw) async {
    return SecretKey(await _aesGcmDecrypt(kek, dekPw));
  }

  /// AES-GCM decrypt with the WebCrypto layout: `ct[:-16] || tag[16]`. The
  /// `cryptography` package splits these into [SecretBox.cipherText] and
  /// [SecretBox.mac].
  Future<Uint8List> _aesGcmDecrypt(SecretKey key, WrappedBlob blob) async {
    final ctLen = blob.ct.length;
    final cipherText = Uint8List.sublistView(blob.ct, 0, ctLen - kAesGcmTagLengthBytes);
    final macBytes = Uint8List.sublistView(blob.ct, ctLen - kAesGcmTagLengthBytes);
    final secretBox = SecretBox(
      cipherText,
      nonce: blob.iv,
      mac: Mac(macBytes),
    );
    try {
      final plain = await _aesGcm.decrypt(secretBox, secretKey: key);
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError catch (_) {
      throw VaultDecryptException(
        'Decryption failed — wrong password or tampered data.',
      );
    }
  }

  /// Decrypt every entry in a backup envelope.
  ///
  /// Returns a map from `vaultId` to the decoded secret JSON object.
  ///
  /// Throws [VaultEnvelopeException] when the envelope is malformed
  /// (user pasted the wrong file). Throws [VaultDecryptException] when
  /// the master password fails to unwrap the DEK or any entry fails
  /// AES-GCM authentication.
  Future<DecryptedVault> decryptEnvelope({
    required String encryptedJson,
    required String metaJson,
    required String password,
  }) async {
    final meta = VaultEnvelopeMeta.parse(metaJson);

    // Parse the encrypted-entries map.
    final Object? entriesRaw;
    try {
      entriesRaw = jsonDecode(encryptedJson);
    } on FormatException catch (e) {
      throw VaultEnvelopeException(
        'vault.encrypted is not valid JSON: ${e.message}',
      );
    }
    if (entriesRaw is! Map) {
      throw VaultEnvelopeException(
        'vault.encrypted is not a JSON object (got ${entriesRaw.runtimeType})',
      );
    }

    // Derive KEK, unwrap DEK.
    final kek = await deriveKek(password, meta.salt);
    final dek = await _unwrapDek(kek, meta.dekPw);

    // Decrypt each per-vaultId entry.
    final out = <String, Map<String, Object?>>{};
    for (final entry in entriesRaw.entries) {
      final vaultId = entry.key;
      if (vaultId is! String || vaultId.isEmpty) continue;
      final WrappedBlob blob;
      try {
        blob = WrappedBlob.fromJson(entry.value, field: 'encrypted[$vaultId]');
      } on VaultEnvelopeException {
        // Skip malformed individual entries — the password might still be
        // correct, and partial recovery is better than total failure.
        continue;
      }
      final plain = await _aesGcmDecrypt(dek, blob);
      final Object? secret;
      try {
        secret = jsonDecode(utf8.decode(plain));
      } on FormatException catch (_) {
        // Skip — same logic as above.
        continue;
      }
      if (secret is Map) {
        out[vaultId] = Map<String, Object?>.from(secret);
      }
    }

    return out;
  }
}
