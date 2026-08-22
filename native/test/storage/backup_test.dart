// Backup envelope crypto (encrypted export/import, codex-reviewed design):
// Argon2id (params in-envelope, strictly bounded on read) → AES-256-GCM with
// the canonical header authenticated as AAD. One generic error for wrong
// passphrase / any tamper. These tests use tiny KDF params via the
// permissive test bounds — real defaults are pinned by constants tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/storage/backup.dart';

// Tiny-but-valid Argon2 params so the suite stays fast; the permissive bounds
// accept them (strict bounds would reject — asserted below).
const _tinyKdf = BackupKdfParams(mKiB: 64, t: 1, p: 1);
const _testBounds = BackupKdfBounds(
  minMKiB: 8,
  maxMKiB: 65536,
  minT: 1,
  maxT: 6,
  maxP: 1,
);

Map<String, Object?> _payload() => <String, Object?>{
      'payloadVersion': 1,
      'profiles': [
        {'host': 'h.example', 'port': 22, 'username': 'me'},
      ],
      'secrets': {
        'profile-h.example:22:me': {'password': 'hunter2hunter2'},
      },
    };

Future<String> _encryptTiny(Map<String, Object?> payload, String pass) =>
    encryptBackupEnvelope(
      payload: payload,
      passphrase: pass,
      kdf: _tinyKdf,
    );

Future<Map<String, Object?>> _decryptTiny(String envelope, String pass) =>
    decryptBackupEnvelope(
      envelopeJson: envelope,
      passphrase: pass,
      bounds: _testBounds,
    );

