// Connect form — host/port/username/password (or key) + Submit.
//
// Phase 1 (#501): no profiles, no persistence. Submit calls the SshSession
// controller; UI mirrors lifecycle state below the form.
//
// Profile import (Phase 3 of #501): saved profiles rendered above the form;
// tapping one populates host/port/username (user still types credentials).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/crash_reporter.dart';

import '../ssh/ssh_connect_params.dart';
import '../ssh/ssh_session.dart';
import '../state/connection_providers.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../storage/profiles_store.dart';
import 'diagnostics_section.dart';
import 'host_key_dialog.dart';
import 'import_profiles_dialog.dart';
import 'profile_list.dart';
import 'settings_panel.dart';

enum _AuthKind { password, key }

class ConnectForm extends ConsumerStatefulWidget {
  const ConnectForm({super.key});

  @override
  ConsumerState<ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends ConsumerState<ConnectForm> {
  final _hostCtrl = TextEditingController(text: 'test-sshd');
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController(text: 'testuser');
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  _AuthKind _authKind = _AuthKind.password;
  bool _busy = false;

  /// Last saved profile applied to the form, if any. Carries the human title
  /// through to the session (#518). Cleared (effectively) by drift-checking
  /// host/port/username at submit time so the title doesn't lie about the
  /// connection target.
  SavedProfile? _appliedProfile;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch for host-key prompts; show dialog when one appears.
    ref.listen<AsyncValue<SshSessionData>>(sshSessionDataProvider,
        (prev, next) {
      final pending = next.valueOrNull?.pendingHostKey;
      final prevPending = prev?.valueOrNull?.pendingHostKey;
      if (pending != null && prevPending == null) {
        _handleHostKeyPrompt(pending);
      }
    });

    final data = ref.watch(sshSessionDataProvider).valueOrNull ??
        const SshSessionData();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Saved profiles + import action. Collapsed-to-empty-hint when the
          // user has no imported profiles yet.
          ProfileList(onSelect: _applyProfileToForm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('open-import-profiles-dialog'),
              onPressed: _openImportDialog,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Import from PWA'),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostCtrl,
                  decoration: const InputDecoration(labelText: 'Host'),
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _portCtrl,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(labelText: 'Username'),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          SegmentedButton<_AuthKind>(
            segments: const [
              ButtonSegment(
                value: _AuthKind.password,
                label: Text('Password'),
                icon: Icon(Icons.password),
              ),
              ButtonSegment(
                value: _AuthKind.key,
                label: Text('Key'),
                icon: Icon(Icons.vpn_key),
              ),
            ],
            selected: {_authKind},
            onSelectionChanged: (s) =>
                setState(() => _authKind = s.first),
          ),
          const SizedBox(height: 8),
          if (_authKind == _AuthKind.password)
            TextField(
              controller: _passwordCtrl,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            )
          else ...[
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Private key (PEM)',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
              ),
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passphraseCtrl,
              decoration:
                  const InputDecoration(labelText: 'Key passphrase (optional)'),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _canSubmit(data) ? () => _submit() : null,
            icon: const Icon(Icons.power_settings_new),
            label: Text(_busy ? 'Connecting...' : 'Connect'),
          ),
          const SizedBox(height: 4),
          if (data.state == SshSessionState.connected)
            OutlinedButton.icon(
              onPressed: () =>
                  ref.read(sshSessionProxyProvider).disconnect(),
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
            ),
          const SizedBox(height: 8),
          const SettingsPanel(),
          const DiagnosticsSection(),
        ],
      ),
    );
  }

  bool _canSubmit(SshSessionData data) {
    switch (data.state) {
      case SshSessionState.connecting:
      case SshSessionState.authenticating:
      case SshSessionState.awaitingHostKey:
      case SshSessionState.connected:
      case SshSessionState.reconnecting:
        return false;
      case SshSessionState.idle:
      case SshSessionState.failed:
      case SshSessionState.disconnected:
        return !_busy;
    }
  }

  Future<void> _submit() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    final username = _userCtrl.text.trim();

    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Host and username are required')),
      );
      return;
    }

    final SshAuth auth;
    if (_authKind == _AuthKind.password) {
      auth = SshAuth.password(_passwordCtrl.text);
    } else {
      auth = SshAuth.key(
        Uint8List.fromList(utf8.encode(_keyCtrl.text)),
        passphrase: _passphraseCtrl.text.isEmpty ? null : _passphraseCtrl.text,
      );
    }

    final params = SshConnectParams(
      host: host,
      port: port,
      username: username,
      auth: auth,
    );

    setState(() => _busy = true);
    try {
      // Multi-session (#511): route through the sessions notifier so we
      // dedupe by host:port:user and create a per-session proxy. If a
      // matching session already exists, addOrActivate returns it without
      // reconnecting (acceptance bullet 4). The optional title carries the
      // saved profile's display name into the session (#518).
      //
      // #533: connect now dispatches across the task gateway via the per-
      // session [SshSessionProxy] — the underlying `SshSessionController`
      // lives in the task isolate, not the UI.
      final title = _profileTitleForCurrentForm();
      final entry = ref
          .read(sessionsProvider.notifier)
          .addOrActivate(params, title: title);
      // Only fire connect for entries that haven't been kicked off yet —
      // idle/failed/disconnected states are safe to re-drive; connected/
      // connecting/authenticating are no-ops inside the task-side controller
      // itself.
      await entry.proxy.connect(params);
      // Once we've proven we have network reachability, fire-and-forget a
      // crash upload sweep. Tailscale being down is the common case at boot
      // and the second-chance path matters more than blocking the UI.
      unawaited(CrashReporter.uploadPending());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Populate the form with metadata from a saved profile. When the
  /// profile has a `vaultId` or `keyVaultId`, look up the decrypted secret
  /// in `flutter_secure_storage` and prefill the password / key fields.
  /// The user can still edit them before submitting.
  ///
  /// Both ids are consulted because a `key`-auth profile imported from the
  /// PWA stores the private-key blob under `keyVaultId`, not `vaultId`
  /// (#519).
  void _applyProfileToForm(SavedProfile profile) {
    setState(() {
      _appliedProfile = profile;
      _hostCtrl.text = profile.host;
      _portCtrl.text = profile.port.toString();
      _userCtrl.text = profile.username;
      if (profile.authType == 'key') {
        _authKind = _AuthKind.key;
      } else if (profile.authType == 'password') {
        _authKind = _AuthKind.password;
      }
    });
    if (profile.vaultId != null || profile.keyVaultId != null) {
      unawaited(_prefillFromVault(profile));
    }
  }

  /// Return the saved profile title to attach to the new session — but only
  /// if the user hasn't drifted away from the applied profile's host/port/
  /// username. If they've edited anything, return null so the session falls
  /// back to `username@host:port` (#518).
  String? _profileTitleForCurrentForm() {
    final p = _appliedProfile;
    if (p == null) return null;
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    final username = _userCtrl.text.trim();
    if (p.host == host && p.port == port && p.username == username) {
      return p.title;
    }
    return null;
  }

  Future<void> _prefillFromVault(SavedProfile profile) async {
    final secrets = ref.read(secretsStoreProvider);
    final creds = await loadProfileCredentials(secrets, profile);
    if (!mounted || creds.isEmpty) return;
    setState(() {
      final pw = creds.password;
      if (pw != null) _passwordCtrl.text = pw;
      final key = creds.privateKey;
      if (key != null) {
        _keyCtrl.text = key;
        _authKind = _AuthKind.key;
      }
      final passphrase = creds.passphrase;
      if (passphrase != null) _passphraseCtrl.text = passphrase;
    });
  }

  Future<void> _openImportDialog() async {
    final result = await showImportProfilesDialog(context);
    if (!mounted || result == null) return;
    final msg = result.added > 0
        ? 'Imported ${result.added} profile${result.added == 1 ? '' : 's'}'
            '${result.skipped > 0 ? ', ${result.skipped} skipped (duplicate)' : ''}'
        : result.skipped > 0
            ? 'No new profiles — all ${result.skipped} were already saved.'
            : 'No profiles imported.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _handleHostKeyPrompt(PendingHostKey pending) async {
    final accepted = await showHostKeyDialog(context, pending: pending);
    // #533: host-key over-IPC is a follow-up — the proxy's accept/reject
    // are no-ops today because the gateway envelope contract doesn't carry
    // `pendingHostKey` state. The trust-on-first-use cache in the task-side
    // controller handles cached fingerprints; first-time prompts surface
    // through the dialog but the decision currently round-trips only through
    // the in-process host. See [SshSessionProxy.acceptHostKey].
    final proxy = ref.read(sshSessionProxyProvider);
    if (accepted) {
      proxy.acceptHostKey();
    } else {
      proxy.rejectHostKey();
    }
  }
}
