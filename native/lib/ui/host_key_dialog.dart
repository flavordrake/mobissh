// Host-key trust prompt dialog.
//
// Trust-on-first-use prompt (#501), persisted by HostKeyStore (#565). #1226
// adds the one-time RE-CONFIRM variant for a saved legacy MD5 fingerprint that
// can't be compared with the SHA256 the server now reports.

import 'package:flutter/material.dart';

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
      content: Column(
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
          const SizedBox(height: 8),
          const Text('Fingerprint:'),
          const SizedBox(height: 4),
          SelectableText(
            pending.fingerprint,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Text(
            'Only trust this key if it matches what the server administrator '
            'expects. The fingerprint is saved on this device.',
            style: TextStyle(fontSize: 12),
          ),
        ],
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
