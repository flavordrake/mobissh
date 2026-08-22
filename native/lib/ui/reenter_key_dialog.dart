// Re-enter dialog (#1121): paste the private material for an EXISTING named
// key. Shared between the keys screen (row action) and the profile editor's
// stored-key note (the migration banner lands the user THERE, so the fill-in
// affordance must exist there too). No name field — the identity stays; the
// vault entry is restored under the key's same vault id, healing every profile
// attached to it. The PEM is never logged; it goes straight to the vault.

import 'package:flutter/material.dart';

import 'revealable_field.dart';
import 'top_toast.dart';

/// The values collected by [ReenterKeyDialog].
class ReenterKeyInput {
  const ReenterKeyInput({required this.pem, this.passphrase});
  final String pem;
  final String? passphrase;
}

/// Show the re-enter dialog for the key named [name]. Resolves to the pasted
/// material, or null when the user cancels.
Future<ReenterKeyInput?> showReenterKeyDialog(
  BuildContext context, {
  required String name,
}) {
  return showDialog<ReenterKeyInput>(
    context: context,
    builder: (_) => ReenterKeyDialog(name: name),
  );
}

class ReenterKeyDialog extends StatefulWidget {
  const ReenterKeyDialog({super.key, required this.name});

  final String name;

  @override
  State<ReenterKeyDialog> createState() => _ReenterKeyDialogState();
}

class _ReenterKeyDialogState extends State<ReenterKeyDialog> {
  final _pemCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  @override
  void dispose() {
    _pemCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pem = _pemCtrl.text.trim();
    if (pem.isEmpty) {
      showTopToast(context, 'Paste the private key');
      return;
    }
    final passphrase = _passphraseCtrl.text;
    Navigator.of(context).pop(
      ReenterKeyInput(
        pem: pem,
        passphrase: passphrase.isEmpty ? null : passphrase,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('keys-reenter-dialog'),
      title: Text('Re-enter "${widget.name}"'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste the private key for this entry — e.g. after a phone '
              'migration, when the stored copy can no longer be read on this '
              'device. Every profile using this key is restored at once.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('keys-reenter-pem'),
              controller: _pemCtrl,
              decoration: const InputDecoration(
                labelText: 'Private key (PEM / OpenSSH)',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 6,
              minLines: 4,
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            RevealableTextField(
              fieldKeyName: 'keys-reenter-passphrase',
              controller: _passphraseCtrl,
              labelText: 'Passphrase (optional)',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('keys-reenter-save'),
          onPressed: _submit,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
