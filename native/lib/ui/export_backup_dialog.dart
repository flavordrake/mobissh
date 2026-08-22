// Export-backup dialog (#1124) — the encrypted full-backup EXPORT path.
//
// Flow: passphrase + confirm (obscured, validated via
// `validateBackupPassphrase` + equality) → gather the payload
// (`buildBackupPayload`; an unreadable-secrets abort surfaces its error
// in-dialog) → encrypt (`encryptBackupEnvelope` wrapped in `Isolate.run` —
// Argon2id at 19 MiB is CPU-heavy, must not jank the UI thread) → save via
// the SAF create-document adapter. The save seam only ever sees CIPHERTEXT:
// the envelope JSON bytes, nothing else.
//
// Seams (all injectable for tests): payload builder, encryptor, save adapter,
// clock. Production defaults wire the real stores, Isolate.run + default KDF,
// and the `mobissh/storage_picker` MethodChannel (`createDocumentBytes`,
// mirroring `pickJsonBytes` in MainActivity.kt / FilePickerAdapter in
// import_profiles_dialog.dart).

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ssh/host_key_store.dart';
import '../state/recent_sessions.dart';
import '../storage/backup.dart';
import '../storage/backup_payload.dart';
import '../storage/custom_patterns_store.dart';
import '../storage/detection_exceptions_store.dart';
import '../storage/detection_styles_store.dart';
import '../storage/favorites_store.dart';
import '../storage/keys_store.dart';
import '../storage/profiles_store.dart';
import '../storage/secrets_store.dart';
import 'revealable_field.dart';

/// Builds the plaintext payload once the passphrase is confirmed.
/// [allowMissing] is the user's explicit "export anyway without the
/// unreadable entries" opt-in (partial backup with an omissions manifest).
typedef BackupPayloadBuilder = Future<BackupPayloadResult> Function(
    {bool allowMissing});

/// Readability preflight run when the dialog OPENS (owner-directed: never ask
/// for a passphrase before knowing the export can be built).
typedef BackupPreflightRunner = Future<BackupPreflight> Function();

/// Encrypts [payload] under [passphrase] into envelope JSON.
typedef BackupEncryptor = Future<String> Function(
  Map<String, Object?> payload,
  String passphrase,
);

/// Abstraction over the platform "create document" save flow so tests can
/// supply a fake (mirrors `FilePickerAdapter` in import_profiles_dialog.dart).
abstract class BackupSaveAdapter {
  /// Open the SAF create-document UI suggesting [fileName] and write [bytes]
  /// to the chosen location. Returns true on success, false on user-cancel;
  /// throws on write failure.
  Future<bool> createDocument({
    required String fileName,
    required Uint8List bytes,
  });
}

/// Production adapter — calls the Kotlin `createDocumentBytes` handler on the
/// existing `mobissh/storage_picker` channel (MainActivity.kt).
class MethodChannelBackupSaveAdapter implements BackupSaveAdapter {
  const MethodChannelBackupSaveAdapter();

  static const _channel = MethodChannel('mobissh/storage_picker');

  @override
  Future<bool> createDocument({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final ok = await _channel.invokeMethod<bool>('createDocumentBytes', {
      'name': fileName,
      'bytes': bytes,
    });
    return ok ?? false;
  }
}

/// Suggested backup filename: `mobissh-backup-<yyyyMMdd-HHmmss>.mobissh`.
String backupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'mobissh-backup-'
      '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}.mobissh';
}

/// Production payload builder: real stores over the shared prefs instance,
/// app version from package_info (best-effort — an unresolvable version must
/// never block a credential backup).
Future<BackupPayloadResult> productionBackupPayload(
    {bool allowMissing = false}) async {
  final prefs = await SharedPreferences.getInstance();
  var appVersion = '';
  try {
    final pkg = await PackageInfo.fromPlatform();
    appVersion = '${pkg.version}+${pkg.buildNumber}';
  } catch (_) {
    // No platform channel (tests) or lookup failure — export without it.
  }
  return buildBackupPayload(
    profiles: ProfilesStore(prefs: prefs),
    keys: KeysStore(prefs: prefs),
    secrets: SecretsStore(),
    hostKeys: SharedPrefsHostKeyBackend(prefs: prefs),
    recents: RecentSessionsStore(prefs: prefs),
    favorites: FavoritesStore(prefs: prefs),
    detectionExceptions: DetectionExceptionsStore(prefs: prefs),
    customPatterns: CustomPatternsStore(prefs: prefs),
    detectionStyles: DetectionStylesStore(prefs: prefs),
    prefs: prefs,
    appVersion: appVersion,
    allowMissing: allowMissing,
  );
}

/// Production preflight: classification only, values discarded on read.
Future<BackupPreflight> productionBackupPreflight() async {
  final prefs = await SharedPreferences.getInstance();
  return preflightBackup(
    profiles: ProfilesStore(prefs: prefs),
    keys: KeysStore(prefs: prefs),
    secrets: SecretsStore(),
  );
}

/// Production encryptor: default (OWASP-minimum) KDF, off the UI thread.
Future<String> isolateBackupEncryptor(
  Map<String, Object?> payload,
  String passphrase,
) {
  return Isolate.run(
    () => encryptBackupEnvelope(payload: payload, passphrase: passphrase),
  );
}

/// Show the export dialog. Resolves true when a backup file was saved.
Future<bool?> showExportBackupDialog(
  BuildContext context, {
  BackupPayloadBuilder payloadBuilder = productionBackupPayload,
  BackupPreflightRunner preflight = productionBackupPreflight,
  BackupEncryptor encryptor = isolateBackupEncryptor,
  BackupSaveAdapter saveAdapter = const MethodChannelBackupSaveAdapter(),
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => ExportBackupDialog(
      payloadBuilder: payloadBuilder,
      preflight: preflight,
      encryptor: encryptor,
      saveAdapter: saveAdapter,
    ),
  );
}

