// Profile editor (#579).
//
// Opened from a profile row's edit pencil ([ProfileList.onEdit]). Pre-populates
// every editable field of a [SavedProfile] — title, host, port, username,
// authType, initialCommand, theme, color — plus optional credential fields.
//
// Save semantics:
//   - Metadata (everything except credentials) is upserted into the
//     `profiles_store` by identity key (host:port:username). When the user
//     edits host/port/username the old entry is replaced (rename), matching the
//     import upsert behavior.
//   - Credential edits (password / private key / passphrase) NEVER touch the
//     profile JSON — they are written ONLY through the `secrets_store`/vault
//     path (Android-Keystore-backed flutter_secure_storage). A profile that
//     lacks a vault reference gets one minted on first credential save. Secrets
//     are never logged and never stored in shared_preferences (security rule).
//
// The editor is a modal route (full page) so it works on small screens with
// the keyboard up; tests can also pump it directly.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/connect_trace.dart';
import '../state/profiles_providers.dart';
import '../storage/profiles_store.dart';

enum _AuthKind { password, key }

/// Push the profile editor as a modal route. Resolves to `true` when the user
/// saved (caller should refresh the profile list), or `null`/`false` when they
/// cancelled / backed out.
Future<bool?> showProfileEditor(BuildContext context, SavedProfile profile) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => ProfileEditor(profile: profile),
    ),
  );
}

class ProfileEditor extends ConsumerStatefulWidget {
  const ProfileEditor({super.key, required this.profile});

  final SavedProfile profile;

  @override
  ConsumerState<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<ProfileEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _initialCommandCtrl;
  late final TextEditingController _themeCtrl;
  late final TextEditingController _colorCtrl;
  final _passwordCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();

  late _AuthKind _authKind;
  bool _busy = false;

