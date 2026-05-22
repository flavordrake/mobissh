// Host-key trust prompt dialog.
//
// Phase 1 (#501): trust-on-first-use prompt. Phase 3 will swap the backing
// store to flutter_secure_storage so trusted fingerprints survive restarts.

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
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Verify host key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${pending.host}:${pending.port}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text('Key type: ${pending.keyType}'),
          const SizedBox(height: 8),
          const Text('Fingerprint (SHA-256, hex):'),
          const SizedBox(height: 4),
          SelectableText(
            pending.fingerprint,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Only trust this key if it matches what the server administrator '
            'expects. The fingerprint is stored in memory for this session.',
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
          child: const Text('Trust + connect'),
        ),
      ],
    ),
  );
  return result ?? false;
}
