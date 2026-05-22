// "Import from PWA" dialog (#501).
//
// Accepts pasted JSON in the PWA export shape and merges into the store.
// On success: returns the [ImportResult] so the caller can show a snackbar.
// On parse failure or unknown shape: shows the error in-dialog without
// closing, so the user can fix the paste and retry.

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
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Rebuild on text changes so the Submit button's enabled state tracks
    // whether the paste field is empty.
    _ctrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final store = ref.read(profilesStoreProvider);
    final result = await store.importFromJson(_ctrl.text);
    if (!mounted) return;

    // If we got zero adds and zero skips with errors, treat as input error
    // and leave the dialog open so the user can fix the paste.
    if (result.added == 0 && result.skipped == 0 && result.errors.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = result.errors.first;
      });
      return;
    }

    // Invalidate the watcher so the parent list rebuilds.
    if (result.added > 0) {
      ref.invalidate(savedProfilesProvider);
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('import-profiles-dialog'),
      title: const Text('Import profiles from PWA'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the JSON copied from the PWA "Export to native" button.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('import-profiles-input'),
              controller: _ctrl,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                hintText: '{ "version": 1, "profiles": [ ... ] }',
                border: OutlineInputBorder(),
              ),
            ),
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
          onPressed: _busy || _ctrl.text.trim().isEmpty ? null : _submit,
          child: Text(_busy ? 'Importing…' : 'Import'),
        ),
      ],
    );
  }
}
