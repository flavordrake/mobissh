// Profile chooser — the home/connect view (#583).
//
// History: this widget used to be a full inline connect FORM
// (host/port/username/auth fields + a Connect button). #580 added tap-a-profile
// = connect and a pencil = full profile editor, which made the inline form
// redundant. #583 strips the form: the view is now an uncluttered profile
// CHOOSER for human decision —
//   - the saved-profile list (tap = connect, pencil = edit), and
//   - a single "New" affordance that opens the profile editor in create mode
//     (the editor is the new / ad-hoc connection entry now), and
//   - slim access to Import-from-PWA, Settings, and Diagnostics.
//
// CRITICAL plumbing kept here (the relocation trap): the host-key prompt
// listener (`ref.listen(sshSessionDataProvider)` → [_handleHostKeyPrompt]) and
// the shared connect dispatch ([_connectWithParams] / [_connectFromProfile] +
// initial-command arming) live in this State so tap-to-connect AND
// editor-"Save & connect" both prompt for unknown host keys and run the initial
// command. The class name is kept as `ConnectForm` (it's referenced by
// NewSessionPage + tests) even though it no longer renders a form.

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
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart';
import 'connect_error_dialog.dart';
import 'host_key_dialog.dart';
import 'import_profiles_dialog.dart';
import 'profile_editor.dart';
import 'profile_list.dart';

class ConnectForm extends ConsumerStatefulWidget {
  const ConnectForm({super.key});

