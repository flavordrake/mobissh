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
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart';

enum _AuthKind { password, key }

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

class _ProfileEditorState extends ConsumerState<ProfileEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _initialCommandCtrl;
  late final TextEditingController _colorCtrl;

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
    final p = widget.profile;
    _originalIdentityKey = p.identityKey;
    _titleCtrl = TextEditingController(text: p.title);
    _hostCtrl = TextEditingController(text: p.host);
    _portCtrl = TextEditingController(text: p.port.toString());
    _userCtrl = TextEditingController(text: p.username);
    _initialCommandCtrl = TextEditingController(text: p.initialCommand ?? '');
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
    _titleCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _initialCommandCtrl.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Host and username are required')),
      );
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
        theme: _themeKey,
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
        child: SingleChildScrollView(
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
            ],
          ),
        ),
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
