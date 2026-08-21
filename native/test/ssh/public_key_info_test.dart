// Tests for derivePublicKeyInfo (#1122): derive the OpenSSH public line +
// SHA256 fingerprint + algorithm from a private key PEM, returning null (never
// throwing) for anything unparseable so import/restore is never blocked.
//
// Fixtures are real throwaway keys — see test/support/test_keys.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/ssh/public_key_info.dart';

import '../support/test_keys.dart';

void main() {
  test('unencrypted ed25519: exact public line, fingerprint, algorithm', () {
    final info = derivePublicKeyInfo(kTestEd25519Pem);
    expect(info, isNotNull);
    expect(info!.publicKeyLine, kTestEd25519PublicLine);
    expect(info.fingerprint, kTestEd25519Fingerprint);
    expect(info.algorithm, 'ed25519');
  });

  test('fingerprint carries no base64 padding (OpenSSH format)', () {
    final info = derivePublicKeyInfo(kTestEd25519Pem);
    expect(info!.fingerprint, startsWith('SHA256:'));
    expect(info.fingerprint, isNot(contains('=')));
  });

  test('garbage PEM returns null, never throws', () {
    expect(derivePublicKeyInfo('not a key at all'), isNull);
    expect(derivePublicKeyInfo(''), isNull);
    expect(
      derivePublicKeyInfo('-----BEGIN OPENSSH PRIVATE KEY-----\n!!\n'
          '-----END OPENSSH PRIVATE KEY-----'),
      isNull,
    );
  });

  test('encrypted PEM without passphrase returns null, never throws', () {
    expect(derivePublicKeyInfo(kTestEncryptedPem), isNull);
  });

  test('encrypted PEM with a wrong passphrase returns null, never throws', () {
    expect(
      derivePublicKeyInfo(kTestEncryptedPem, passphrase: 'wrong'),
      isNull,
    );
  });

  test('encrypted PEM with the correct passphrase derives', () {
    final info = derivePublicKeyInfo(
      kTestEncryptedPem,
      passphrase: kTestEncryptedPassphrase,
    );
    expect(info, isNotNull);
    expect(info!.publicKeyLine, kTestEncryptedPublicLine);
    expect(info.fingerprint, kTestEncryptedFingerprint);
    expect(info.algorithm, 'ed25519');
  });
}