  @override
  ConsumerState<ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends ConsumerState<ConnectForm> {
  bool _busy = false;

  /// Active subscription / completer for the "pop on connected" wait. Stored
  /// so [dispose] can tear them down cleanly when the chooser unmounts before
  /// the session reaches `connected` (otherwise the test binding flags a
  /// pending timer or the awaiter hangs forever).
  StreamSubscription<SshSessionData>? _connectedSub;
  Completer<bool>? _connectedCompleter;

  /// True while the connect-error dialog (#648) is open, so the `failed`-state
  /// listener doesn't stack a second dialog on a re-emit of the same failure.
  bool _errorDialogOpen = false;

  /// The params (and display title) of the most recent connect dispatch, so the
  /// connect-error dialog's "Retry" can re-attempt the SAME connection without
  /// re-walking the profile/credential resolution (#648).
  SshConnectParams? _lastConnectParams;
  String? _lastConnectTitle;

  @override
  void dispose() {
    ctrace('ui.chooser', 'dispose: ProfileChooser state being torn down');
    // Unblock any in-flight "wait for connected" await so the future doesn't
    // leak a Stream subscription or hang.
    if (_connectedCompleter != null && !_connectedCompleter!.isCompleted) {
      _connectedCompleter!.complete(false);
    }
    _connectedSub?.cancel();
    _connectedSub = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // CRITICAL (relocation trap): watch for host-key prompts so tapping a
    // profile (or "Save & connect" from the editor) still pops the Trust
    // dialog for an unknown host. This listener MUST live on the always-mounted
    // chooser — it was previously on the now-removed inline form.
    ref.listen<AsyncValue<SshSessionData>>(sshSessionDataProvider, (
      prev,
      next,
    ) {
      final pending = next.valueOrNull?.pendingHostKey;
      final prevPending = prev?.valueOrNull?.pendingHostKey;
      if (pending != null && prevPending == null) {
        _handleHostKeyPrompt(pending);
      }

      // #648: surface a connect FAILURE. An unreachable host (down / bad host /
      // wrong port → TCP refused, no route, or the half-open path that hit the
      // readyTimeout), a rejected host key, a bad key, or an auth failure all
      // land the active session in `failed`. The router keeps THIS chooser
      // mounted on a never-live `failed` precisely so the connect error renders
      // here (main.dart RootRouter) — but nothing rendered it. Show a clear
      // dialog with the reason + Back/Retry instead of a silent spinner/no-op.
      // Only fire on the TRANSITION into `failed` (prev != failed) so a re-emit
      // doesn't stack dialogs.
      final nextState = next.valueOrNull?.state;
      final prevState = prev?.valueOrNull?.state;
      if (nextState == SshSessionState.failed &&
          prevState != SshSessionState.failed) {
        _handleConnectFailure(next.valueOrNull);
      }
    });

    // #643: the chooser FILLS the screen. The saved-profile list goes in an
    // `Expanded` so it takes all the vertical room above the actions (it
    // scrolls within that full height); "New connection" + "Import from PWA"
    // pin directly below the full-height list. Previously the list was capped
    // at 220px and the whole Column was wrapped in a SingleChildScrollView at
    // both call sites, so it collapsed to the top ~40% with a blank band below.
    // This widget now needs a BOUNDED height (it no longer lives inside a
    // SingleChildScrollView) — its hosts (ConnectHomePage / NewSessionPage)
    // give it the full screen height.
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Saved profiles: tap a row = connect, pencil = edit. Empty-state
          // hint nudges Import when the user has none yet. Expanded so the list
          // uses the available height and scrolls internally (#643).
          Expanded(
            child: ProfileList(
              onConnect: _connectFromProfile,
              onEdit: _editProfile,
            ),
          ),
          const SizedBox(height: 4),
          // The single "New" affordance: opens the editor in create mode. The
          // editor is the ad-hoc / new-connection entry now that the inline
          // form is gone (#583).
          FilledButton.icon(
            key: const Key('new-connection'),
            onPressed: _busy ? null : _newConnection,
            icon: const Icon(Icons.add),
            label: Text(_busy ? 'Connecting…' : 'New connection'),
          ),
          const SizedBox(height: 4),
          // Slim secondary access: Import-from-PWA. Settings + Diagnostics live
          // on the home bottom nav (#611 Part A), not here.
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('open-import-profiles-dialog'),
              onPressed: _openImportDialog,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Import from PWA'),
            ),
          ),
          // #611 Part A: Settings + Diagnostics moved OUT of the chooser into
          // their own bottom-nav destinations (SettingsScreen / DiagnosticsScreen
          // on ConnectHomePage). The home view is now JUST the profile chooser,
          // and so is the pushed "New session" route (NewSessionPage).
        ],
      ),
    );
  }

  /// "New" affordance → open the editor in CREATE mode. On "Save & connect" the
  /// editor returns the saved profile and we route it through the same connect
  /// path as a profile-row tap. On plain "Save" we just refresh the list.
  Future<void> _newConnection() async {
    final result = await showProfileEditorForNew(context);
    if (!mounted || result == null) return;
    if (result.saved) {
      ref.invalidate(savedProfilesProvider);
    }
    final toConnect = result.connect;
    if (toConnect != null) {
      await _connectFromProfile(toConnect);
    }
  }

  /// Shared connect path used by BOTH a saved-profile row tap and the editor's
  /// "Save & connect". Routes through the sessions notifier (dedupe by
  /// host:port:user, per-session proxy), arms the run-on-connect command, then
  /// dispatches `proxy.connect`. When this chooser was pushed as a "New
  /// session" route, it pops back to the terminal once the session CONNECTS.
  Future<void> _connectWithParams(
    SshConnectParams params, {
    String? title,
    required String initialCommand,
    String? themeName,
    double? fontSize,
  }) async {
    // Captured before the async gap so we can pop a pushed "New session" route
    // after dispatching connect without touching `context` post-await.
    final navigator = Navigator.of(context);

    // Remember the params so the connect-error dialog's "Retry" can re-attempt
    // this exact connection without re-resolving the profile/credential (#648).
    _lastConnectParams = params;
    _lastConnectTitle = title;

    setState(() => _busy = true);
    try {
      // Multi-session (#511): route through the sessions notifier so we dedupe
      // by host:port:user and create a per-session proxy. If a matching session
      // already exists, addOrActivate returns it without reconnecting. The
      // optional title carries the saved profile's display name into the
      // session (#518).
      final entry = ref
          .read(sessionsProvider.notifier)
          .addOrActivate(params, title: title);
      ctrace('ui.chooser', 'entry=${entry.id} → proxy.connect()');
      // #613: apply the profile's default theme to THIS session (per-session,
      // #601 — keyed by the new session's id, NOT global). Only when the profile
      // carries a theme; an unknown/typo name maps to the default palette.
      if (themeName != null) {
        ref
            .read(sessionAppearanceProvider.notifier)
            .setTheme(entry.id, paletteIndexForThemeName(themeName));
        ctrace(
          'ui.chooser',
          'applied profile theme "$themeName" → '
              'palette ${paletteIndexForThemeName(themeName)} for ${entry.id}',
        );
      }
      // #640: seed THIS session's font size from the profile's PERSISTED
      // per-profile font (mirrors the theme seed above). Per-session, keyed by
      // the new session's id — NOT global. Only when the profile carries a
      // custom size; otherwise the session tracks the app default (#616).
      if (fontSize != null) {
        ref
            .read(sessionAppearanceProvider.notifier)
            .setFontSize(entry.id, fontSize);
        ctrace(
          'ui.chooser',
          'applied profile fontSize $fontSize for ${entry.id}',
        );
      }
      // Arm the run-on-connect command (#558) BEFORE dispatching connect, so
      // the one-shot listener is attached before the task side can emit
      // `connected`. No-op when the field is empty.
      ref
          .read(initialCommandRunnerProvider)
          .arm(
            sessionId: entry.id,
            proxy: entry.proxy,
            command: initialCommand,
          );
      await entry.proxy.connect(params);
      // Once we've proven network reachability, fire-and-forget a crash upload
      // sweep. Tailscale being down at boot is the common case.
      unawaited(CrashReporter.uploadPending());
      // When this chooser was pushed as a "New session" route (over a live
      // TerminalScreen), return to the terminal once the session CONNECTS — not
      // on dispatch. Staying mounted lets the chooser show the trust prompt;
      // once connected we pop back. The root chooser (ConnectHomePage) can't
      // pop, so this is skipped there — the router swaps to the terminal screen
      // on `connected` as before.
      if (navigator.canPop()) {
        await _popWhenConnected(entry, navigator);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Wait for the new session's proxy to reach `connected`, then pop the pushed
  /// "New session" route back to the terminal. Stays mounted while waiting so
  /// host-key prompts still render. On `failed` we stop and stay put so the
  /// user sees the error. On dispose the completer is short-circuited.
  Future<void> _popWhenConnected(
    SessionEntry entry,
    NavigatorState navigator,
  ) async {
    ctrace(
      'ui.chooser',
      'popWhenConnected: enter sid=${entry.id} state=${entry.proxy.data.state.name}',
    );
    if (entry.proxy.data.state == SshSessionState.connected) {
      ctrace('ui.chooser', 'popWhenConnected: already connected → pop');
      if (mounted && navigator.canPop()) navigator.pop();
      return;
    }
    final completer = Completer<bool>();
    _connectedCompleter = completer;
    _connectedSub = entry.proxy.stream.listen((data) {
      ctrace('ui.chooser', 'popWhenConnected: state=${data.state.name}');
      if (completer.isCompleted) return;
      if (data.state == SshSessionState.connected) {
        completer.complete(true);
      } else if (data.state == SshSessionState.failed) {
        completer.complete(false);
      }
    });
    final connected = await completer.future;
    ctrace(
      'ui.chooser',
      'popWhenConnected: completer=$connected mounted=$mounted canPop=${navigator.canPop()}',
    );
    await _connectedSub?.cancel();
    _connectedSub = null;
    _connectedCompleter = null;
    if (connected && mounted && navigator.canPop()) {
      ctrace('ui.chooser', 'popWhenConnected: navigator.pop() now');
      navigator.pop();
    }
  }

  /// #579 tap-to-connect / #583 editor "Save & connect". Resolve the profile's
  /// connection params + stored credentials, then connect immediately via the
  /// shared connect path.
  ///
  /// Credential resolution mirrors the PWA's `connectFromProfile`: load creds
  /// from the vault by vaultId/keyVaultId. If NO stored credentials are found,
  /// fall back to opening the profile editor (edit mode for this profile) so
  /// the user can add the missing credential — NOT a silent no-op, and no
  /// dangling reference to the removed inline form (#583).
  Future<void> _connectFromProfile(SavedProfile profile) async {
    final secrets = ref.read(secretsStoreProvider);
    final creds = await loadProfileCredentials(secrets, profile);
    if (!mounted) return;

    // Decide auth kind: explicit authType wins, else infer from what the vault
    // returned / the keyVaultId reference.
    final wantsKey =
        profile.authType == 'key' ||
        (profile.authType == null &&
            (creds.privateKey != null ||
                (profile.keyVaultId != null &&
                    profile.keyVaultId!.isNotEmpty)));

    final hasUsableCreds = wantsKey
        ? (creds.privateKey != null && creds.privateKey!.isNotEmpty)
        : (creds.password != null && creds.password!.isNotEmpty);

    if (!hasUsableCreds) {
      // No stored secret — open the editor so the user can enter credentials.
      // Matches the PWA "not saved on this browser" branch. NOT a silent
      // failure. The editor's "Save & connect" then routes back here.
      ctrace(
        'ui.chooser',
        'connectFromProfile ${profile.host}: no stored creds → editor',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved credentials — enter them to connect.'),
        ),
      );
      await _editProfile(profile);
      return;
    }

    final SshAuth auth;
    if (wantsKey) {
      auth = SshAuth.key(
        Uint8List.fromList(utf8.encode(creds.privateKey!)),
        passphrase: (creds.passphrase == null || creds.passphrase!.isEmpty)
            ? null
            : creds.passphrase,
      );
    } else {
      auth = SshAuth.password(creds.password!);
    }

    final params = SshConnectParams(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      auth: auth,
    );
    ctrace(
      'ui.chooser',
      'connectFromProfile ${profile.host} authType=${wantsKey ? 'key' : 'password'} → connect',
    );
    await _connectWithParams(
      params,
      title: profile.title,
      initialCommand: profile.initialCommand ?? '',
      themeName: profile.theme,
      fontSize: profile.fontSize,
    );
  }

  /// #579 edit pencil / #583 no-creds fallback. Open the full profile editor;
  /// on save, refresh the saved-profile list, and if the user chose "Save &
  /// connect", route through the shared connect path.
  Future<void> _editProfile(SavedProfile profile) async {
    final result = await showProfileEditor(context, profile);
    if (!mounted || result == null) return;
    if (result.saved) {
      ref.invalidate(savedProfilesProvider);
    }
    final toConnect = result.connect;
    if (toConnect != null) {
      await _connectFromProfile(toConnect);
    }
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

  /// #648: surface a connect failure as a clear, dismissable error dialog with
  /// the reason + Back/Retry. Called on the transition into `failed`. "Retry"
  /// re-dispatches the last connect params to the active session; "Back" just
  /// dismisses (the user stays on the chooser, not a silent spinner).
  Future<void> _handleConnectFailure(SshSessionData? data) async {
    if (_errorDialogOpen) return;
    final reason = (data?.error?.trim().isNotEmpty ?? false)
        ? data!.error!.trim()
        : 'The connection could not be established.';
    final host = data?.host;
    final port = data?.port;
    final target = (host != null && host.isNotEmpty)
        ? (port != null ? '$host:$port' : host)
        : null;
    ctrace('ui.chooser', 'connectFailure: surfacing error "$reason"');
    _errorDialogOpen = true;
    bool retry = false;
    try {
      retry = await showConnectErrorDialog(
        context,
        reason: reason,
        target: target,
      );
    } finally {
      _errorDialogOpen = false;
    }
    if (!mounted || !retry) return;

    // Retry: re-attempt the SAME connection. Reuse the cached params so we
    // don't re-walk profile/credential resolution. The active proxy is the one
    // that just failed; re-dispatch connect through it.
    final params = _lastConnectParams;
    if (params == null) return;
    ctrace('ui.chooser', 'connectFailure: RETRY ${params.host}:${params.port}');
    final proxy = ref.read(sshSessionProxyProvider);
    setState(() => _busy = true);
    try {
      await proxy.connect(params, title: _lastConnectTitle);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleHostKeyPrompt(PendingHostKey pending) async {
    final accepted = await showHostKeyDialog(context, pending: pending);
    // Defensive — the chooser can be popped (e.g. New session route) while the
    // dialog is in-flight. Touching `ref` after dispose throws StateError.
    if (!mounted) return;
    final proxy = ref.read(sshSessionProxyProvider);
    if (accepted) {
      proxy.acceptHostKey();
    } else {
      proxy.rejectHostKey();
    }
  }
}

/// Full-screen page hosting the profile [ConnectForm] chooser for starting an
/// ADDITIONAL session while others are already connected (#583). Pushed from
/// the session menu's "New session" tile (the goal's leg 2). It shows the SAME
/// chooser as the home view: pick a profile = open as a new session; "New" =
/// editor. The chooser pops this route itself once the new session CONNECTS
/// (see [_ConnectFormState._popWhenConnected]).
class NewSessionPage extends StatelessWidget {
  const NewSessionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('new-session-page'),
      appBar: AppBar(title: const Text('New session')),
      // #643: NO SingleChildScrollView — the chooser fills the page height so
      // its profile list expands and scrolls internally instead of collapsing
      // to the top with a blank band below.
      body: const SafeArea(child: ConnectForm(key: Key('new-session-form'))),
    );
  }
}