class ExportBackupDialog extends StatefulWidget {
  const ExportBackupDialog({
    super.key,
    this.payloadBuilder = productionBackupPayload,
    this.preflight = productionBackupPreflight,
    this.encryptor = isolateBackupEncryptor,
    this.saveAdapter = const MethodChannelBackupSaveAdapter(),
    this.now,
  });

  final BackupPayloadBuilder payloadBuilder;
  final BackupPreflightRunner preflight;
  final BackupEncryptor encryptor;
  final BackupSaveAdapter saveAdapter;

  /// Clock override for the suggested filename (tests).
  final DateTime Function()? now;

  @override
  State<ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<ExportBackupDialog> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;
  bool _busy = false;

  /// Readability preflight, run on OPEN (owner-directed: never ask for a
  /// passphrase before knowing the export can be built). Null while running.
  BackupPreflight? _preflight;
  bool _preflightFailed = false;

  /// The explicit "export anyway without the unreadable entries" opt-in.
  bool _skipUnreadable = false;

  @override
  void initState() {
    super.initState();
    _runPreflight();
  }

  Future<void> _runPreflight() async {
    try {
      final p = await widget.preflight();
      if (!mounted) return;
      setState(() => _preflight = p);
    } catch (_) {
      if (!mounted) return;
      setState(() => _preflightFailed = true);
    }
  }

  /// Passphrase entry unlocks only when the export is known buildable: clean
  /// preflight, or unreadables explicitly skipped.
  bool get _ready {
    final p = _preflight;
    if (p == null) return false;
    return p.clean || _skipUnreadable;
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pass = _passCtrl.text;
    final policy = validateBackupPassphrase(pass);
    if (policy != null) {
      setState(() => _error = policy);
      return;
    }
    if (_confirmCtrl.text != pass) {
      setState(() => _error = 'Passphrases do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Plaintext is gathered ONLY now, after the passphrase is confirmed,
      // and handed straight to the encryptor. allowMissing carries the
      // user's explicit skip-unreadable opt-in from the preflight stage.
      final result = await widget.payloadBuilder(allowMissing: _skipUnreadable);
      final payload = result.payload;
      if (payload == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = result.error ?? 'Export failed.';
        });
        return;
      }
      final envelope = await widget.encryptor(payload, pass);
      final fileName = backupFileName(widget.now?.call() ?? DateTime.now());
      final saved = await widget.saveAdapter.createDocument(
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(envelope)),
      );
      if (!mounted) return;
      if (!saved) {
        // User cancelled the SAF picker — nothing written, dialog stays open.
        setState(() => _busy = false);
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      final skipped = result.omittedLabels.length;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Backup saved (${result.profileCount} profiles, '
            '${result.keyCount} keys'
            '${skipped > 0 ? '; $skipped credential${skipped == 1 ? '' : 's'} skipped' : ''})',
          ),
        ),
      );
    } on PlatformException {
      // Deliberately message-free: a platform error string could embed a
      // path, never a secret — but keep it generic anyway.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not write the backup file.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Export failed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _preflight;
    return AlertDialog(
      key: const Key('export-backup-dialog'),
      title: const Text('Export encrypted backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The backup file contains ALL profiles, passwords and SSH keys, '
              'encrypted with this passphrase. If you lose the passphrase the '
              'file cannot be read — there is no recovery. A few random words '
              'make a strong passphrase.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // ── Preflight stage: know the export is buildable BEFORE asking
            //    for a passphrase (owner-directed). ─────────────────────────
            if (_preflightFailed)
              Text(
                'Could not check stored credentials — try again.',
                key: const Key('export-backup-preflight-error'),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (p == null)
              const Row(
                key: Key('export-backup-preflight-running'),
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Checking stored credentials…'),
                ],
              )
            else if (p.clean)
              Text(
                'Ready: ${p.profileCount} profiles, ${p.keyCount} keys, '
                '${p.readableSecretCount} stored credentials.',
                key: const Key('export-backup-preflight-ok'),
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                '${p.unreadableLabels.length} stored '
                'credential${p.unreadableLabels.length == 1 ? '' : 's'} '
                "can't be read: ${p.unreadableLabels.take(6).join('; ')}"
                '${p.unreadableLabels.length > 6 ? '; …and ${p.unreadableLabels.length - 6} more' : ''}. '
                'Re-enter them first for a complete backup, or export '
                'without them.',
                key: const Key('export-backup-preflight-unreadable'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              CheckboxListTile(
                key: const Key('export-skip-unreadable'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _skipUnreadable,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _skipUnreadable = v ?? false),
                title: const Text(
                  'Export anyway without these — the affected profiles will '
                  'need their credentials re-entered after import',
                ),
              ),
            ],
            // ── Passphrase stage: only once the export is known buildable. ──
            if (_ready) ...[
              const SizedBox(height: 12),
              RevealableTextField(
                fieldKeyName: 'export-backup-passphrase',
                controller: _passCtrl,
                enabled: !_busy,
                labelText: 'Passphrase',
              ),
              const SizedBox(height: 8),
              RevealableTextField(
                fieldKeyName: 'export-backup-confirm',
                controller: _confirmCtrl,
                enabled: !_busy,
                labelText: 'Confirm passphrase',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('export-backup-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('export-backup-submit'),
          onPressed: (_busy || !_ready) ? null : _submit,
          child: Text(_busy ? 'Exporting…' : 'Export'),
        ),
      ],
    );
  }
}
