// SSH key library manager (#1088 Slice 1b). Its own route, reached from
// Settings. Lists the named library keys ([savedKeysProvider]) — each row shows
// ONLY non-secret metadata (name, algorithm, fingerprint); the private key
// bytes live solely in the vault and are NEVER rendered or logged here.
//
// Add: paste a PEM/OpenSSH private key + a name (+ optional passphrase) →
// [KeysManager.importFromPem]. Per row: Rename ([KeysManager.rename]) and Delete
// ([KeysManager.delete], warning when profiles still reference the key by its
// `keyVaultId`). Generation is Slice 2, out of scope here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/keys_providers.dart';
import '../state/profiles_providers.dart';
import '../storage/keys_store.dart';
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
        onPressed: () => _addKey(context, ref),
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

  Future<void> _addKey(BuildContext context, WidgetRef ref) async {
    final input = await showDialog<_AddKeyInput>(
      context: context,
      builder: (_) => const _AddKeyDialog(),
    );
    if (input == null) return;
    await ref.read(keysManagerProvider).importFromPem(
          name: input.name,
          pem: input.pem,
          passphrase: input.passphrase,
        );
    if (context.mounted) showTopToast(context, 'Key added');
  }
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
    return ListTile(
      leading: const Icon(Icons.vpn_key_outlined),
      title: Text(savedKey.name),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
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

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: savedKey.name),
    );
    if (name == null) return;
    await ref.read(keysManagerProvider).rename(savedKey.id, name);
  }

  Future<void> _reenter(BuildContext context, WidgetRef ref) async {
    final input = await showDialog<_ReenterKeyInput>(
      context: context,
      builder: (_) => _ReenterKeyDialog(name: savedKey.name),
    );
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

/// The values collected by [_AddKeyDialog].
class _AddKeyInput {
  const _AddKeyInput({required this.name, required this.pem, this.passphrase});
  final String name;
  final String pem;
  final String? passphrase;
}

/// Add-key dialog: name + pasted PEM + optional passphrase. The PEM is a key
/// blob so it is shown in a plain multiline field (not obscured), but it is
/// NEVER logged — it goes straight to the vault via the manager.
class _AddKeyDialog extends StatefulWidget {
  const _AddKeyDialog();

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  final _nameCtrl = TextEditingController();
  final _pemCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pemCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pem = _pemCtrl.text.trim();
    if (pem.isEmpty) {
      showTopToast(context, 'Paste a private key');
      return;
    }
    final passphrase = _passphraseCtrl.text;
    Navigator.of(context).pop(
      _AddKeyInput(
        name: _nameCtrl.text,
        pem: pem,
        passphrase: passphrase.isEmpty ? null : passphrase,
      ),
    );
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
            TextField(
              key: const ValueKey('keys-add-passphrase'),
              controller: _passphraseCtrl,
              decoration: const InputDecoration(
                labelText: 'Passphrase (optional)',
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
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
          key: const ValueKey('keys-add-save'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// The values collected by [_ReenterKeyDialog].
class _ReenterKeyInput {
  const _ReenterKeyInput({required this.pem, this.passphrase});
  final String pem;
  final String? passphrase;
}

/// Re-enter dialog (#1121): paste the private material for an EXISTING named
/// key. No name field — the identity stays; the vault entry is restored under
/// the key's same vault id, healing every profile attached to it.
class _ReenterKeyDialog extends StatefulWidget {
  const _ReenterKeyDialog({required this.name});

  final String name;

  @override
  State<_ReenterKeyDialog> createState() => _ReenterKeyDialogState();
}

class _ReenterKeyDialogState extends State<_ReenterKeyDialog> {
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
      _ReenterKeyInput(
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
            TextField(
              key: const ValueKey('keys-reenter-passphrase'),
              controller: _passphraseCtrl,
              decoration: const InputDecoration(
                labelText: 'Passphrase (optional)',
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
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
