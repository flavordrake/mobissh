// Encrypted full-backup envelope (v2) — codex-reviewed design.
//
// One file, everything inside one ciphertext: unlike the v1 PWA envelope
// (plaintext profiles + encrypted vault), nothing leaks — no hostnames, key
// names, or timestamps outside the ciphertext. Layout:
//
//   { "format": "mobissh-backup", "version": 2,
//     "kdf":    {"algo":"argon2id","mKiB":N,"t":N,"p":1,"salt":"<b64 16B>"},
//     "cipher": {"algo":"aes-256-gcm","iv":"<b64 12B>"},
//     "ciphertext": "<b64 ct||16B tag>" }
//
// Security properties (each pinned by test/storage/backup_test.dart):
// - Argon2id with params stored IN the envelope but STRICTLY bounded on read
//   ([kBackupStrictBounds]) — a hostile file cannot demand gigabytes of memory
//   or run an attacker-cheap KDF.
// - The canonical header (format|version|kdf|cipher fields) is authenticated
//   as GCM AAD — tampering ANY outer field fails decryption.
// - Wrong passphrase and every tamper case produce ONE generic error
//   ([kBackupGenericError]) so error text can't oracle what went wrong.
// - Passphrase bytes are exact UTF-8: no trimming, no normalization; min 12
//   chars, max 1024 bytes ([validateBackupPassphrase]).
// - createdAt / appVersion belong INSIDE the payload, never in the envelope.
//
// This module is pure crypto + framing; payload composition/merge semantics
// live with the export/import features. KDF work is CPU-heavy — callers on the
// UI thread should wrap encrypt/decrypt in Isolate.run.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Envelope identity.
const String kBackupFormat = 'mobissh-backup';
const int kBackupVersion = 2;

/// The single error message for wrong passphrase / any tampered or undecodable
/// envelope — deliberately not distinguishing which (no error oracle).
const String kBackupGenericError =
    'Wrong passphrase or damaged backup file.';

/// Hard cap on the envelope JSON before ANY parsing/base64/KDF work.
const int kBackupMaxEnvelopeBytes = 16 * 1024 * 1024;

const int _saltLength = 16;
const int _ivLength = 12;
const int _tagLength = 16;
const int _keyLength = 32;

/// Argon2id parameters carried in the envelope. `mKiB` is the Argon2 memory
/// cost in KiB blocks (19456 = the OWASP-minimum 19 MiB profile).
class BackupKdfParams {
  const BackupKdfParams({required this.mKiB, required this.t, required this.p});
  final int mKiB;
  final int t;
  final int p;
}

/// Production defaults: OWASP-minimum Argon2id (m=19 MiB, t=2, p=1).
const BackupKdfParams kBackupDefaultKdf =
    BackupKdfParams(mKiB: 19456, t: 2, p: 1);

/// Acceptable parameter ranges when READING an envelope. Anything outside is
/// rejected before allocation. Tests inject permissive bounds to keep the
/// suite fast; production always uses [kBackupStrictBounds].
class BackupKdfBounds {
  const BackupKdfBounds({
    required this.minMKiB,
    required this.maxMKiB,
    required this.minT,
    required this.maxT,
    required this.maxP,
  });
  final int minMKiB;
  final int maxMKiB;
  final int minT;
  final int maxT;
  final int maxP;

  bool accepts(BackupKdfParams k) =>
      k.mKiB >= minMKiB &&
      k.mKiB <= maxMKiB &&
      k.t >= minT &&
      k.t <= maxT &&
      k.p >= 1 &&
      k.p <= maxP;
}

const BackupKdfBounds kBackupStrictBounds = BackupKdfBounds(
  minMKiB: 19456,
  maxMKiB: 65536,
  minT: 2,
  maxT: 6,
  maxP: 1,
);

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

/// Passphrase policy (codex): >=12 characters, <=1024 UTF-8 bytes, bytes used
/// exactly as typed. Returns a user-facing problem string, or null when valid.
String? validateBackupPassphrase(String passphrase) {
  if (passphrase.length < 12) {
    return 'Use at least 12 characters (a few random words work well).';
  }
  if (utf8.encode(passphrase).length > 1024) {
    return 'Passphrase is too long (max 1024 bytes).';
  }
  return null;
}

/// Canonical header bytes authenticated as GCM AAD. Deterministic field order;
/// recomputed from the PARSED envelope on decrypt, so any header edit breaks
/// the tag even when the KDF output would otherwise match.
Uint8List _headerAad({
  required BackupKdfParams kdf,
  required String saltB64,
  required String ivB64,
}) {
  return Uint8List.fromList(utf8.encode(
    '$kBackupFormat\n$kBackupVersion\nargon2id\n'
    '${kdf.mKiB}\n${kdf.t}\n${kdf.p}\n$saltB64\naes-256-gcm\n$ivB64',
  ));
}

Future<SecretKey> _deriveKey(
  String passphrase,
  Uint8List salt,
  BackupKdfParams kdf,
) {
  final algo = Argon2id(
    memory: kdf.mKiB,
    iterations: kdf.t,
    parallelism: kdf.p,
    hashLength: _keyLength,
  );
  return algo.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
}

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
}

