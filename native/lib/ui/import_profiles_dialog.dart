// "Import from PWA" dialog (#501, vault decrypt for #510).
//
// Two-stage flow:
//   1. User pastes JSON. Submit triggers a sync parse.
//   2. If the parsed envelope carries `vault.encrypted`+`vault.meta`, an
//      additional password field appears (same dialog). Submit then
//      decrypts + persists.
//   3. Plain envelope (no vault) → single Submit path, same as before.
//
// On success: returns the [ImportResult] so the caller can show a snackbar.
// On parse failure / wrong password / unknown shape: shows the error
// in-dialog without closing, so the user can fix the input and retry.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/profiles_providers.dart';
import '../storage/profiles_store.dart';

/// Show the import dialog. Resolves to the [ImportResult] on success, or
/// `null` if the user cancelled. Tests can construct
/// [ImportProfilesDialog] directly instead of going through this helper.
Future<ImportResult?> showImportProfilesDialog(BuildContext context) {
  return showDialog<ImportResult>(
    context: context,
    builder: (_) => const ImportProfilesDialog(),
  );
}

class ImportProfilesDialog extends ConsumerStatefulWidget {
  const ImportProfilesDialog({super.key});

  @override
  ConsumerState<ImportProfilesDialog> createState() =>
      _ImportProfilesDialogState();
}

class _ImportProfilesDialogState extends ConsumerState<ImportProfilesDialog> {
  final _jsonCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String? _error;
  bool _busy = false;

  // Stage 2: a parsed envelope carrying a vault. When non-null, the
  // password field is rendered and Submit applies with the password.
  ParsedImport? _pendingVault;

  @override
  void initState() {
    super.initState();
    _jsonCtrl.addListener(_onTextChanged);
    _passwordCtrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _jsonCtrl.removeListener(_onTextChanged);
    _passwordCtrl.removeListener(_onTextChanged);
    _jsonCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final store = ref.read(profilesStoreProvider);
    final secrets = ref.read(secretsStoreProvider);

    // Stage 2: already have a vault parse; this submit carries the password.
    if (_pendingVault != null) {
      final result = await store.applyParsedImport(
        _pendingVault!,
        password: _passwordCtrl.text,
        secrets: secrets,
      );
      if (!mounted) return;

      if (result.added == 0 && result.skipped == 0 && result.errors.isNotEmpty) {
        setState(() {
          _busy = false;
          _error = result.errors.first;
        });
        return;
      }
      if (result.added > 0) {
        ref.invalidate(savedProfilesProvider);
      }
      Navigator.of(context).pop(result);
      return;
    }

    // Stage 1: parse the pasted JSON. If it carries a vault, switch the
    // dialog into stage 2 (password prompt) without persisting anything.
    final parsed = ProfilesStore.parseImport(_jsonCtrl.text);
    if (parsed.hasVault) {
      setState(() {
        _busy = false;
        _pendingVault = parsed;
      });
      return;
    }

    // No vault: persist directly.
    final result = await store.applyParsedImport(parsed);
    if (!mounted) return;

    if (result.added == 0 && result.skipped == 0 && result.errors.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = result.errors.first;
      });
      return;
    }
    if (result.added > 0) {
      ref.invalidate(savedProfilesProvider);
    }
    Navigator.of(context).pop(result);
  }

  bool _canSubmit() {
    if (_busy) return false;
    if (_pendingVault != null) {
      return _passwordCtrl.text.isNotEmpty;
    }
    return _jsonCtrl.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final inVaultStage = _pendingVault != null;
    return AlertDialog(
      key: const Key('import-profiles-dialog'),
      title: Text(inVaultStage
          ? 'Unlock encrypted vault'
          : 'Import profiles from PWA'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!inVaultStage) ...[
              const Text(
                'Paste the JSON copied from the PWA "Export to native" button.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('import-profiles-input'),
                controller: _jsonCtrl,
                maxLines: 8,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  hintText: '{ "version": 1, "profiles": [ ... ] }',
                  border: OutlineInputBorder(),
                ),
              ),
            ] else ...[
              const Text(
                'This backup is encrypted. Enter the master password you set '
                'in the PWA to decrypt the saved credentials.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('import-profiles-password'),
                controller: _passwordCtrl,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) {
                  if (_canSubmit()) _submit();
                },
                decoration: const InputDecoration(
                  labelText: 'Master password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('import-profiles-error'),
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('import-profiles-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('import-profiles-submit'),
          onPressed: _canSubmit() ? _submit : null,
          child: Text(_busy
              ? 'Importing…'
              : (inVaultStage ? 'Unlock & import' : 'Import')),
        ),
      ],
    );
  }
}