void main() {
  const pass = 'correct horse battery';

  test('round trip: payload survives encrypt → decrypt', () async {
    final envelope = await _encryptTiny(_payload(), pass);
    final out = await _decryptTiny(envelope, pass);
    expect(out, _payload());
  });

  test('outer envelope leaks no payload content', () async {
    final envelope = await _encryptTiny(_payload(), pass);
    expect(envelope, isNot(contains('h.example')));
    expect(envelope, isNot(contains('hunter2')));
    expect(envelope, isNot(contains('profiles')));
    final outer = jsonDecode(envelope) as Map<String, dynamic>;
    expect(outer.keys.toSet(),
        {'format', 'version', 'kdf', 'cipher', 'ciphertext'},
        reason: 'createdAt/appVersion live INSIDE the ciphertext');
    expect(outer['format'], 'mobissh-backup');
    expect(outer['version'], 2);
  });

  test('wrong passphrase → single generic error', () async {
    final envelope = await _encryptTiny(_payload(), pass);
    await expectLater(
      _decryptTiny(envelope, 'not the passphrase'),
      throwsA(isA<BackupException>().having(
          (e) => e.message, 'message', kBackupGenericError)),
    );
  });

  test('tampered ciphertext byte → same generic error', () async {
    final envelope = await _encryptTiny(_payload(), pass);
    final outer = jsonDecode(envelope) as Map<String, dynamic>;
    final ct = base64Decode(outer['ciphertext'] as String);
    ct[ct.length ~/ 2] ^= 0x01;
    outer['ciphertext'] = base64Encode(ct);
    await expectLater(
      _decryptTiny(jsonEncode(outer), pass),
      throwsA(isA<BackupException>().having(
          (e) => e.message, 'message', kBackupGenericError)),
    );
  });

  test('tampered header field breaks AAD → generic error', () async {
    final envelope = await _encryptTiny(_payload(), pass);
    // Bump t within bounds: KDF derives a different key AND the AAD no longer
    // matches — either way decrypt must fail with the generic error.
    final outer = jsonDecode(envelope) as Map<String, dynamic>;
    final kdf = Map<String, dynamic>.from(outer['kdf'] as Map);
    kdf['t'] = (kdf['t'] as int) + 1;
    outer['kdf'] = kdf;
    await expectLater(
      _decryptTiny(jsonEncode(outer), pass),
      throwsA(isA<BackupException>().having(
          (e) => e.message, 'message', kBackupGenericError)),
    );
  });

  test('two exports of identical state differ (fresh salt + IV)', () async {
    final a = await _encryptTiny(_payload(), pass);
    final b = await _encryptTiny(_payload(), pass);
    final oa = jsonDecode(a) as Map<String, dynamic>;
    final ob = jsonDecode(b) as Map<String, dynamic>;
    expect((oa['kdf'] as Map)['salt'], isNot((ob['kdf'] as Map)['salt']));
    expect((oa['cipher'] as Map)['iv'], isNot((ob['cipher'] as Map)['iv']));
    expect(oa['ciphertext'], isNot(ob['ciphertext']));
  });

  test('KDF params are read FROM the envelope', () async {
    final envelope = await encryptBackupEnvelope(
      payload: _payload(),
      passphrase: pass,
      kdf: const BackupKdfParams(mKiB: 128, t: 2, p: 1),
    );
    final out = await _decryptTiny(envelope, pass);
    expect(out, _payload());
  });

  group('strict bounds reject hostile envelopes', () {
    Future<String> tinyEnvelope() => _encryptTiny(_payload(), pass);

    test('below-minimum memory rejected by STRICT bounds', () async {
      // The tiny test envelope itself (m=64 KiB) must be rejected under the
      // strict production bounds — proving prod never runs attacker-cheap KDF.
      final envelope = await tinyEnvelope();
      await expectLater(
        decryptBackupEnvelope(envelopeJson: envelope, passphrase: pass),
        throwsA(isA<BackupException>()),
      );
    });

    Future<void> expectRejected(
        Map<String, dynamic> Function(Map<String, dynamic>) mutate) async {
      final outer =
          jsonDecode(await tinyEnvelope()) as Map<String, dynamic>;
      final mutated = mutate(Map<String, dynamic>.from(outer));
      await expectLater(
        _decryptTiny(jsonEncode(mutated), pass),
        throwsA(isA<BackupException>()),
      );
    }

    test('absurd memory demand rejected before allocation', () async {
      await expectRejected((o) {
        final kdf = Map<String, dynamic>.from(o['kdf'] as Map);
        kdf['mKiB'] = 8 * 1024 * 1024; // 8 GiB
        return o..['kdf'] = kdf;
      });
    });

    test('unknown KDF algorithm rejected', () async {
      await expectRejected((o) {
        final kdf = Map<String, dynamic>.from(o['kdf'] as Map);
        kdf['algo'] = 'md5';
        return o..['kdf'] = kdf;
      });
    });

    test('unknown cipher rejected', () async {
      await expectRejected((o) {
        final cipher = Map<String, dynamic>.from(o['cipher'] as Map);
        cipher['algo'] = 'aes-256-cbc';
        return o..['cipher'] = cipher;
      });
    });

    test('wrong salt / IV lengths rejected', () async {
      await expectRejected((o) {
        final kdf = Map<String, dynamic>.from(o['kdf'] as Map);
        kdf['salt'] = base64Encode(Uint8List(8)); // 8B, need 16B
        return o..['kdf'] = kdf;
      });
      await expectRejected((o) {
        final cipher = Map<String, dynamic>.from(o['cipher'] as Map);
        cipher['iv'] = base64Encode(Uint8List(16)); // 16B, need 12B
        return o..['cipher'] = cipher;
      });
    });

    test('ciphertext shorter than a GCM tag rejected', () async {
      await expectRejected(
          (o) => o..['ciphertext'] = base64Encode(Uint8List(8)));
    });

    test('wrong format/version rejected', () async {
      await expectRejected((o) => o..['format'] = 'other');
      await expectRejected((o) => o..['version'] = 3);
    });

    test('oversized envelope rejected before parsing work', () async {
      final big = '{"format":"mobissh-backup","version":2,"pad":"'
          '${'a' * (kBackupMaxEnvelopeBytes + 1)}"}';
      await expectLater(
        _decryptTiny(big, pass),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('passphrase policy', () {
    test('minimum 12 characters', () {
      expect(validateBackupPassphrase('elevenchars'), isNotNull);
      expect(validateBackupPassphrase('twelve chars'), isNull);
    });

    test('over 1024 UTF-8 bytes rejected', () {
      expect(validateBackupPassphrase('a' * 1025), isNotNull);
      expect(validateBackupPassphrase('a' * 1024), isNull);
    });

    test('unicode counts in bytes, exact — no trimming', () async {
      // 12 chars with leading/trailing spaces is VALID and significant.
      const spaced = ' twelve char ';
      expect(validateBackupPassphrase(spaced), isNull);
      final envelope = await _encryptTiny(_payload(), spaced);
      await expectLater(
        _decryptTiny(envelope, spaced.trim()),
        throwsA(isA<BackupException>()),
        reason: 'passphrase bytes are exact — no normalization',
      );
      expect(await _decryptTiny(envelope, spaced), _payload());
    });
  });

  test('production defaults pinned (OWASP-minimum Argon2id)', () {
    expect(kBackupDefaultKdf.mKiB, 19456);
    expect(kBackupDefaultKdf.t, 2);
    expect(kBackupDefaultKdf.p, 1);
    expect(kBackupStrictBounds.minMKiB, 19456);
    expect(kBackupStrictBounds.maxMKiB, 65536);
    expect(kBackupStrictBounds.minT, 2);
    expect(kBackupStrictBounds.maxT, 6);
    expect(kBackupStrictBounds.maxP, 1);
  });
}
