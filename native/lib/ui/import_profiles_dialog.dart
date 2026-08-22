// "Import backup" dialog (#501, vault decrypt for #510, file picker for #529,
// v2 encrypted backups for #1125).
//
// Primary affordance: "Choose backup file…" → opens Android Storage Access
// Framework via a custom MethodChannel (`mobissh/storage_picker`). The file's
// bytes are read by the Kotlin side and returned to Dart. The paste path
// stays as a collapsed disclosure ("Paste JSON instead") so the existing
// test/keyboard-driven flow keeps working.
//
// Why a custom channel instead of the `file_picker` package: see #529. Both
// `file_picker` 8.x and 11.x break the build in this project (AAR-metadata
// at 8.x; Flutter Built-in-Kotlin / KGP conflict at 11.x). The custom channel
// is ~30 LoC of Kotlin and bypasses the entire package toolchain.
//
// Two-stage flow:
//   1. User picks file OR pastes JSON. Submit triggers a sync parse.
//   2a. v1 vault envelope (`vault.encrypted`+`vault.meta`) → master-password
//       prompt; submit decrypts + persists (legacy path, unchanged).
//   2b. v2 encrypted backup (#1125) → passphrase prompt + the default-OFF
//       "restore auto-run commands and port forwards" checkbox; submit
//       decrypts (Isolate.run — Argon2id is CPU-heavy) and applies via
//       `applyBackupPayload`.
//   3. Plain envelope (no vault) → single Submit path.
//
// On success: returns the [ImportResult] so the caller can show a snackbar.
// On parse failure / wrong password / unknown shape: shows the error
// in-dialog without closing, so the user can fix the input and retry.

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/profiles_providers.dart';
import '../storage/backup.dart';
import '../storage/backup_restore.dart';
import '../storage/profiles_store.dart';
import 'revealable_field.dart';

/// Seam for the v2 envelope decrypt so widget tests can run it directly with
/// permissive KDF bounds — the production default wraps the strict-bounds
/// decrypt in [Isolate.run] (Argon2id at 19 MiB must not jank the UI thread).
typedef BackupEnvelopeDecryptor = Future<Map<String, Object?>> Function(
  String envelopeJson,
  String passphrase,
);

Future<Map<String, Object?>> _isolateBackupDecrypt(
  String envelopeJson,
  String passphrase,
) {
  return Isolate.run(
    () => decryptBackupEnvelope(
      envelopeJson: envelopeJson,
      passphrase: passphrase,
    ),
  );
}

/// Plain-data result of a file pick. Decoupled from the platform so the
/// widget test can inject a fake without binding to MethodChannel.
class PickedFile {
  PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Abstraction over the platform file picker so tests can supply a fake.
abstract class FilePickerAdapter {
  /// Open the storage picker filtered to JSON files. Returns the picked
  /// file's bytes + display name, or null if the user cancelled.
  Future<PickedFile?> pickJsonFile();
}

/// Production adapter — calls the Kotlin handler in `MainActivity` via the
/// `mobissh/storage_picker` channel. Returns a [PickedFile] with the
/// file's name and raw bytes.
class MethodChannelFilePickerAdapter implements FilePickerAdapter {
  const MethodChannelFilePickerAdapter();

  static const _channel = MethodChannel('mobissh/storage_picker');

  @override
  Future<PickedFile?> pickJsonFile() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickJsonBytes',
    );
    if (result == null) return null;
    final name = result['name'] as String? ?? 'backup.json';
    final bytes = result['bytes'] as Uint8List?;
    if (bytes == null) return null;
    return PickedFile(name: name, bytes: bytes);
  }
}

/// Show the import dialog. Resolves to the [ImportResult] on success, or
/// `null` if the user cancelled. Tests can construct
/// [ImportProfilesDialog] directly instead of going through this helper,
/// or pass a custom [pickerAdapter] to inject a fake.
Future<ImportResult?> showImportProfilesDialog(
  BuildContext context, {
  FilePickerAdapter pickerAdapter = const MethodChannelFilePickerAdapter(),
}) {
  return showDialog<ImportResult>(
    context: context,
    builder: (_) => ImportProfilesDialog(pickerAdapter: pickerAdapter),
  );
}

class ImportProfilesDialog extends ConsumerStatefulWidget {
  const ImportProfilesDialog({
    super.key,
    this.pickerAdapter = const MethodChannelFilePickerAdapter(),
    this.backupDecryptor = _isolateBackupDecrypt,
  });

  /// Adapter used to open the storage picker. Tests pass a fake.
  final FilePickerAdapter pickerAdapter;

  /// v2 envelope decrypt seam (#1125). Tests pass a direct call with
  /// permissive KDF bounds; production keeps the Isolate.run default.
  final BackupEnvelopeDecryptor backupDecryptor;

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

  // Set after a successful file pick. Drives a one-line summary so the user
  // can confirm the selection before tapping Import.
  String? _pickedFileName;
  String? _pickedSummary;

  // Stage 2 (v1): a parsed envelope carrying a vault. When non-null, the
  // password field is rendered and Submit applies with the password.
  ParsedImport? _pendingVault;

  // Stage 2 (v2, #1125): a parsed encrypted-backup envelope. When non-null,
  // the passphrase field + the restore-commands checkbox are rendered and
  // Submit decrypts + applies the full backup.
  ParsedImport? _pendingBackup;

