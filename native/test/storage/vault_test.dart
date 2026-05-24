// Unit tests for [VaultDecryptor] (#510).
//
// Round-trip strategy: we don't have an offline-generated PWA envelope
// fixture (browsers + WebCrypto vs `cryptography` Dart package), so each
// test builds its own envelope using the same primitives that the PWA's
// `vault.ts` uses (PBKDF2-HMAC-SHA256 600k / AES-GCM-256 / 12-byte IV /
// tag-appended ciphertext). This proves the parity contract:
//   - PBKDF2 params + salt encoding produce a stable KEK.
//   - AES-GCM IV+tag layout matches WebCrypto.
//   - Wrong password → SecretBoxAuthenticationError → VaultDecryptException.
//
// Tests use a low-iteration PBKDF2 override on the decryptor — running 600k
// iterations is ~half a second in test mode and we'd burn the wall-clock
// budget on a noisy local loop. The crypto contract under test (HMAC-SHA256
// + iteration count round-trip) is unchanged by the iteration count.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/storage/vault.dart';

/// Lower-iteration PBKDF2 for fast tests. Production code uses
/// kVaultPbkdf2Iterations (600k); we override here so test runtimes stay
/// sub-second. Round-trip parity is independent of iteration count — the
/// same param chain (Pbkdf2 → KEK → AES-GCM unwrap → DEK → AES-GCM decrypt)
/// runs in both cases.
Pbkdf2 _fastPbkdf2() => Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 1000,
      bits: 256,
    );

