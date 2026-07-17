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
//
// Two tabs (profile-import goal): "Details" is the field form; "SSH config"
// accepts a pasted `~/.ssh/config` Host block, parses it (ssh_config_parser),
// and populates the Details fields — for quickly importing/updating a host. If
// the block names an IdentityFile the Details key area offers a stored key to
// reuse or a pasted secret (the file path itself can't be read from a phone).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/connect_trace.dart';
import '../ssh/ssh_config_parser.dart';
import '../state/profiles_providers.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart';
import 'color_picker_sheet.dart';
import 'top_toast.dart';

enum _AuthKind { password, key }

/// Where a key-auth profile's private key comes from: a freshly [pasted] PEM,
/// or a [stored] key already in the vault (reused by its keyVaultId, no
/// re-paste). Default [pasted] preserves the pre-import editor behavior.
enum _KeySource { pasted, stored }

/// Outcome of the profile editor (#583). The editor is now the SINGLE entry for
/// both editing a saved profile AND creating a new / ad-hoc connection — the
/// inline connect form on the home view was removed. The caller (the profile
/// chooser) inspects the result to decide whether to just refresh the list or
/// to also connect to the saved profile.
class ProfileEditorResult {
  const ProfileEditorResult({required this.saved, this.connect});

  /// True when the store was mutated (save or delete) — caller refreshes list.
  final bool saved;

  /// Non-null when the user chose "Save & connect": the profile to connect to.
  /// The chooser routes this through its shared connect path so the host-key
  /// prompt + initial-command arming run exactly as a profile-row tap does.
  final SavedProfile? connect;
}

/// Push the profile editor as a modal route to EDIT an existing profile.
/// Resolves to a [ProfileEditorResult] (`saved`/`connect`), or `null` when the
/// user backed out without saving.
Future<ProfileEditorResult?> showProfileEditor(
  BuildContext context,
  SavedProfile profile,
) {
  return Navigator.of(context).push<ProfileEditorResult>(
    MaterialPageRoute<ProfileEditorResult>(
      fullscreenDialog: true,
      builder: (_) => ProfileEditor(profile: profile),
    ),
  );
}

/// A blank profile used to open the editor in CREATE mode (#583). Sensible
/// defaults so the user starts on an empty form (host/username empty, port 22).
SavedProfile blankProfile() =>
    SavedProfile(title: '', host: '', port: 22, username: '');

/// Push the editor in CREATE mode for a brand-new / ad-hoc connection (#583).
/// This is the home view's "New" affordance: the editor IS the new-connection
/// entry now that the inline form is gone. Same return contract as
/// [showProfileEditor].
Future<ProfileEditorResult?> showProfileEditorForNew(BuildContext context) {
  return Navigator.of(context).push<ProfileEditorResult>(
    MaterialPageRoute<ProfileEditorResult>(
      fullscreenDialog: true,
      builder: (_) => ProfileEditor(profile: blankProfile(), isNew: true),
    ),
  );
}

class ProfileEditor extends ConsumerStatefulWidget {
  const ProfileEditor({super.key, required this.profile, this.isNew = false});

  final SavedProfile profile;

  /// When true the editor renders in CREATE mode: blank starting fields, no
  /// delete action, "Edit profile" → "New connection" title (#583).
  final bool isNew;

  @override
  ConsumerState<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<ProfileEditor>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _initialCommandCtrl;
  late final TextEditingController _defaultPathCtrl;
  late final TextEditingController _colorCtrl;

  /// Paste buffer for the "SSH config" tab.
  final _sshConfigCtrl = TextEditingController();

  /// Key source for key auth (profile-import goal). [_KeySource.stored] reuses
  /// [_selectedStoredKeyVaultId] without re-pasting; [_KeySource.pasted] uses
  /// the PEM field. Defaults to pasted (unchanged editor behavior).
  _KeySource _keySource = _KeySource.pasted;
  String? _selectedStoredKeyVaultId;

