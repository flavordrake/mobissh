// Throwaway SSH key fixtures for #1122 derivation tests. REAL keys generated
// with `ssh-keygen -t ed25519` purely as test data — never used anywhere.
// Expected public lines / fingerprints verified with `ssh-keygen -lf`.

/// Unencrypted ed25519 private key (comment: mobissh-test).
const String kTestEd25519Pem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBN02DhbocmphwWtFR/CQDzusdFXcZtLAP4RosN2JhgdAAAAJBWq2bVVqtm
1QAAAAtzc2gtZWQyNTUxOQAAACBN02DhbocmphwWtFR/CQDzusdFXcZtLAP4RosN2JhgdA
AAAEClWD6sb65XJm6ivawLO9U2di7oxgI7z+GBu1evfrAYGk3TYOFuhyamHBa0VH8JAPO6
x0Vdxm0sA/hGiw3YmGB0AAAADG1vYmlzc2gtdGVzdAE=
-----END OPENSSH PRIVATE KEY-----
''';

/// Expected OpenSSH public line for [kTestEd25519Pem] (no comment).
const String kTestEd25519PublicLine =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE3TYOFuhyamHBa0VH8JAPO6x0Vdxm0sA/hGiw3YmGB0';

/// Expected `ssh-keygen -lf` fingerprint for [kTestEd25519Pem].
const String kTestEd25519Fingerprint =
    'SHA256:kq/+vc+ujo+5vu6DRfmmvMTp1fzDDwHunJILhC1IA8s';

/// Passphrase protecting [kTestEncryptedPem].
const String kTestEncryptedPassphrase = 'test-passphrase';

/// ed25519 private key encrypted with [kTestEncryptedPassphrase]
/// (comment: mobissh-test-enc).
const String kTestEncryptedPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBcn8ymLP
T3NbDuSI3H8iuKAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHNAtwBbsd4wGFt7
MLCOIdTzfcU2KE0n4s0LpTu8BXeRAAAAoIkGYxj6ORhYYssIKezRrp/22UKBAVmlwt/OsZ
ZOP6iYvIDcCAadtpe3ShLH4sBwbm84BBLXtGBf7J82Q2euRCMwCpc7wRefq/gj/ywgiO9a
JW7SFs+32EFdCC1qzeXaNaVhd4rsf+bshVbOBWHxdPp5MGsMfneEEIU5j2zPXagvCLQ57Y
cEzk19JgClxRhl9OgQnSKh+E43tarfzCeFJ+k=
-----END OPENSSH PRIVATE KEY-----
''';

/// Expected OpenSSH public line for [kTestEncryptedPem] (no comment).
const String kTestEncryptedPublicLine =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNAtwBbsd4wGFt7MLCOIdTzfcU2KE0n4s0LpTu8BXeR';

/// Expected `ssh-keygen -lf` fingerprint for [kTestEncryptedPem].
const String kTestEncryptedFingerprint =
    'SHA256:9896ZFAoSt7DXYNWuzk9JJRx02wuj/8RPPTKOLyJZcQ';