Future<Map<String, String>> _buildEnvelope({
  required String password,
  required Map<String, Map<String, Object?>> secrets,
  required Pbkdf2 pbkdf2,
}) async {
  final random = Random.secure();
  final salt = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );

  // Generate DEK (32 bytes for AES-256-GCM).
  final dekBytes = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  final dek = SecretKey(dekBytes);

  // Derive KEK from password.
  final kek = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );

  final aesGcm = AesGcm.with256bits();

  // Wrap DEK under KEK.
  final dekWrapIv = Uint8List.fromList(
    List<int>.generate(12, (_) => random.nextInt(256)),
  );
  final dekWrapBox = await aesGcm.encrypt(
    dekBytes,
    secretKey: kek,
    nonce: dekWrapIv,
  );
  // WebCrypto layout: ciphertext + tag concatenated.
  final dekWrapCt = Uint8List.fromList([
    ...dekWrapBox.cipherText,
    ...dekWrapBox.mac.bytes,
  ]);

  // Encrypt each secret under DEK.
  final encryptedEntries = <String, Map<String, String>>{};
  for (final entry in secrets.entries) {
    final iv = Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    final box = await aesGcm.encrypt(
      utf8.encode(jsonEncode(entry.value)),
      secretKey: dek,
      nonce: iv,
    );
    final ct = Uint8List.fromList([
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    encryptedEntries[entry.key] = <String, String>{
      'iv': base64Encode(iv),
      'ct': base64Encode(ct),
    };
  }

  final meta = <String, Object?>{
    'salt': base64Encode(salt),
    'dekPw': <String, String>{
      'iv': base64Encode(dekWrapIv),
      'ct': base64Encode(dekWrapCt),
    },
  };

  return <String, String>{
    'encrypted': jsonEncode(encryptedEntries),
    'meta': jsonEncode(meta),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultDecryptor.decryptEnvelope', () {
    test('round-trips a single secret with the right password', () async {
      final pbkdf2 = _fastPbkdf2();
      final secret = <String, Object?>{
        'password': 'hunter2',
        'authType': 'password',
      };
      final envelope = await _buildEnvelope(
        password: 'masterpw',
        secrets: <String, Map<String, Object?>>{'vault-1': secret},
        pbkdf2: pbkdf2,
      );

      final decryptor = VaultDecryptor(pbkdf2: pbkdf2);
      final out = await decryptor.decryptEnvelope(
        encryptedJson: envelope['encrypted']!,
        metaJson: envelope['meta']!,
        password: 'masterpw',
      );

      expect(out, hasLength(1));
      expect(out['vault-1'], secret);
    });

    test('round-trips multiple secrets', () async {
      final pbkdf2 = _fastPbkdf2();
      final envelope = await _buildEnvelope(
        password: 'pw',
        secrets: <String, Map<String, Object?>>{
          'v1': <String, Object?>{'password': 'one'},
          'v2': <String, Object?>{'password': 'two', 'passphrase': 'xyz'},
        },
        pbkdf2: pbkdf2,
      );

      final decryptor = VaultDecryptor(pbkdf2: pbkdf2);
      final out = await decryptor.decryptEnvelope(
        encryptedJson: envelope['encrypted']!,
        metaJson: envelope['meta']!,
        password: 'pw',
      );

      expect(out.keys.toSet(), {'v1', 'v2'});
      expect(out['v1']!['password'], 'one');
      expect(out['v2']!['passphrase'], 'xyz');
    });

    test('throws VaultDecryptException on wrong password', () async {
      final pbkdf2 = _fastPbkdf2();
      final envelope = await _buildEnvelope(
        password: 'correct-horse',
        secrets: <String, Map<String, Object?>>{
          'v1': <String, Object?>{'password': 'secret'},
        },
        pbkdf2: pbkdf2,
      );

      final decryptor = VaultDecryptor(pbkdf2: pbkdf2);

      await expectLater(
        decryptor.decryptEnvelope(
          encryptedJson: envelope['encrypted']!,
          metaJson: envelope['meta']!,
          password: 'wrong-password',
        ),
        throwsA(isA<VaultDecryptException>()),
      );
    });

    test('throws VaultEnvelopeException on malformed meta', () async {
      final decryptor = VaultDecryptor(pbkdf2: _fastPbkdf2());
      await expectLater(
        decryptor.decryptEnvelope(
          encryptedJson: '{}',
          metaJson: 'not json at all',
          password: 'pw',
        ),
        throwsA(isA<VaultEnvelopeException>()),
      );
    });

    test('throws VaultEnvelopeException on missing meta.salt', () async {
      final decryptor = VaultDecryptor(pbkdf2: _fastPbkdf2());
      await expectLater(
        decryptor.decryptEnvelope(
          encryptedJson: '{}',
          metaJson: '{"dekPw":{"iv":"","ct":""}}',
          password: 'pw',
        ),
        throwsA(isA<VaultEnvelopeException>()),
      );
    });

    test('silently ignores dekBio in meta (device-specific wrap)', () async {
      // PWA backups carry dekBio when the source device enrolled biometric;
      // it's tied to the source device's WebAuthn credential and cannot
      // decrypt here. Native must NOT crash on its presence.
      final pbkdf2 = _fastPbkdf2();
      final envelope = await _buildEnvelope(
        password: 'pw',
        secrets: <String, Map<String, Object?>>{
          'v1': <String, Object?>{'password': 'x'},
        },
        pbkdf2: pbkdf2,
      );

      // Inject a bogus dekBio into the meta. The decryptor should ignore it.
      final metaParsed = jsonDecode(envelope['meta']!) as Map<String, dynamic>;
      metaParsed['dekBio'] = <String, String>{
        'iv': base64Encode(Uint8List(12)),
        'ct': base64Encode(Uint8List(32)),
      };
      final tamperedMeta = jsonEncode(metaParsed);

      final decryptor = VaultDecryptor(pbkdf2: pbkdf2);
      final out = await decryptor.decryptEnvelope(
        encryptedJson: envelope['encrypted']!,
        metaJson: tamperedMeta,
        password: 'pw',
      );

      expect(out['v1']!['password'], 'x');
    });

    test('skips individual malformed entries but decrypts the rest',
        () async {
      final pbkdf2 = _fastPbkdf2();
      final envelope = await _buildEnvelope(
        password: 'pw',
        secrets: <String, Map<String, Object?>>{
          'good': <String, Object?>{'password': 'ok'},
        },
        pbkdf2: pbkdf2,
      );

      // Tamper: add a malformed entry to the encrypted map.
      final entries =
          jsonDecode(envelope['encrypted']!) as Map<String, dynamic>;
      entries['bad'] = <String, String>{'iv': 'not base 64!@#', 'ct': 'zzz'};
      final tamperedEncrypted = jsonEncode(entries);

      final decryptor = VaultDecryptor(pbkdf2: pbkdf2);
      final out = await decryptor.decryptEnvelope(
        encryptedJson: tamperedEncrypted,
        metaJson: envelope['meta']!,
        password: 'pw',
      );

      expect(out.keys, {'good'});
    });
  });
}