  /// The IdentityFile path from an imported config, shown as a hint in the key
  /// area (the phone can't read the file — it's guidance for which key to pick
  /// or paste). Null unless a parsed entry referenced one.
  String? _pendingIdentityFile;

  /// Selected theme = a PWA `ThemeName` key from [terminalPalettes] (#613). The
  /// editor shows the palette LABEL but stores the KEY into [SavedProfile.theme]
  /// so connect can map it back via [paletteIndexForThemeName]. Defaults to the
  /// profile's current theme key, falling back to the default palette key.
  late String _themeKey;
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
    _tabs = TabController(length: 2, vsync: this);
    final p = widget.profile;
    _originalIdentityKey = p.identityKey;
    _titleCtrl = TextEditingController(text: p.title);
    _hostCtrl = TextEditingController(text: p.host);
    _portCtrl = TextEditingController(text: p.port.toString());
    _userCtrl = TextEditingController(text: p.username);
    _initialCommandCtrl = TextEditingController(text: p.initialCommand ?? '');
    _defaultPathCtrl = TextEditingController(text: p.defaultPath);
    _colorCtrl = TextEditingController(text: p.color ?? '');
    // Seed the picker from the profile's stored theme key when it maps to a
    // known palette; otherwise fall back to the default palette's key.
    final known =
        p.theme != null && terminalPalettes.any((t) => t.key == p.theme);
    _themeKey = known ? p.theme! : terminalPalettes[terminalThemeDefault].key;
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
    _tabs.dispose();
    _sshConfigCtrl.dispose();
    _titleCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _initialCommandCtrl.dispose();
    _defaultPathCtrl.dispose();
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
    final saved = await _persist();
    if (saved == null || !mounted) return;
    Navigator.of(context).pop(const ProfileEditorResult(saved: true));
  }

  /// Save & connect (#583): persist the profile then hand it back to the
  /// chooser so it connects via the shared connect path (host-key prompt +
  /// initial-command arming included). The editor is the new-connection entry
  /// now that the inline form is gone.
  Future<void> _saveAndConnect() async {
    final saved = await _persist();
    if (saved == null || !mounted) return;
    Navigator.of(context).pop(ProfileEditorResult(saved: true, connect: saved));
  }

  /// Persist the current fields to the store + vault. Returns the saved
  /// profile on success, or null when validation failed (caller stays open).
  Future<SavedProfile?> _persist() async {
    final host = _hostCtrl.text.trim();
    final username = _userCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    if (host.isEmpty || username.isEmpty) {
      showTopToast(context, 'Host and username are required');
      return null;
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

    // Reusing an existing stored key (profile-import goal): point this profile
    // at the chosen key's vault id, writing NO new secret. Wins over the paste
    // path so the PEM field being blank doesn't matter.
    final reuseStoredKey = _authKind == _AuthKind.key &&
        _keySource == _KeySource.stored &&
        _selectedStoredKeyVaultId != null;
    if (reuseStoredKey) {
      keyVaultId = _selectedStoredKeyVaultId;
    }

    try {
      if (reuseStoredKey) {
        // No secret to write — the stored key already exists in the vault.
      } else if (_authKind == _AuthKind.password && pw.isNotEmpty) {
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
        theme: _themeKey,
        color: _emptyToNull(_colorCtrl.text),
        authType: authType,
        vaultId: vaultId,
        keyVaultId: keyVaultId,
        initialCommand: _emptyToNull(_initialCommandCtrl.text),
        // #891: optional file-browser starting dir. Trim; empty = SFTP home.
        defaultPath: _defaultPathCtrl.text.trim(),
      );

      await store.upsert(updated, previousIdentityKey: _originalIdentityKey);
      ctrace(
        'ui.editor',
        'saved profile $newIdentity authType=$authType '
            'hasVaultId=${vaultId != null} hasKeyVaultId=${keyVaultId != null}',
      );
      ref.invalidate(savedProfilesProvider);
      return updated;
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
    Navigator.of(context).pop(const ProfileEditorResult(saved: true));
  }

  @override
  Widget build(BuildContext context) {
    final isKey = _authKind == _AuthKind.key;
    // Keyboard height. We size and float the action bar against this ourselves
    // (resizeToAvoidBottomInset:false below) so the buttons stay directly above
    // the soft keyboard and remain hit-testable — the #585 session-menu pattern
    // applied to the editor footer (#594). A device-real keyboard occupies the
    // lower viewport; if the buttons lived at the bottom of the scrolling form
    // they'd sit behind it and ad-hoc connect would be unreachable.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      key: const Key('profile-editor'),
      // We manage the keyboard inset manually in the footer so the action bar
      // floats above the keyboard without the Scaffold also reserving for it
      // (which would double-count). The scroll body gets bottom padding to clear
      // both the keyboard and the fixed footer.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(widget.isNew ? 'New connection' : 'Edit profile'),
        actions: [
          // No delete in create mode — there's nothing persisted yet (#583).
          if (!widget.isNew)
            IconButton(
              key: const Key('profile-editor-delete'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete profile',
              onPressed: _busy ? null : _delete,
            ),
        ],
        // Two-tab box (profile-import goal): the field form vs a paste-an-ssh-
        // config surface. The shared action footer (Save / Save&connect) lives
        // outside the tabs so it applies to whichever tab filled the fields.
        bottom: TabBar(
          key: const Key('profile-editor-tabs'),
          controller: _tabs,
          tabs: const [
            Tab(key: Key('profile-editor-tab-details'), text: 'Details'),
            Tab(key: Key('profile-editor-tab-sshconfig'), text: 'SSH config'),
          ],
        ),
      ),
      // Fixed action footer (#594). Floats above the keyboard via the
      // viewInsets padding so Save & Save&connect are always reachable with the
      // keyboard up. Mirrors the PWA editor where the connect/save action is
      // always reachable.
      bottomNavigationBar: _ActionBar(
        key: const Key('profile-editor-action-bar'),
        busy: _busy,
        keyboardInset: keyboardInset,
        onConnect: _busy ? null : _saveAndConnect,
        onSave: _busy ? null : _save,
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabs,
          children: [
            _buildDetailsTab(context, keyboardInset, isKey),
            _buildSshConfigTab(context, keyboardInset),
          ],
        ),
      ),
    );
  }

  /// The "Details" tab — the field form. Extracted from [build] unchanged so
  /// the two-tab restructure is a wrap, not a rewrite.
  Widget _buildDetailsTab(
    BuildContext context,
    double keyboardInset,
    bool isKey,
  ) {
    return SingleChildScrollView(
          // Bottom padding clears the keyboard AND the fixed action footer so
          // the last field can scroll into the keyboard-free area.
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + keyboardInset + 120),
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
              else
                ..._buildKeyAuthFields(context),
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
              // #891: optional file-browser starting directory. Empty = SFTP
              // home (current behaviour). Crucial for VPS/seedbox hosts where
              // the home dir isn't where you work (e.g. `/files`).
              TextField(
                key: const Key('profile-editor-default-path'),
                controller: _defaultPathCtrl,
                decoration: const InputDecoration(
                  labelText: 'Default directory (optional)',
                  hintText: 'e.g. /files or ~/downloads',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              // #613: theme PICKER over the full ported palette set. Shows the
              // palette label; stores the PWA theme KEY into SavedProfile.theme
              // so connect maps it back via paletteIndexForThemeName.
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Theme',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const Key('profile-editor-theme-picker'),
                    isExpanded: true,
                    value: _themeKey,
                    items: [
                      for (final palette in terminalPalettes)
                        DropdownMenuItem<String>(
                          value: palette.key,
                          child: Text(palette.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _themeKey = value);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // #1030: first-class color section. One-tap preset chips + the
              // shared picker sheet for custom colors. The hex field stays the
              // backing value (same key + controller) so the save path and
              // existing tests are unchanged — presets/picker just write it.
              _ColorSection(controller: _colorCtrl),
            ],
          ),
        );
  }

  /// Sentinel value for the "Paste a new key…" option in the key-source
  /// dropdown (a DropdownButton needs a non-null value per item).
  static const String _pasteKeySentinel = '__paste_new_key__';

  /// The key-auth fields: an optional "Key source" dropdown to reuse a stored
  /// key, an IdentityFile hint from an imported config, and either a
  /// stored-key note (reuse) or the PEM + passphrase paste fields.
  List<Widget> _buildKeyAuthFields(BuildContext context) {
    final storedKeys =
        ref.watch(storedKeysProvider).asData?.value ?? const <StoredKeyRef>[];
    return [
      if (storedKeys.isNotEmpty) ...[
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Key source',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const Key('profile-editor-key-source'),
              isExpanded: true,
              value: _keySource == _KeySource.stored
                  ? _selectedStoredKeyVaultId
                  : _pasteKeySentinel,
              items: [
                const DropdownMenuItem<String>(
                  value: _pasteKeySentinel,
                  child: Text('Paste a new key…'),
                ),
                for (final k in storedKeys)
                  DropdownMenuItem<String>(
                    value: k.keyVaultId,
                    child: Text('Stored: ${k.label}'),
                  ),
              ],
              onChanged: (v) => setState(() {
                if (v == null || v == _pasteKeySentinel) {
                  _keySource = _KeySource.pasted;
                  _selectedStoredKeyVaultId = null;
                } else {
                  _keySource = _KeySource.stored;
                  _selectedStoredKeyVaultId = v;
                }
              }),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (_pendingIdentityFile != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Config referenced key file: $_pendingIdentityFile\n'
            "This device can't read that file — pick a stored key above or "
            'paste its contents below.',
            key: const Key('profile-editor-identityfile-hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (_keySource == _KeySource.stored)
        ListTile(
          key: const Key('profile-editor-stored-key-note'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.vpn_key),
          title: const Text('Using a stored key'),
          subtitle: Text(_storedKeyLabel(storedKeys, _selectedStoredKeyVaultId)),
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
    ];
  }

  String _storedKeyLabel(List<StoredKeyRef> keys, String? id) {
    for (final k in keys) {
      if (k.keyVaultId == id) return k.label;
    }
    return id ?? '';
  }

  /// The "SSH config" tab — two directions. Top: the CURRENT profile rendered
  /// as a copy-ready `~/.ssh/config` Host block (export). Bottom: paste a block
  /// to fill the Details fields (import).
  Widget _buildSshConfigTab(BuildContext context, double keyboardInset) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + keyboardInset + 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This profile as an SSH config entry',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          // Live: rebuild the block as the Details fields change so the export
          // always reflects the current settings. authType/IdentityFile changes
          // arrive via parent setState (which recreates this builder).
          ListenableBuilder(
            listenable: Listenable.merge(
              [_titleCtrl, _hostCtrl, _portCtrl, _userCtrl],
            ),
            builder: (context, _) => _buildSshConfigExport(context),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            'Paste an entry from ~/.ssh/config to fill the Details fields '
            '(host, port, user). If it names an IdentityFile you can reuse a '
            'stored key or paste the secret on the Details tab.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('profile-editor-sshconfig-input'),
            controller: _sshConfigCtrl,
            decoration: const InputDecoration(
              labelText: 'SSH config entry',
              hintText: 'Host prod\n'
                  '  HostName prod.example.com\n'
                  '  User deploy\n'
                  '  IdentityFile ~/.ssh/id_ed25519',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 8,
            minLines: 5,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('profile-editor-sshconfig-apply'),
            onPressed: _applySshConfig,
            icon: const Icon(Icons.download_done),
            label: const Text('Parse & fill Details'),
          ),
        ],
      ),
    );
  }

  /// The export block: the current Details fields as a copy-ready ssh-config
  /// Host stanza, plus a Copy button. Empty until a host is entered (an empty
  /// host makes the block useless — round-trips to nothing).
  Widget _buildSshConfigExport(BuildContext context) {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      return Text(
        'Add a host on the Details tab to generate a config entry.',
        key: const Key('profile-editor-sshconfig-export-empty'),
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    // IdentityFile is a hint only — emit it when key auth and a config named a
    // path (the phone never stores a file path; keys live in the vault).
    final identityFile =
        _authKind == _AuthKind.key ? _pendingIdentityFile : null;
    final block = formatSshConfig(
      alias: _configAlias(_titleCtrl.text, host),
      host: host,
      port: port,
      user: _userCtrl.text,
      identityFile: identityFile,
    );
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: SelectableText(
            block,
            key: const Key('profile-editor-sshconfig-export'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const Key('profile-editor-sshconfig-copy'),
            onPressed: () => _copySshConfig(block),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }

  /// The `Host` alias for the generated config: the profile Name when it's a
  /// single clean token (usable as `ssh <alias>`), else the hostname. A name
  /// like `deploy@prod` or one with spaces isn't a valid alias, so fall back.
  String _configAlias(String title, String host) {
    final t = title.trim();
    if (t.isNotEmpty && !t.contains(RegExp(r'\s')) && !t.contains('@')) {
      return t;
    }
    return host;
  }

  Future<void> _copySshConfig(String block) async {
    await Clipboard.setData(ClipboardData(text: block));
    if (!mounted) return;
    showTopToast(context, 'Copied SSH config entry');
  }

  /// Parse the pasted config and fill Details. One concrete host → apply it;
  /// several → let the user choose; none → toast.
  void _applySshConfig() {
    final entries =
        parseSshConfig(_sshConfigCtrl.text).where((e) => !e.isWildcard).toList();
    if (entries.isEmpty) {
      showTopToast(context, 'No host entry found in that config');
      return;
    }
    if (entries.length == 1) {
      _applyEntry(entries.single);
      return;
    }
    _chooseAndApplyEntry(entries);
  }

  Future<void> _chooseAndApplyEntry(List<SshConfigEntry> entries) async {
    final chosen = await showModalBottomSheet<SshConfigEntry>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Choose a host to import'),
            ),
            for (final e in entries)
              ListTile(
                key: Key('profile-editor-sshconfig-choice-${e.alias}'),
                leading: const Icon(Icons.dns_outlined),
                title: Text(e.alias),
                subtitle: Text(e.effectiveHost),
                onTap: () => Navigator.of(sheetCtx).pop(e),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) _applyEntry(chosen);
  }

  /// Fill the Details controllers from a parsed entry, then jump to Details so
  /// the user can review and save. Only overwrites fields the entry provides;
  /// an empty Name is auto-filled `user@host`.
  void _applyEntry(SshConfigEntry e) {
    setState(() {
      _hostCtrl.text = e.effectiveHost;
      if (e.port != null) _portCtrl.text = e.port.toString();
      if (e.user != null && e.user!.isNotEmpty) _userCtrl.text = e.user!;
      if (_titleCtrl.text.trim().isEmpty) {
        final u = _userCtrl.text.trim();
        _titleCtrl.text = u.isNotEmpty ? '$u@${e.effectiveHost}' : e.alias;
      }
      if (e.identityFile != null) {
        _authKind = _AuthKind.key;
        _pendingIdentityFile = e.identityFile;
      }
    });
    _tabs.animateTo(0);
    showTopToast(context, 'Filled from "${e.alias}" — review and save');
  }
}

/// Color section (#1030): swatch button (opens the shared picker), the hex
/// TextField (backing value — `SavedProfile.color` persists exactly this
/// text), and the shared preset chips for one-tap selection. Stateful only to
/// repaint the swatch/selection ring as the controller text changes.
class _ColorSection extends StatefulWidget {
  const _ColorSection({required this.controller});

  final TextEditingController controller;

  @override
  State<_ColorSection> createState() => _ColorSectionState();
}

class _ColorSectionState extends State<_ColorSection> {
  Color? get _current => colorFromHex(widget.controller.text);

  void _setHex(String hex) {
    setState(() => widget.controller.text = hex);
  }

  Future<void> _openPicker() async {
    final result = await showColorPickerSheet(
      context,
      initial: _current,
      title: 'Profile color',
      // Short label: the sheet's action row is three-up on a 360dp phone and a
      // longer label ellipsized on the emulator shot.
      clearLabel: 'No color',
      previewLabel: 'session row',
    );
    if (result == null) return; // cancelled — keep as-is
    _setHex(result.color == null ? '' : hexFromColor(result.color!));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _current;
    final currentHex = current == null ? null : hexFromColor(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Custom-color affordance: current swatch (or a neutral palette
            // glyph when colorless) opening the shared picker sheet.
            InkResponse(
              key: const Key('profile-editor-color-custom'),
              onTap: _openPicker,
              radius: 28,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: current,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: current == null
                    ? Icon(
                        Icons.palette_outlined,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const Key('profile-editor-color'),
                controller: widget.controller,
                decoration: const InputDecoration(
                  labelText: 'Color (optional)',
                  hintText: '#ff8800',
                ),
                autocorrect: false,
                enableSuggestions: false,
                // Repaint the swatch + selection ring on manual hex edits.
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // One-tap quick swatches — the shared preset set the picker also
        // offers, kept inline so the common case stays a single tap.
        Wrap(
          key: const Key('profile-editor-color-presets'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in colorPickerPresets)
              _PresetSwatch(
                key: Key(
                  'profile-editor-color-preset-${hexFromColor(preset)}',
                ),
                color: preset,
                selected: hexFromColor(preset) == currentHex,
                onTap: () => _setHex(hexFromColor(preset)),
              ),
          ],
        ),
      ],
    );
  }
}

/// Round one-tap swatch chip (44dp) with a selection ring — the editor-side
/// twin of the picker's preset chip.
class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: 26,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 22,
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              )
            : null,
      ),
    );
  }
}

