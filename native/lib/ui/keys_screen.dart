// SSH key library manager (#1088 Slice 1b). Its own route, reached from
// Settings. Lists the named library keys ([savedKeysProvider]) — each row shows
// ONLY non-secret metadata (name, algorithm, fingerprint); the private key
// bytes live solely in the vault and are NEVER rendered or logged here.
//
// Add: paste a PEM/OpenSSH private key + a name (+ optional passphrase) →
// [KeysManager.addKey], which refuses a key that doesn't parse (#1259). Per row: Rename ([KeysManager.rename]) and Delete
// ([KeysManager.delete], warning when profiles still reference the key by its
// `keyVaultId`). Generation is Slice 2, out of scope here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/clipboard.dart';
import '../state/keys_providers.dart';
import '../state/profiles_providers.dart';
import '../storage/keys_store.dart';
import 'reenter_key_dialog.dart';
import 'revealable_field.dart';
import 'top_toast.dart';

/// Push the key-library manager as a route.
Future<void> showKeysScreen(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const KeysScreen()),
  );
}

class KeysScreen extends ConsumerStatefulWidget {
  const KeysScreen({super.key});

  @override
  ConsumerState<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends ConsumerState<KeysScreen> {
  @override
  void initState() {
    super.initState();
    // Unify the library with pre-existing per-profile keys (#1088): adopt any
    // profile key not yet in the library so it shows here by name. Idempotent
    // and a no-op when there's nothing to adopt; the savedKeysProvider watch
    // below picks up the newly-adopted rows after it invalidates.
    ref.read(keysManagerProvider).adoptFromProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final keysAsync = ref.watch(savedKeysProvider);
    return Scaffold(
      key: const ValueKey('keys-screen'),
      appBar: AppBar(title: const Text('SSH keys')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('keys-add-fab'),
        onPressed: () => showAddKeyDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add key'),
      ),
      body: SafeArea(
        child: keysAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text('Could not load keys: $e'),
          ),
          data: (keys) {
            if (keys.isEmpty) {
              return const Center(
                key: ValueKey('keys-empty'),
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No SSH keys yet. Tap "Add key" to paste a private key '
                    'you can then attach to one or more profiles.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.builder(
              key: const ValueKey('keys-list'),
              itemCount: keys.length,
              itemBuilder: (context, i) => _KeyRow(
                key: ValueKey('keys-row-${keys[i].id}'),
                savedKey: keys[i],
              ),
            );
          },
        ),
      ),
    );
  }

}

/// The Add-key dialog (#1259), shared by the Keys screen and the profile
/// editor. It validates the key before storing anything and stays open with
/// an inline error until the key parses. Resolves to the stored key — the
/// only case that toasts "Key added" — or null when cancelled.
Future<SavedKey?> showAddKeyDialog(BuildContext context) async {
  final key = await showDialog<SavedKey>(
    context: context,
    builder: (_) => const _AddKeyDialog(),
  );
  if (key != null && context.mounted) showTopToast(context, 'Key added');
  return key;
}

/// One library-key row: name + optional algorithm/fingerprint, plus a Rename /
/// Delete overflow menu. Never shows private material.
class _KeyRow extends ConsumerWidget {
  const _KeyRow({super.key, required this.savedKey});

