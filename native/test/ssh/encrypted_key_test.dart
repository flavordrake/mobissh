// Pinpoints the device key-auth hang: can dartssh2 decrypt a passphrase-
// protected OpenSSH key (aes256-ctr + bcrypt, the ssh-keygen default)?
//
// Real key profiles are passphrase-encrypted (device log: keyLen=463 ppLen=8).
// ssh_session.dart `_identitiesFor` does `SSHKeyPair.fromPem(pem, passphrase)`
// inside `catch (e) => return null`. If fromPem throws or hangs on an encrypted
// key, the null result + no password fallback for key auth = `authenticated`
// hangs forever. This test feeds a throwaway aes256-ctr/bcrypt ed25519 key
// (generated with `ssh-keygen -N hunter2x`) straight to fromPem.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

// Throwaway test key — NOT a real secret. Generated solely for this test.
const _encryptedPem = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCLp5MvTg
b4m67CBUF43f8JAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAICEzT2LZ3rgWNO9i
DNQ8Ee+pnlipQHc0XiiNyNSUhPSGAAAAkDDb6GuP+mBGqkCJmzZiMppmTmRHXsxmeCnT7n
0WySGp0HtoKj+xBg4IwdVj9fKa2MPfOWs8krZRZvwLaHUVdzeMZhZShicsjjIUtJBjaX6S
yniXb4FF/lNC4FXyautH+M6u96NxmxKd3DQthhTGckZ90u+ng+Z+JOjGQl+El4c62Pm8In
4Lc/PppbnKX1vsGw==
-----END OPENSSH PRIVATE KEY-----''';

const _passphrase = 'hunter2x';

void main() {
  test('dartssh2 decrypts an aes256-ctr/bcrypt ed25519 key with the right '
      'passphrase', () {
    final pairs = SSHKeyPair.fromPem(_encryptedPem, _passphrase);
    expect(pairs, isNotEmpty,
        reason: 'encrypted key should yield at least one identity');
    expect(pairs.first.type, contains('ed25519'));
  });

  test('wrong passphrase fails fast (throws) — never silently empty/hang', () {
    expect(
      () => SSHKeyPair.fromPem(_encryptedPem, 'wrong-passphrase'),
      throwsA(anything),
    );
  });
}
