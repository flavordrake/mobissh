// Fixed, key-free descriptions of a private-key parse failure (#1252).
//
// `SSHKeyPair.fromPem` exceptions can quote the key itself (a base64
// FormatException prints the source around the bad character). Their text
// must never reach error state, logs or bug reports, so callers report only
// the coarse kind from here.

import 'package:dartssh2/dartssh2.dart';

/// The kind of failure, from the exception's TYPE only (never its text).
String keyParseFailureKind(Object e) {
  if (e is SSHKeyDecryptError) return 'wrong or missing passphrase';
  // dartssh2 raises ArgumentError for a passphrase given to an unencrypted
  // key, or missing for an encrypted one.
  if (e is ArgumentError) return 'wrong or missing passphrase';
  if (e is UnsupportedError) return 'unsupported format';
  return 'corrupted';
}

/// The user-facing message for a private-key parse failure.
String keyParseFailureMessage(Object e) =>
    "Couldn't read the private key: ${keyParseFailureKind(e)}";
