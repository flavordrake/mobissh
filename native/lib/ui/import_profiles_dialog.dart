// "Import from PWA" dialog (#501, vault decrypt for #510, file picker
// affordance for #520).
//
// Primary affordance: "Choose backup file…" → opens Android's storage
// picker (file_picker), reads the chosen JSON's bytes, drives the same
// parseImport/applyParsedImport pipeline as the paste path. The paste
// textarea remains as a collapsed disclosure ("Paste JSON instead") so
// power users and tests can still drive it directly.
//
// Two-stage flow (unchanged from #510):
//   1. User selects a file OR pastes JSON. Submit triggers a sync parse.
//   2. If the parsed envelope carries `vault.encrypted`+`vault.meta`, an
//      additional password field appears (same dialog). Submit then
//      decrypts + persists.
//   3. Plain envelope (no vault) → single Submit path, same as before.
//
// On success: returns the [ImportResult] so the caller can show a snackbar.
// On parse failure / wrong password / unknown shape: shows the error
// in-dialog without closing, so the user can fix the input and retry.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/profiles_providers.dart';
import '../storage/profiles_store.dart';

/// Plain-data result of a file pick. Decoupled from `file_picker` so the
/// widget test can inject a fake without binding to platform channels.
class PickedFile {
  PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Abstraction over `file_picker` so tests can supply a fake. Production
/// code uses [DefaultFilePickerAdapter]; widget tests construct
/// [ImportProfilesDialog] with a custom adapter via [showImportProfilesDialog]
/// (`pickerAdapter` parameter).
abstract class FilePickerAdapter {
  /// Open the storage picker filtered to JSON files. Returns the picked
  /// file's bytes + display name, or null if the user cancelled.
  Future<PickedFile?> pickJsonFile();
}

/// Real implementation that wraps `FilePicker.platform`.
class DefaultFilePickerAdapter implements FilePickerAdapter {
  const DefaultFilePickerAdapter();

  @override
  Future<PickedFile?> pickJsonFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return null;
    return PickedFile(name: file.name, bytes: bytes);
  }
}

/// Show the import dialog. Resolves to the [ImportResult] on success, or
/// `null` if the user cancelled. Tests can construct
/// [ImportProfilesDialog] directly instead of going through this helper,
/// or pass a custom [pickerAdapter] to inject a fake.
Future<ImportResult?> showImportProfilesDialog(
  BuildContext context, {
  FilePickerAdapter pickerAdapter = const DefaultFilePickerAdapter(),
}) {
  return showDialog<ImportResult>(
    context: context,
    builder: (_) => ImportProfilesDialog(pickerAdapter: pickerAdapter),
  );
}

class ImportProfilesDialog extends ConsumerStatefulWidget {
  const ImportProfilesDialog({
    super.key,
    this.pickerAdapter = const DefaultFilePickerAdapter(),
  });

  /// Adapter used to open the storage picker. Tests pass a fake.
  final FilePickerAdapter pickerAdapter;

  @override
  ConsumerState<ImportProfilesDialog> createState() =>
      _ImportProfilesDialogState();
}

class _ImportProfilesDialogState extends ConsumerState<ImportProfilesDialog> {
  final _jsonCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _pasteExpanded = false;

  // Set after a successful file pick. The bytes/name drive the import and
  // a one-line summary so the user can confirm the selection before tapping
  // Import.
  String? _pickedFileName;
  String? _pickedSummary;

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

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    PickedFile? picked;
    try {
      picked = await widget.pickerAdapter.pickJsonFile();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not open file picker: $e';
      });
      return;
    }
    if (!mounted) return;
    if (picked == null) {
      // User cancelled the picker — leave any prior selection intact.
      setState(() {
        _busy = false;
      });
      return;
    }

    String text;
    try {
      text = utf8.decode(picked.bytes);
    } on FormatException catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not read file as UTF-8 text: ${e.message}';
      });
      return;
    }

    // Drive both the underlying paste field (so Submit reuses one code path)
    // and a user-facing summary that's correct even when paste is collapsed.
    _jsonCtrl.text = text;
    final summary = _summarize(text);
    setState(() {
      _busy = false;
      _pickedFileName = picked!.name;
      _pickedSummary = summary;
    });
  }

  /// Build the one-line summary shown under `Selected: <name>`. Uses the
  /// same envelope-shape detection as `parseImport` so the user can spot
  /// a wrong file before tapping Import.
  String _summarize(String text) {
    final parsed = ProfilesStore.parseImport(text);
    if (parsed.profileEntries.isEmpty && parsed.errors.isNotEmpty) {
      return parsed.errors.first;
    }
    final n = parsed.profileEntries.length;
    final vault = parsed.hasVault ? 'vault present' : 'no vault';
    return '$n profile${n == 1 ? '' : 's'}, $vault';
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

    // Stage 1: parse the pasted/loaded JSON. If it carries a vault, switch
    // the dialog into stage 2 (password prompt) without persisting anything.
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            if (!inVaultStage) ...[
              const Text(
                'Choose the backup file the PWA downloaded, or paste the '
                'JSON copied from the PWA "Export to native" button.',
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('import-profiles-pick-file'),
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose backup file…'),
              ),
              if (_pickedFileName != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Selected: $_pickedFileName',
                  key: const Key('import-profiles-picked-name'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (_pickedSummary != null)
                  Text(
                    _pickedSummary!,
                    key: const Key('import-profiles-picked-summary'),
                    style: const TextStyle(color: Colors.white70),
                  ),
              ],
              const SizedBox(height: 12),
              // Paste textarea behind a disclosure — fallback path. Same key
              // as before (`import-profiles-input`) so existing tests work.
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                ),
                child: ExpansionTile(
                  key: const Key('import-profiles-paste-disclosure'),
                  initiallyExpanded: _pasteExpanded,
                  onExpansionChanged: (v) =>
                      setState(() => _pasteExpanded = v),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  title: const Text('Paste JSON instead'),
                  children: [
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
                  ],
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
