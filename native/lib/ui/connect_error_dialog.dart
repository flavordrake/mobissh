// Connect-error dialog (#648).
//
// When a connect attempt ends in `SshSessionState.failed` BEFORE the session
// ever reached `connected` (unreachable host, refused, no route, half-open path
// that hit the readyTimeout, bad key, rejected host key, auth failure), the user
// must see a clear error with the reason and a way forward — never a silent
// spinner or a no-op. Mirrors `showHostKeyDialog` (showDialog + AlertDialog) so
// the chooser surfaces failures the same way it surfaces host-key prompts.
//
// Returns `true` if the user chose "Retry" (caller should re-dispatch connect),
// `false`/null if the user dismissed with "Back".

import 'package:flutter/material.dart';

/// Show a modal explaining why a connect attempt failed.
///
/// [reason] is the controller's `SshSessionData.error` string (e.g.
/// "TCP connect failed: ...", "No SSH response in 25s — host may be unreachable
/// or asleep", "Authentication failed: ..."). [target] is an optional
/// "host:port" label shown above the reason.
Future<bool> showConnectErrorDialog(
  BuildContext context, {
  required String reason,
  String? target,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('connect-error-dialog'),
      title: const Text('Connection failed'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (target != null && target.isNotEmpty) ...[
            Text(target, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
          ],
          Text(reason),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('connect-error-back'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Back'),
        ),
        FilledButton(
          key: const Key('connect-error-retry'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
  return result ?? false;
}
