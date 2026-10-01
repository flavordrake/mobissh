// CHANGED host-key review + deliberate re-trust (#1235).
//
// The fail-closed mismatch (#1108) stays fail-closed: re-trusting takes two
// explicit steps. Review → "Forget old key and reconnect" drops ONLY the stored
// key for that host:port; the reconnect then meets the ordinary first-contact
// prompt, where the user accepts the offered key (or not). Nothing here ever
// trusts a key by itself.
//
// Persistent action, never a toast (feedback_actionable_guidance_not_toast):
// the Review button lives where the failure is shown (terminal Disconnected
// banner, profile row inline error).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ssh/ssh_session.dart';
import '../ssh/ssh_session_proxy.dart';
import '../state/sessions.dart';
import 'host_key_dialog.dart';

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// `/etc/ssh/ssh_host_<x>_key.pub` naming for an SSH key algorithm.
String _hostKeyFileType(String keyType) {
  if (keyType.contains('ed25519')) return 'ed25519';
  if (keyType.contains('ecdsa')) return 'ecdsa';
  if (keyType.contains('rsa')) return 'rsa';
  if (keyType.contains('dss')) return 'dsa';
  return '<type>';
}

/// Review dialog for a refused CHANGED key. Resolves true only when the user
/// chose "Forget old key and reconnect"; Cancel (the default) and dismissal
/// resolve false.
Future<bool> showHostKeyMismatchDialog(
  BuildContext context, {
  required HostKeyMismatch mismatch,
}) async {
  final m = mismatch;
  final target = m.jumpHop
      ? 'Jump host ${m.host}:${m.port}'
      : '${m.host}:${m.port}';
  // #1226: a CHANGED key is SHA256 vs SHA256 (a legacy MD5 entry re-confirms
  // instead), and plain `ssh-keygen -l` prints SHA256.
  final verifyCmd =
      'ssh-keygen -l -f /etc/ssh/ssh_host_${_hostKeyFileType(m.keyType)}_key.pub';
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final error = Theme.of(ctx).colorScheme.error;
      return AlertDialog(
        key: const Key('hostkey-mismatch-dialog'),
        title: const Text('Host key changed'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(target, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Key type: ${m.keyType}'),
              const SizedBox(height: 12),
              const Text('Trusted key (stored, SHA256):'),
              SelectableText(
                m.storedFingerprint,
                key: const Key('hostkey-mismatch-stored'),
                style: _mono,
              ),
              const SizedBox(height: 8),
              const Text('Key the server offers now (SHA256):'),
              SelectableText(
                m.offeredFingerprint,
                key: const Key('hostkey-mismatch-offered'),
                style: _mono,
              ),
              const SizedBox(height: 12),
              Text(
                'This server is not using the key you trusted. That is normal '
                'after a host is rebuilt or its keys are regenerated, but it is '
                'also exactly what a man-in-the-middle attack looks like. Only '
                'continue if you know the key changed.',
                style: TextStyle(color: error),
              ),
              const SizedBox(height: 12),
              const Text(
                'Check on the server (compare with the offered key, ignoring '
                'the colons):',
              ),
              SelectableText(verifyCmd, style: _mono),
              const SizedBox(height: 12),
              const Text(
                'Forgetting removes only the stored key for this host. You '
                'will then be asked to trust the offered key explicitly.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('hostkey-mismatch-cancel'),
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('hostkey-mismatch-forget'),
            style: FilledButton.styleFrom(
              backgroundColor: error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forget old key and reconnect'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// "Host key changed — Review" for a session that failed on a CHANGED key.
/// Renders nothing for any other state or failure. `disconnected` counts: a
/// failed first connect stops the foreground service, whose teardown moves the
/// session on to `disconnected` while the mismatch is still the reason.
class HostKeyReviewAction extends StatelessWidget {
  const HostKeyReviewAction({
    super.key,
    required this.sessionId,
    required this.data,
    required this.onForget,
    this.foregroundColor,
  });

  final String sessionId;
  final SshSessionData data;

  /// Called once the user confirmed Forget in the review dialog.
  final void Function(HostKeyMismatch mismatch) onForget;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final m = data.hostKeyMismatch;
    final dropped =
        data.state == SshSessionState.failed ||
        data.state == SshSessionState.disconnected;
    if (!dropped || m == null) return const SizedBox.shrink();
    return TextButton.icon(
      key: Key('hostkey-review-$sessionId'),
      style: TextButton.styleFrom(
        foregroundColor: foregroundColor,
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
      label: const Text('Host key changed — Review'),
      onPressed: () async {
        if (await showHostKeyMismatchDialog(context, mismatch: m)) onForget(m);
      },
    );
  }
}

/// Prompts already on screen, by `sessionId|fingerprint`, so the chooser's
/// listener and the post-forget watcher never stack two dialogs.
final Set<String> _promptsShowing = <String>{};

/// Show the ordinary first-contact prompt for [pending] once and forward the
/// decision to [proxy].
Future<void> promptHostKeyOnce(
  BuildContext context,
  SshSessionProxy proxy,
  PendingHostKey pending,
) async {
  final key = '${proxy.sessionId}|${pending.fingerprint}';
  if (!_promptsShowing.add(key)) return;
  try {
    final accepted = await showHostKeyDialog(context, pending: pending);
    if (accepted) {
      proxy.acceptHostKey();
    } else {
      proxy.rejectHostKey();
    }
  } finally {
    _promptsShowing.remove(key);
  }
}

/// Forget [sessionId]'s mismatched key, reconnect, and show the first-contact
/// prompt when the reconnect reaches it. The chooser only prompts for the
/// ACTIVE session and is not mounted while other sessions keep the terminal
/// up, so the prompt is armed here, on the root navigator.
void forgetHostKeyAndRetrust(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) {
  SshSessionProxy? proxy;
  for (final e in ref.read(sessionsProvider).entries) {
    if (e.id == sessionId) proxy = e.proxy;
  }
  final p = proxy;
  if (p == null) return;
  final navContext = Navigator.of(context, rootNavigator: true).context;
  var redialing = false;
  late final StreamSubscription<SshSessionData> sub;
  sub = p.stream.listen((d) {
    final pending = d.pendingHostKey;
    if (pending != null) {
      unawaited(sub.cancel());
      if (navContext.mounted) {
        unawaited(promptHostKeyOnce(navContext, p, pending));
      }
      return;
    }
    switch (d.state) {
      case SshSessionState.reconnecting:
      case SshSessionState.connecting:
        redialing = true;
      case SshSessionState.connected:
      case SshSessionState.disconnected:
        unawaited(sub.cancel());
      case SshSessionState.failed:
        // The forget's own update is still `failed`; only a failure AFTER the
        // re-dial started ends the watch.
        if (redialing) unawaited(sub.cancel());
      case SshSessionState.idle:
      case SshSessionState.awaitingHostKey:
      case SshSessionState.authenticating:
      case SshSessionState.softDisconnected:
        break;
    }
  });
  unawaited(
    ref.read(sessionsProvider.notifier).forgetHostKeyAndReconnect(sessionId),
  );
}
