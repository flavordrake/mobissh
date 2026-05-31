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

import '../diagnostics/connect_trace.dart';
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
  // Optional command run once after the session connects (#558). Prefilled
  // from an applied profile's `initialCommand`; empty by default.
  final _initialCommandCtrl = TextEditingController();

  _AuthKind _authKind = _AuthKind.password;
  bool _busy = false;

  /// Active subscription / completer for the "pop on connected" wait. Stored
  /// so [dispose] can tear them down cleanly when the form unmounts before the
  /// session reaches `connected` (otherwise the test binding flags a pending
  /// timer or the awaiter hangs forever).
  StreamSubscription<SshSessionData>? _connectedSub;
  Completer<bool>? _connectedCompleter;

  /// Last saved profile applied to the form, if any. Carries the human title
  /// through to the session (#518). Cleared (effectively) by drift-checking
  /// host/port/username at submit time so the title doesn't lie about the
  /// connection target.
  SavedProfile? _appliedProfile;

  @override
  void dispose() {
    ctrace('ui.form', 'dispose: ConnectForm state being torn down');
    // Unblock any in-flight "wait for connected" await BEFORE the controllers
    // tear down, so _popWhenConnected's continuation runs against a dead
    // widget but doesn't leak a Stream subscription or hang the future.
    if (_connectedCompleter != null && !_connectedCompleter!.isCompleted) {
      _connectedCompleter!.complete(false);
    }
    _connectedSub?.cancel();
    _connectedSub = null;
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    _keyCtrl.dispose();
    _passphraseCtrl.dispose();
    _initialCommandCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch for host-key prompts; show dialog when one appears.
    ref.listen<AsyncValue<SshSessionData>>(sshSessionDataProvider, (
      prev,
      next,
    ) {
      final pending = next.valueOrNull?.pendingHostKey;
      final prevPending = prev?.valueOrNull?.pendingHostKey;
      if (pending != null && prevPending == null) {
        _handleHostKeyPrompt(pending);
      }
    });

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
                  key: const Key('connect-host'),
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
                  key: const Key('connect-port'),
                  controller: _portCtrl,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('connect-username'),
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
            onSelectionChanged: (s) => setState(() => _authKind = s.first),
          ),
          const SizedBox(height: 8),
          if (_authKind == _AuthKind.password)
            TextField(
              key: const Key('connect-password'),
              controller: _passwordCtrl,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            )
          else ...[
            TextField(
              key: const Key('connect-key'),
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
            key: const Key('connect-initial-command'),
            controller: _initialCommandCtrl,
            decoration: const InputDecoration(
              labelText: 'Initial command (optional)',
              hintText: 'e.g. tmux attach || tmux',
            ),
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('connect-submit'),
            onPressed: _canSubmit() ? () => _submit() : null,
            icon: const Icon(Icons.power_settings_new),
            label: Text(_busy ? 'Connecting...' : 'Connect'),
          ),
          const SizedBox(height: 8),
          const SettingsPanel(),
          const DiagnosticsSection(),
        ],
      ),
    );
  }

  /// Whether the Connect button is enabled. Gated only on this form's own
  /// in-flight submit (`_busy`) — NOT on any global/active session state.
  ///
  /// Multi-session: the form may be a pushed "New session" page opened while
  /// other sessions are already `connected`. Gating on the legacy single-
  /// session shim (`sshSessionDataProvider`) disabled the button whenever any
  /// session was connected, making it impossible to start a 2nd session.
  /// `addOrActivate` dedups by host:port:username and the task-side controller
  /// no-ops a re-connect, so an always-enabled button is safe.
  bool _canSubmit() => !_busy;

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

    // Credential-presence trace (lengths only — never values). Tells us via
    // the on-device Connect log whether the vault prefill actually populated
    // the fields: pwLen=0 / keyLen=0 means prefill returned empty (secret not
    // found / read failed), vs a non-zero length meaning creds are present and
    // the server rejected them. (#542/#543 diagnosis of "all auth methods
    // failed after import".)
    ctrace(
      'ui.form',
      'auth=${_authKind.name} pwLen=${_passwordCtrl.text.length} '
          'keyLen=${_keyCtrl.text.length} ppLen=${_passphraseCtrl.text.length}',
    );
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

    // Captured before the async gap so we can pop a pushed "New session"
    // route after dispatching connect without touching `context` post-await.
    final navigator = Navigator.of(context);

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
      ctrace(
        'ui.form',
        'submit host=$host port=$port user=$username auth=${_authKind.name}',
      );
      final title = _profileTitleForCurrentForm();
      final entry = ref
          .read(sessionsProvider.notifier)
          .addOrActivate(params, title: title);
      // Only fire connect for entries that haven't been kicked off yet —
      // idle/failed/disconnected states are safe to re-drive; connected/
      // connecting/authenticating are no-ops inside the task-side controller
      // itself.
      ctrace('ui.form', 'entry=${entry.id} → proxy.connect()');
      // Arm the run-on-connect command (#558) BEFORE dispatching connect, so
      // the one-shot listener is attached before the task side can emit
      // `connected`. The runner fires exactly once on the first `connected`
      // transition for this session id and guards against re-fire on the
      // #551 reconnect rebind. No-op when the field is empty.
      ref
          .read(initialCommandRunnerProvider)
          .arm(
            sessionId: entry.id,
            proxy: entry.proxy,
            command: _initialCommandCtrl.text,
          );
      await entry.proxy.connect(params);
      // Once we've proven we have network reachability, fire-and-forget a
      // crash upload sweep. Tailscale being down is the common case at boot
      // and the second-chance path matters more than blocking the UI.
      unawaited(CrashReporter.uploadPending());
      // When this form was pushed as a "New session" route (over a live
      // TerminalScreen), return to the terminal once the session CONNECTS —
      // not on dispatch. Popping early would unmount the form mid-handshake,
      // so a host-key prompt for the new session would have no form to render
      // on (and touching `ref` after dispose throws). Staying mounted lets the
      // form show the trust prompt; once connected we pop back to the terminal.
      // The root form (ConnectHomePage) can't pop, so this is skipped there —
      // the router swaps to the terminal screen on `connected` as before.
      if (navigator.canPop()) {
        await _popWhenConnected(entry, navigator);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Wait for the new session's proxy to reach `connected`, then pop the
  /// pushed "New session" route back to the terminal. Stays mounted while
  /// waiting so host-key prompts still render on this form. On `failed` we
  /// stop and stay put so the user sees the error and can retry. On dispose
  /// (e.g. the user backs out), the completer is short-circuited so the
  /// awaiter unblocks without leaking the subscription.
  Future<void> _popWhenConnected(
    SessionEntry entry,
    NavigatorState navigator,
  ) async {
    ctrace(
      'ui.form',
      'popWhenConnected: enter sid=${entry.id} state=${entry.proxy.data.state.name}',
    );
    // Already there? Pop now.
    if (entry.proxy.data.state == SshSessionState.connected) {
      ctrace('ui.form', 'popWhenConnected: already connected → pop');
      if (mounted && navigator.canPop()) navigator.pop();
      return;
    }
    final completer = Completer<bool>();
    _connectedCompleter = completer;
    _connectedSub = entry.proxy.stream.listen((data) {
      ctrace('ui.form', 'popWhenConnected: state=${data.state.name}');
      if (completer.isCompleted) return;
      if (data.state == SshSessionState.connected) {
        completer.complete(true);
      } else if (data.state == SshSessionState.failed) {
        completer.complete(false);
      }
    });
    final connected = await completer.future;
    ctrace(
      'ui.form',
      'popWhenConnected: completer=$connected mounted=$mounted canPop=${navigator.canPop()}',
    );
    await _connectedSub?.cancel();
    _connectedSub = null;
    _connectedCompleter = null;
    if (connected && mounted && navigator.canPop()) {
      ctrace('ui.form', 'popWhenConnected: navigator.pop() now');
      navigator.pop();
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
      // Prefill the optional run-on-connect command (#558). Empty when the
      // profile carries none.
      _initialCommandCtrl.text = profile.initialCommand ?? '';
      // Pick the auth mode. Prefer the explicit authType, but if it's missing
      // or ambiguous (e.g. a profile imported by an older build that persisted
      // before authType round-tripped), INFER from keyVaultId: a profile that
      // carries a key-blob reference is a key-auth profile. Without this, such
      // a profile defaults to password mode with an empty password field and
      // every connect fails with "all authentication methods failed" against a
      // publickey-only host.
      if (profile.authType == 'key') {
        _authKind = _AuthKind.key;
      } else if (profile.authType == 'password') {
        _authKind = _AuthKind.password;
      } else if (profile.keyVaultId != null && profile.keyVaultId!.isNotEmpty) {
        _authKind = _AuthKind.key;
      } else {
        _authKind = _AuthKind.password;
      }
      ctrace(
        'ui.form',
        'applyProfile ${profile.host} authType=${profile.authType} '
            'keyVaultId=${profile.keyVaultId != null} → mode=${_authKind.name}',
      );
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
    final parts = <String>[];
    if (result.added > 0) {
      parts.add('${result.added} added');
    }
    if (result.updated > 0) {
      parts.add('${result.updated} updated');
    }
    final msg = parts.isNotEmpty
        ? 'Imported ${parts.join(', ')}'
        : 'No profiles imported.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _handleHostKeyPrompt(PendingHostKey pending) async {
    final accepted = await showHostKeyDialog(context, pending: pending);
    // Defensive — the form can be popped (e.g. New session route) while the
    // dialog is in-flight. Touching `ref` after dispose throws StateError.
    // The new-session flow now stays mounted until connected, so this only
    // fires on edge cases (user backs out mid-handshake); skipping the
    // decision lets the task-side controller fall through its own timeout.
    if (!mounted) return;
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

/// Full-screen page hosting a [ConnectForm] for starting an ADDITIONAL session
/// while others are already connected. Pushed from the session menu's
/// "New session" tile (the goal's leg 2: connect a second session).
///
/// Without this, the `RootRouter` shows the terminal screen the moment any
/// session connects, so there's no way back to the connect form to start a
/// second one. The form pops this route itself once connect is dispatched
/// (see [_ConnectFormState._submit]), landing back on the terminal screen with
/// the new session active.
class NewSessionPage extends StatelessWidget {
  const NewSessionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('new-session-page'),
      appBar: AppBar(title: const Text('New session')),
      body: const SafeArea(
        child: SingleChildScrollView(
          child: ConnectForm(key: Key('new-session-form')),
        ),
      ),
    );
  }
}
