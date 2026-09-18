// ssh_config EXPORT dialog (#1185, R23) — preview the saved profiles rendered
// as `~/.ssh/config` text and hand that text to the EXISTING share path (the
// same `FileViewerActionService` seam the file viewers use, with a
// [BytesFileSource]: the share sheet receives a FILE, never a path string).
//
// The preview states plainly that the artifact carries no secrets — the user
// is about to send this to another machine, and the one thing they must know
// is what it does and does not contain (R22).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/viewer_file_actions.dart';
import '../ssh/ssh_config_export.dart';
import '../state/keys_providers.dart';
import '../state/profiles_providers.dart';
import 'top_toast.dart';

/// Open the ssh_config export preview.
Future<void> showSshConfigExportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const SshConfigExportDialog(),
  );
}

class SshConfigExportDialog extends ConsumerWidget {
  const SshConfigExportDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(savedProfilesProvider).valueOrNull;
    final keys = ref.watch(savedKeysProvider).valueOrNull ?? const [];
    final theme = Theme.of(context);

    if (profiles == null) {
      return const AlertDialog(
        title: Text('Export as ssh config'),
        content: Center(
          key: Key('ssh-config-export-loading'),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final export = buildSshConfigExport(profiles, keys: keys);
    final empty = profiles.isEmpty;

    return AlertDialog(
      title: const Text('Export as ssh config'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No secrets are included: no passwords, no private keys, '
                    'no passphrases.',
                    key: const Key('ssh-config-export-no-secrets'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (empty)
              Text(
                'No saved profiles to export.',
                key: const Key('ssh-config-export-empty'),
                style: theme.textTheme.bodyMedium,
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    export.text,
                    key: const Key('ssh-config-export-preview'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ssh-config-export-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const Key('ssh-config-export-share'),
          onPressed: empty ? null : () => _share(context, ref, export.text),
          icon: const Icon(Icons.ios_share),
          label: const Text('Share'),
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context, WidgetRef ref, String text) async {
    final navigator = Navigator.of(context);
    final service = ref.read(fileViewerActionServiceProvider);
    try {
      await service.shareFile(BytesFileSource(
        fileName: sshConfigExportFileName,
        bytes: Uint8List.fromList(utf8.encode(text)),
      ));
      if (!context.mounted) return;
      navigator.pop();
    } catch (e) {
      if (!context.mounted) return;
      showTopToast(context, 'Share failed: $e');
    }
  }
}