  // #1125: default-OFF opt-in for restoring initialCommand + port forwards.
  bool _restoreCommands = false;

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
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not open file picker: ${e.message ?? e.code}';
      });
      return;
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

    _jsonCtrl.text = text;
    final summary = _summarize(text);
    setState(() {
      _busy = false;
      _pickedFileName = picked!.name;
      _pickedSummary = summary;
    });
  }

  /// One-line summary under `Selected: <name>`. Uses the same envelope-shape
  /// detection as `parseImport` so a wrong file is spotted before submit.
  String _summarize(String text) {
    final parsed = ProfilesStore.parseImport(text);
    // #1125: nothing about a v2 backup is readable pre-decrypt by design.
    if (parsed.isEncryptedBackup) return 'Encrypted MobiSSH backup';
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

    // Stage 2 (v2, #1125): decrypt the backup envelope with the passphrase,
    // then stage+apply the whole payload. ONE generic error for wrong
    // passphrase / tamper (no oracle).
    if (_pendingBackup != null) {
      final Map<String, Object?> payload;
      try {
        payload = await widget.backupDecryptor(
          _pendingBackup!.envelopeJson!,
          _passwordCtrl.text,
        );
      } on BackupException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = e.message;
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = kBackupGenericError;
        });
        return;
      }
      if (!mounted) return;
      final result = await applyBackupPayload(
        payload,
        secrets: secrets,
        restoreCommands: _restoreCommands,
      );
      if (!mounted) return;
      if (result.added == 0 && result.updated == 0 && result.errors.isNotEmpty) {
        setState(() {
          _busy = false;
          _error = result.errors.first;
        });
        return;
      }
      if (result.added > 0 || result.updated > 0) {
        ref.invalidate(savedProfilesProvider);
      }
      Navigator.of(context).pop(result);
      return;
    }

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
      if (result.added > 0 || result.updated > 0) {
        ref.invalidate(savedProfilesProvider);
      }
      Navigator.of(context).pop(result);
      return;
    }

    // Stage 1: parse the pasted/loaded JSON. If it carries a vault or is a
    // v2 encrypted backup, switch the dialog into stage 2 (password /
    // passphrase prompt) without persisting anything.
    final parsed = ProfilesStore.parseImport(_jsonCtrl.text);
    if (parsed.isEncryptedBackup) {
      setState(() {
        _busy = false;
        _pendingBackup = parsed;
      });
      return;
    }
    if (parsed.hasVault) {
      setState(() {
        _busy = false;
        _pendingVault = parsed;
      });
      return;
    }

    final result = await store.applyParsedImport(parsed);
    if (!mounted) return;

    if (result.added == 0 && result.skipped == 0 && result.errors.isNotEmpty) {
      setState(() {
        _busy = false;
        _error = result.errors.first;
      });
      return;
    }
    if (result.added > 0 || result.updated > 0) {
      ref.invalidate(savedProfilesProvider);
    }
    Navigator.of(context).pop(result);
  }

  bool _canSubmit() {
    if (_busy) return false;
    if (_pendingVault != null || _pendingBackup != null) {
      return _passwordCtrl.text.isNotEmpty;
    }
    return _jsonCtrl.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final inBackupStage = _pendingBackup != null;
    final inVaultStage = _pendingVault != null || inBackupStage;
    return AlertDialog(
      key: const Key('import-profiles-dialog'),
      // #1125: one title for every stage/format — the dialog still accepts v1
      // files, with no legacy-product wording.
      title: const Text('Import backup'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!inVaultStage) ...[
                FilledButton.icon(
                  key: const Key('import-profiles-pick-file'),
                  onPressed: _busy ? null : _pickFile,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Choose backup file…'),
                ),
                if (_pickedFileName != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Selected: $_pickedFileName',
                    key: const Key('import-profiles-picked-name'),
                  ),
                  if (_pickedSummary != null)
                    Text(
                      _pickedSummary!,
                      key: const Key('import-profiles-picked-summary'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
                const SizedBox(height: 8),
                ExpansionTile(
                  key: const Key('import-profiles-paste-disclosure'),
                  title: const Text('Paste JSON instead'),
                  initiallyExpanded: _pasteExpanded,
                  onExpansionChanged: (v) => setState(() => _pasteExpanded = v),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  tilePadding: EdgeInsets.zero,
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
              ] else ...[
                Text(inBackupStage
                    ? 'Encrypted MobiSSH backup — enter its passphrase.'
                    : 'Legacy encrypted profile export — enter its master '
                        'password.'),
                const SizedBox(height: 12),
                RevealableTextField(
                  fieldKeyName: 'import-profiles-password',
                  controller: _passwordCtrl,
                  onSubmitted: (_) {
                    if (_canSubmit()) _submit();
                  },
                  labelText: inBackupStage ? 'Passphrase' : 'Master password',
                  border: const OutlineInputBorder(),
                ),
                if (inBackupStage) ...[
                  const SizedBox(height: 4),
                  // #1125: auto-run commands + port forwards are an execution
                  // vector — restored only on explicit opt-in, default OFF.
                  CheckboxListTile(
                    key: const Key('import-restore-commands'),
                    value: _restoreCommands,
                    onChanged: _busy
                        ? null
                        : (v) =>
                            setState(() => _restoreCommands = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Also restore auto-run commands and port forwards '
                      '(only for backups you created)',
                    ),
                  ),
                ],
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