  /// The identity key the editor opened on. Carried so a host/port/username
  /// edit replaces the original entry rather than creating a duplicate.
  late final String _originalIdentityKey;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _originalIdentityKey = p.identityKey;
    _titleCtrl = TextEditingController(text: p.title);
    _hostCtrl = TextEditingController(text: p.host);
    _portCtrl = TextEditingController(text: p.port.toString());
    _userCtrl = TextEditingController(text: p.username);
    _initialCommandCtrl = TextEditingController(text: p.initialCommand ?? '');
    _themeCtrl = TextEditingController(text: p.theme ?? '');
    _colorCtrl = TextEditingController(text: p.color ?? '');
    // Prefer the explicit authType; infer `key` when only a keyVaultId is
    // present (mirrors the connect form's inference for older profiles).
    if (p.authType == 'key') {
      _authKind = _AuthKind.key;
    } else if (p.authType == 'password') {
      _authKind = _AuthKind.password;
    } else if (p.keyVaultId != null && p.keyVaultId!.isNotEmpty) {
      _authKind = _AuthKind.key;
    } else {
      _authKind = _AuthKind.password;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _initialCommandCtrl.dispose();
    _themeCtrl.dispose();
    _colorCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  String? _emptyToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    final host = _hostCtrl.text.trim();
    final username = _userCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Host and username are required')),
      );
      return;
    }

    setState(() => _busy = true);

    final store = ref.read(profilesStoreProvider);
    final secrets = ref.read(secretsStoreProvider);
    final authType = _authKind == _AuthKind.password ? 'password' : 'key';

    // Resolve vault references. A profile that already has a vaultId/keyVaultId
    // keeps it; one that's about to gain credentials gets a fresh id minted
    // from its identity (stable for the same target so a re-edit overwrites the
    // same secret rather than orphaning blobs).
    var vaultId = widget.profile.vaultId;
    var keyVaultId = widget.profile.keyVaultId;

    final newIdentity = '$host:$port:$username';

    // Decide which credential fields the user actually entered. We NEVER log
    // the values — only whether each is present (length-free here; the connect
    // form already traces lengths). Writing goes solely through secrets_store.
    final pw = _passwordCtrl.text;
    final key = _keyCtrl.text;
    final passphrase = _passphraseCtrl.text;

    try {
      if (_authKind == _AuthKind.password && pw.isNotEmpty) {
        vaultId ??= 'profile-$newIdentity';
        await secrets.write(vaultId, <String, Object?>{
          'password': pw,
          if (passphrase.isNotEmpty) 'passphrase': passphrase,
        });
      } else if (_authKind == _AuthKind.key && key.isNotEmpty) {
        keyVaultId ??= 'profile-key-$newIdentity';
        // PWA canonical key entry shape: {data: <PEM>, passphrase?}.
        await secrets.write(keyVaultId, <String, Object?>{
          'data': key,
          if (passphrase.isNotEmpty) 'passphrase': passphrase,
        });
      } else if (_authKind == _AuthKind.key &&
          passphrase.isNotEmpty &&
          keyVaultId != null) {
        // Passphrase-only update on an existing stored key: merge it in without
        // requiring the user to re-paste the PEM.
        final existing = await secrets.read(keyVaultId);
        final merged = <String, Object?>{
          ...?existing,
          'passphrase': passphrase,
        };
        await secrets.write(keyVaultId, merged);
      }

      final updated = SavedProfile(
        title: _emptyToNull(_titleCtrl.text) ?? '$username@$host',
        host: host,
        port: port,
        username: username,
        theme: _emptyToNull(_themeCtrl.text),
        color: _emptyToNull(_colorCtrl.text),
        authType: authType,
        vaultId: vaultId,
        keyVaultId: keyVaultId,
        initialCommand: _emptyToNull(_initialCommandCtrl.text),
      );

      await store.upsert(updated, previousIdentityKey: _originalIdentityKey);
      ctrace(
        'ui.editor',
        'saved profile $newIdentity authType=$authType '
            'hasVaultId=${vaultId != null} hasKeyVaultId=${keyVaultId != null}',
      );
      ref.invalidate(savedProfilesProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final store = ref.read(profilesStoreProvider);
    final p = widget.profile;
    await store.remove(host: p.host, port: p.port, username: p.username);
    ref.invalidate(savedProfilesProvider);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isKey = _authKind == _AuthKind.key;
    return Scaffold(
      key: const Key('profile-editor'),
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          IconButton(
            key: const Key('profile-editor-delete'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete profile',
            onPressed: _busy ? null : _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('profile-editor-title'),
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Auto: user@host',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const Key('profile-editor-host'),
                      controller: _hostCtrl,
                      decoration: const InputDecoration(labelText: 'Host'),
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      key: const Key('profile-editor-port'),
                      controller: _portCtrl,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('profile-editor-username'),
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: 'Username'),
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
                onSelectionChanged: (s) => setState(() => _authKind = s.first),
              ),
              const SizedBox(height: 8),
              if (!isKey)
                TextField(
                  key: const Key('profile-editor-password'),
                  controller: _passwordCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    hintText: '(stored encrypted — leave blank to keep)',
                  ),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                )
              else ...[
                TextField(
                  key: const Key('profile-editor-key'),
                  controller: _keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Private key (PEM)',
                    hintText: '(stored encrypted — leave blank to keep)',
                  ),
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('profile-editor-passphrase'),
                  controller: _passphraseCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Key passphrase (optional)',
                  ),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('profile-editor-initial-command'),
                controller: _initialCommandCtrl,
                decoration: const InputDecoration(
                  labelText: 'Initial command (optional)',
                  hintText: 'e.g. tmux attach || tmux',
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('profile-editor-theme'),
                controller: _themeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Theme (optional)',
                  hintText: 'e.g. dark, solarizedDark',
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('profile-editor-color'),
                controller: _colorCtrl,
                decoration: const InputDecoration(
                  labelText: 'Color (optional)',
                  hintText: '#ff8800',
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('profile-editor-save'),
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_busy ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