  final SavedKey savedKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleParts = <String>[
      if (savedKey.algorithm != null && savedKey.algorithm!.isNotEmpty)
        savedKey.algorithm!,
      if (savedKey.fingerprint != null && savedKey.fingerprint!.isNotEmpty)
        savedKey.fingerprint!,
    ];
    final publicKey = savedKey.publicKey;
    return ListTile(
      leading: const Icon(Icons.vpn_key_outlined),
      title: Text(savedKey.name),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
      // Tap shows the full OpenSSH public line (#1122) — NON-secret, used to
      // match this entry against authorized_keys. No-op when unknown.
      onTap: publicKey == null || publicKey.isEmpty
          ? null
          : () => _showPublicKey(context, publicKey),
      trailing: PopupMenuButton<String>(
        key: ValueKey('keys-row-menu-${savedKey.id}'),
        onSelected: (v) {
          if (v == 'rename') {
            _rename(context, ref);
          } else if (v == 'reenter') {
            _reenter(context, ref);
          } else if (v == 'delete') {
            _delete(context, ref);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem<String>(value: 'rename', child: Text('Rename')),
          // Restore the private material of THIS named key in place (#1121):
          // after a phone migration the metadata survives but the vault entry
          // is unreadable — re-entering here heals every attached profile.
          PopupMenuItem<String>(value: 'reenter', child: Text('Re-enter key')),
          PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _showPublicKey(BuildContext context, String publicKey) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('keys-pubkey-dialog'),
        title: Text(savedKey.name),
        content: SingleChildScrollView(
          child: SelectableText(
            publicKey,
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('keys-pubkey-copy'),
            onPressed: () async {
              // Copy the public line ONLY — it is non-secret by definition.
              await copyToClipboard(publicKey);
              if (ctx.mounted) Navigator.of(ctx).pop();
              // Toast on the ROW's context — the dialog's is gone post-pop.
              if (context.mounted) showTopToast(context, 'Public key copied');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: savedKey.name),
    );
    if (name == null) return;
    await ref.read(keysManagerProvider).rename(savedKey.id, name);
  }

  Future<void> _reenter(BuildContext context, WidgetRef ref) async {
    final input = await showReenterKeyDialog(context, name: savedKey.name);
    if (input == null) return;
    await ref.read(keysManagerProvider).reenterPem(
          savedKey.id,
          pem: input.pem,
          passphrase: input.passphrase,
        );
    if (context.mounted) {
      showTopToast(context, 'Key "${savedKey.name}" restored');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    // Warn when profiles still point their keyVaultId at this key — deleting
    // leaves those profiles needing a new key (we still allow it).
    final profiles =
        await ref.read(savedProfilesProvider.future);
    final usedBy =
        profiles.where((p) => p.keyVaultId == savedKey.vaultId).length;
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('keys-delete-dialog'),
        title: Text('Delete "${savedKey.name}"?'),
        content: Text(
          usedBy > 0
              ? 'Used by $usedBy profile${usedBy == 1 ? '' : 's'}; '
                  "they'll need a new key. This can't be undone."
              : "This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('keys-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(keysManagerProvider).delete(savedKey.id);
  }
}

/// Add-key dialog: name + pasted PEM + optional passphrase. The PEM is a key
/// blob so it is shown in a plain multiline field (not obscured), but it is
/// NEVER logged — it goes straight to the vault via the manager, and only
/// after [KeysManager.addKey] has parsed it (#1259).
class _AddKeyDialog extends ConsumerStatefulWidget {
  const _AddKeyDialog();

  @override
  ConsumerState<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends ConsumerState<_AddKeyDialog> {
  final _nameCtrl = TextEditingController();
  final _pemCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  bool _busy = false;

  /// Inline, key-free reason the last Add was refused (#1259). A field error
  /// the user acts on in place, never a toast.
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pemCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pem = _pemCtrl.text.trim();
    if (pem.isEmpty) {
      setState(() => _error = 'Paste a private key');
      return;
    }
    final passphrase = _passphraseCtrl.text;
    setState(() => _busy = true);
    try {
      final key = await ref.read(keysManagerProvider).addKey(
            name: _nameCtrl.text,
            pem: pem,
            passphrase: passphrase.isEmpty ? null : passphrase,
          );
      if (mounted) Navigator.of(context).pop(key);
    } on KeyImportException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('keys-add-dialog'),
      title: const Text('Add SSH key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('keys-add-name'),
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. work laptop',
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('keys-add-pem'),
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
              fieldKeyName: 'keys-add-passphrase',
              controller: _passphraseCtrl,
              labelText: 'Passphrase (optional)',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const ValueKey('keys-add-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('keys-add-save'),
          onPressed: _busy ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Rename dialog: a single name field seeded with the current name.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('keys-rename-dialog'),
      title: const Text('Rename key'),
      content: TextField(
        key: const ValueKey('keys-rename-field'),
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => Navigator.of(context).pop(_ctrl.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('keys-rename-save'),
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