/// Fixed action footer for the editor (#594). Holds the two actions
/// (`connect-submit` = Save & connect, `profile-editor-save` = Save) and floats
/// directly above the soft keyboard by padding itself with the current
/// keyboard inset. Because the parent Scaffold uses
/// `resizeToAvoidBottomInset:false`, this widget owns the inset entirely, so the
/// buttons stay on-screen and hit-testable with the keyboard up — mirroring the
/// #585 session-menu overlay pattern and the always-reachable PWA editor action.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    super.key,
    required this.busy,
    required this.keyboardInset,
    required this.onConnect,
    required this.onSave,
  });

  final bool busy;
  final double keyboardInset;
  final VoidCallback? onConnect;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Opaque surface so the floating bar reads as a footer, not transparent
      // over the scrolling fields beneath it.
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: Padding(
        // bottom: keyboardInset floats the bar above the keyboard; when the
        // keyboard is down it falls back to the safe-area inset.
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          12 +
              (keyboardInset > 0
                  ? keyboardInset
                  : MediaQuery.paddingOf(context).bottom),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Save & connect (#583): the editor is the new-connection entry now
            // that the inline form is gone. `connect-submit` key keeps the
            // emulator connect smokes addressable. Connects via the chooser's
            // shared path (host-key prompt + initial-command arming).
            FilledButton.icon(
              key: const Key('connect-submit'),
              onPressed: onConnect,
              icon: const Icon(Icons.power_settings_new),
              label: Text(busy ? 'Connecting…' : 'Save & connect'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('profile-editor-save'),
              onPressed: onSave,
              icon: const Icon(Icons.save),
              label: Text(busy ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
