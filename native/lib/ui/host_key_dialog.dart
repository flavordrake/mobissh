// Host-key trust prompt dialog.
//
// Trust-on-first-use prompt (#501), persisted by HostKeyStore (#565). #1226
// adds the one-time RE-CONFIRM variant for a saved legacy MD5 fingerprint that
// can't be compared with the SHA256 the server now reports.

import 'package:flutter/material.dart';

import '../ssh/host_key_store.dart';
import '../ssh/ssh_session.dart';

/// Show a modal confirming whether to trust the server's host key.
///
/// Returns:
///   - `true`  -> user trusts the key (caller should record it).
///   - `false` -> user cancelled (or dismissed the dialog).
Future<bool> showHostKeyDialog(
  BuildContext context, {
  required PendingHostKey pending,
}) async {
  final reconfirm = pending.formatChanged;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      key: Key(reconfirm ? 'host-key-reconfirm-dialog' : 'host-key-dialog'),
      icon: reconfirm
          ? Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(ctx).colorScheme.error,
            )
          : null,
      title: Text(reconfirm ? 'Re-confirm host key' : 'Verify host key'),
      // Scrolls: the re-confirm's two fingerprints + two commands can outgrow a
      // phone in landscape.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${pending.host}:${pending.port}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (reconfirm) ...[
              Text(
                'The saved key for ${pending.host}:${pending.port} uses an '
                "older fingerprint format and can't be compared. Confirm this "
                "server's key:",
              ),
              const SizedBox(height: 8),
            ],
            Text('Key type: ${pending.keyType}'),
            if (reconfirm && pending.storedFingerprint != null) ...[
              const SizedBox(height: 8),
              const Text('Saved fingerprint (old format):'),
              const SizedBox(height: 4),
              SelectableText(
                legacyMd5Display(pending.storedFingerprint!),
                key: const Key('host-key-stored-fingerprint'),
                style: _mono,
              ),
            ],
            const SizedBox(height: 8),
            Text(reconfirm ? 'Fingerprint offered now:' : 'Fingerprint:'),
            const SizedBox(height: 4),
            SelectableText(pending.fingerprint, style: _mono),
            if (reconfirm) ...[
              const SizedBox(height: 12),
              const Text(
                'Match the OLD fingerprint on the server to be sure this is '
                'the same host:',
              ),
              const SizedBox(height: 4),
              SelectableText(
                'ssh-keygen -l -E md5 -f ${hostKeyPubPath(pending.keyType)}',
                style: _mono,
              ),
              const SizedBox(height: 8),
              const Text('The new fingerprint should match:'),
              const SizedBox(height: 4),
              SelectableText(
                'ssh-keygen -l -f ${hostKeyPubPath(pending.keyType)}',
                style: _mono,
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Only trust this key if it matches what the server administrator '
              'expects. The fingerprint is saved on this device.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(reconfirm ? 'Confirm + connect' : 'Trust + connect'),
        ),
      ],
    ),
  );
  return result ?? false;
}

const TextStyle _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// A stored legacy MD5 in the form `ssh-keygen -E md5` prints
/// (`MD5:aa:bb:…`), so the user can match it character for character (#1249).
/// Anything that isn't the 32-hex legacy shape is shown as stored.
String legacyMd5Display(String stored) {
  if (!HostKeyStore.isLegacyMd5Fingerprint(stored)) return stored;
  final pairs = [
    for (var i = 0; i < stored.length; i += 2) stored.substring(i, i + 2),
  ];
  return 'MD5:${pairs.join(':')}';
}

/// The server-side public host key file for an SSH key type, e.g.
/// `ssh-ed25519` → `/etc/ssh/ssh_host_ed25519_key.pub` (#1249).
String hostKeyPubPath(String keyType) {
  final t = keyType.toLowerCase();
  final name = t.contains('ed25519')
      ? 'ed25519'
      : t.contains('ecdsa')
      ? 'ecdsa'
      : t.contains('rsa')
      ? 'rsa'
      : '<type>';
  return '/etc/ssh/ssh_host_${name}_key.pub';
}