/// Encrypt [payload] into a v2 envelope JSON string. [kdf] is overridable for
/// tests only — production callers use the default.
Future<String> encryptBackupEnvelope({
  required Map<String, Object?> payload,
  required String passphrase,
  BackupKdfParams kdf = kBackupDefaultKdf,
}) async {
  final salt = _randomBytes(_saltLength);
  final iv = _randomBytes(_ivLength);
  final saltB64 = base64Encode(salt);
  final ivB64 = base64Encode(iv);
  final key = await _deriveKey(passphrase, salt, kdf);
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: key,
    nonce: iv,
    aad: _headerAad(kdf: kdf, saltB64: saltB64, ivB64: ivB64),
  );
  final ciphertext = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setAll(0, box.cipherText)
    ..setAll(box.cipherText.length, box.mac.bytes);
  return jsonEncode(<String, Object?>{
    'format': kBackupFormat,
    'version': kBackupVersion,
    'kdf': {
      'algo': 'argon2id',
      'mKiB': kdf.mKiB,
      't': kdf.t,
      'p': kdf.p,
      'salt': saltB64,
    },
    'cipher': {'algo': 'aes-256-gcm', 'iv': ivB64},
    'ciphertext': base64Encode(ciphertext),
  });
}

/// True when [json] structurally looks like a v2 backup envelope (cheap check
/// for import-format routing; full validation happens in decrypt).
bool looksLikeBackupEnvelope(Map<String, dynamic> json) =>
    json['format'] == kBackupFormat && json['version'] == kBackupVersion;

/// Decrypt a v2 envelope. Throws [BackupException] — with
/// [kBackupGenericError] for anything secret-dependent (wrong passphrase,
/// tampered ciphertext or header), and specific-but-safe messages for
/// structural violations (wrong format, out-of-bounds KDF, bad lengths).
Future<Map<String, Object?>> decryptBackupEnvelope({
  required String envelopeJson,
  required String passphrase,
  BackupKdfBounds bounds = kBackupStrictBounds,
}) async {
  if (envelopeJson.length > kBackupMaxEnvelopeBytes) {
    throw BackupException('Backup file is too large.');
  }
  final Map<String, dynamic> outer;
  try {
    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('not an object');
    }
    outer = decoded;
  } on FormatException {
    throw BackupException('Not a MobiSSH backup file.');
  }
  if (!looksLikeBackupEnvelope(outer)) {
    throw BackupException('Not a MobiSSH backup file.');
  }

  final kdfRaw = outer['kdf'];
  final cipherRaw = outer['cipher'];
  final ctB64 = outer['ciphertext'];
  if (kdfRaw is! Map || cipherRaw is! Map || ctB64 is! String) {
    throw BackupException('Not a MobiSSH backup file.');
  }
  if (kdfRaw['algo'] != 'argon2id') {
    throw BackupException('Unsupported backup KDF.');
  }
  if (cipherRaw['algo'] != 'aes-256-gcm') {
    throw BackupException('Unsupported backup cipher.');
  }
  final mKiB = kdfRaw['mKiB'];
  final t = kdfRaw['t'];
  final p = kdfRaw['p'];
  final saltB64 = kdfRaw['salt'];
  final ivB64 = cipherRaw['iv'];
  if (mKiB is! int || t is! int || p is! int || saltB64 is! String ||
      ivB64 is! String) {
    throw BackupException('Not a MobiSSH backup file.');
  }
  final kdf = BackupKdfParams(mKiB: mKiB, t: t, p: p);
  // Bound BEFORE any allocation/derivation — a tiny hostile file must not be
  // able to demand gigabytes of memory or minutes of CPU.
  if (!bounds.accepts(kdf)) {
    throw BackupException('Backup KDF parameters out of accepted range.');
  }

  final Uint8List salt, iv, ciphertext;
  try {
    salt = base64Decode(saltB64);
    iv = base64Decode(ivB64);
    ciphertext = base64Decode(ctB64);
  } on FormatException {
    throw BackupException(kBackupGenericError);
  }
  if (salt.length != _saltLength ||
      iv.length != _ivLength ||
      ciphertext.length <= _tagLength) {
    throw BackupException(kBackupGenericError);
  }

  final key = await _deriveKey(passphrase, salt, kdf);
  final ct = Uint8List.sublistView(ciphertext, 0, ciphertext.length - _tagLength);
  final tag = Uint8List.sublistView(ciphertext, ciphertext.length - _tagLength);
  final List<int> plain;
  try {
    plain = await AesGcm.with256bits().decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(tag)),
      secretKey: key,
      aad: _headerAad(kdf: kdf, saltB64: saltB64, ivB64: ivB64),
    );
  } on SecretBoxAuthenticationError {
    throw BackupException(kBackupGenericError);
  }

  try {
    final payload = jsonDecode(utf8.decode(plain));
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('not an object');
    }
    return payload;
  } on FormatException {
    throw BackupException(kBackupGenericError);
  }
}
