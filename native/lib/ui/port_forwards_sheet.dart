// Port forwards sheet (#1047) — session menu → "Port forwards".
//
// Lists the ACTIVE session's ssh -L forwards with live per-forward status
// (starting / active / error), an add form (local port, remote host, remote
// port), per-forward remove, and a per-forward "profile default" star that
// persists the forward onto the session's saved profile so it re-arms on
// every (re)connect. Monochrome Material glyphs only
// (feedback_monochrome_icons_no_emoji); every control is a ≥44px target.
//
// Presented via showModalBottomSheet on the app Navigator (the session-menu
// overlay closes FIRST — its barrier sits above pushed routes, #664 idiom).
//
// Add form (#1094): the remote port MIRRORS the local port as a real controller
// value until the user types their own, so the common `8080 → 8080` case is
// actually committed. Port fields carry no numeric hintText — a grey number
// inside an empty field is indistinguishable from a filled-in one.
//
// Security (.claude/rules/security.md): forwards bind 127.0.0.1 ONLY; the
// sheet states that so the surface is honest about scope. No -R in v1.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/session_messages.dart';
import '../state/sessions.dart';
import '../storage/profiles_store.dart';

/// Open the Port forwards sheet for [entry] on [navigatorContext] (the app
/// Navigator's context — NOT the session-menu overlay's, which must already
/// be closed, #664).
Future<void> showPortForwardsSheet(
  BuildContext navigatorContext, {
  required SessionEntry entry,
  required ProfilesStore store,
}) {
  return showModalBottomSheet<void>(
    context: navigatorContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => PortForwardsSheet(entry: entry, store: store),
  );
}

class PortForwardsSheet extends StatefulWidget {
  const PortForwardsSheet({
    super.key,
    required this.entry,
    required this.store,
  });

  final SessionEntry entry;
  final ProfilesStore store;

  /// Default remote host shown when the field is blank — a bare `-L
  /// localPort:remotePort` binds the SSH server's own loopback (#1054).
  static const String defaultRemoteHost = '127.0.0.1';

  /// The concrete effect line for the add form: `localPort → remoteHost:remotePort`.
  /// Empty ports render as a `·` placeholder so the shape is always visible;
  /// a blank remote host shows the resolved default (127.0.0.1).
  static String previewMapping(
    String localPort,
    String remoteHost,
    String remotePort,
  ) {
    final l = localPort.trim().isEmpty ? '·' : localPort.trim();
    final h = remoteHost.trim().isEmpty ? defaultRemoteHost : remoteHost.trim();
    final r = remotePort.trim().isEmpty ? '·' : remotePort.trim();
    return '$l  →  $h:$r';
  }

  /// Plain-language direction so `ssh -L` can't be misread: what reaches what,
  /// through which host ([sessionHost]).
  static String previewSemantics(
    String localPort,
    String remoteHost,
    String remotePort,
    String sessionHost,
  ) {
    final l = localPort.trim().isEmpty ? '·' : localPort.trim();
    final h = remoteHost.trim().isEmpty ? defaultRemoteHost : remoteHost.trim();
    final r = remotePort.trim().isEmpty ? '·' : remotePort.trim();
    return 'Apps on this phone at 127.0.0.1:$l reach $h:$r through $sessionHost.';
  }

  @override
  State<PortForwardsSheet> createState() => _PortForwardsSheetState();
}

class _PortForwardsSheetState extends State<PortForwardsSheet> {
  late List<ForwardInfo> _forwards;
  StreamSubscription<List<ForwardInfo>>? _sub;

  /// localPorts marked as profile defaults for this session's profile. Null
  /// while loading OR when the session has no saved profile (ad-hoc) — then
  /// the star column is hidden (we never materialize a profile, #640 idiom).
  Set<int>? _defaultPorts;
  bool _hasProfile = false;

  final _localPortCtrl = TextEditingController();
  final _remoteHostCtrl = TextEditingController(text: '127.0.0.1');
  final _remotePortCtrl = TextEditingController();
  String? _formError;

  /// True once the user has typed their own remote port. While false the remote
  /// port MIRRORS the local port (#1094) — the common case `8080 → 8080` is then
  /// genuinely committed, not a hint that merely looks committed. A deliberate
  /// `8080 → 80` is never clobbered by a later local-port edit.
  bool _remotePortEdited = false;

  /// Reentrancy guard: the mirror writes `_remotePortCtrl`, which fires that
  /// controller's own listener. Without this the mirror would read as a user
  /// edit and pin the field after one keystroke.
  bool _mirroringRemotePort = false;

  @override
  void initState() {
    super.initState();
    _forwards = widget.entry.proxy.forwards;
    _sub = widget.entry.proxy.forwardEvents.listen((list) {
      if (!mounted) return;
      setState(() => _forwards = list);
    });
    // Live effect preview (#1054): rebuild the `L → host:R` line as the user
    // types so the concrete mapping + direction stay in front of them.
    _localPortCtrl.addListener(_onLocalPortChanged);
    _remoteHostCtrl.addListener(_onFieldChanged);
    _remotePortCtrl.addListener(_onRemotePortChanged);
    // Hydrate: the task replays the authoritative table.
    widget.entry.proxy.forwardList();
    unawaited(_loadDefaults());
  }

  void _onFieldChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// Mirror the local port into the remote port (#1094) unless the user has
  /// pinned their own. Clearing the local port clears the mirror too, so no
  /// stale value is stranded in a field the user can no longer see the origin of.
  void _onLocalPortChanged() {
    if (!_remotePortEdited && _remotePortCtrl.text != _localPortCtrl.text) {
      _mirroringRemotePort = true;
      _remotePortCtrl.text = _localPortCtrl.text;
      _mirroringRemotePort = false;
    }
    _onFieldChanged();
  }

  /// A user edit pins the remote port; wiping it back to empty hands the field
  /// to the mirror again. Deliberately does NOT refill on the spot — refilling
  /// the instant the field empties corrupts backspace-then-retype on a soft
  /// keyboard (`80` → `8` → `` → refilled `8080`, then the new digits append).
  void _onRemotePortChanged() {
    if (!_mirroringRemotePort) {
      _remotePortEdited = _remotePortCtrl.text.trim().isNotEmpty;
    }
    _onFieldChanged();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _localPortCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDefaults() async {
    final profiles = await widget.store.load();
    if (!mounted) return;
    for (final p in profiles) {
      if (p.identityKey == widget.entry.profileKey) {
        setState(() {
          _hasProfile = true;
          _defaultPorts = p.forwards.map((f) => f.localPort).toSet();
        });
        return;
      }
    }
    setState(() {
      _hasProfile = false;
      _defaultPorts = <int>{};
    });
  }

  /// Toggle "arm on connect" for [info]'s localPort on the saved profile.
  Future<void> _toggleDefault(ForwardInfo info) async {
    final ports = _defaultPorts;
    if (!_hasProfile || ports == null) return;
    final next = <int>{...ports};
    final adding = next.add(info.localPort);
    if (!adding) next.remove(info.localPort);
    // Rebuild the profile list from the CURRENT session table (source of
    // truth for targets) filtered to the marked ports.
    final list = <ProfileForward>[
      for (final f in _forwards)
        if (next.contains(f.localPort))
          ProfileForward(
            localPort: f.localPort,
            remoteHost: f.remoteHost,
            remotePort: f.remotePort,
          ),
    ];
    await widget.store.setForwards(widget.entry.profileKey, list);
    if (!mounted) return;
    setState(() => _defaultPorts = next);
  }

  /// When a forward is removed from the live session, also drop a matching
  /// profile default — a removed forward that silently re-arms on the next
  /// connect would read as "remove didn't work".
  Future<void> _remove(ForwardInfo info) async {
    widget.entry.proxy.forwardRemove(info.localPort);
    final ports = _defaultPorts;
    if (_hasProfile && ports != null && ports.contains(info.localPort)) {
      final next = <int>{...ports}..remove(info.localPort);
      final list = <ProfileForward>[
        for (final f in _forwards)
          if (f.localPort != info.localPort && next.contains(f.localPort))
            ProfileForward(
              localPort: f.localPort,
              remoteHost: f.remoteHost,
              remotePort: f.remotePort,
            ),
      ];
      await widget.store.setForwards(widget.entry.profileKey, list);
      if (!mounted) return;
      setState(() => _defaultPorts = next);
    }
  }

  void _submitAdd() {
    final localPort = int.tryParse(_localPortCtrl.text.trim());
    final remotePort = int.tryParse(_remotePortCtrl.text.trim());
    final remoteHostRaw = _remoteHostCtrl.text.trim();
    final remoteHost = remoteHostRaw.isEmpty ? '127.0.0.1' : remoteHostRaw;
    if (localPort == null || localPort < 1 || localPort > 65535) {
      setState(() => _formError = 'Local port must be 1–65535');
      return;
    }
    if (remotePort == null || remotePort < 1 || remotePort > 65535) {
      setState(() => _formError = 'Remote port must be 1–65535');
      return;
    }
    setState(() => _formError = null);
    widget.entry.proxy.forwardAdd(
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
    // Reset the pin FIRST so clearing the local port also clears the mirror and
    // the next entry mirrors again.
    _remotePortEdited = false;
    _localPortCtrl.clear();
    _remotePortCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Float above the soft keyboard so the add form stays reachable.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            key: const Key('port-forwards-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Text('Port forwards', style: theme.textTheme.titleSmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  // Honest scope: loopback-only listeners (rules/security.md).
                  'Listens on 127.0.0.1 on this device; tunnels to the host '
                  'over SSH.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_forwards.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(
                    'No forwards yet.',
                    key: const Key('port-forwards-empty'),
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final f in _forwards) _forwardRow(theme, f),
                    ],
                  ),
                ),
              const Divider(height: 1),
              _addForm(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _forwardRow(ThemeData theme, ForwardInfo f) {
    final (IconData glyph, Color color, String label) = switch (f.status) {
      ForwardStatus.active => (
        Icons.check_circle,
        theme.colorScheme.primary,
        'Active',
      ),
      ForwardStatus.starting => (
        Icons.pending_outlined,
        theme.colorScheme.onSurfaceVariant,
        'Waiting for connection',
      ),
      ForwardStatus.error => (
        Icons.error_outline,
        theme.colorScheme.error,
        'Error',
      ),
    };
    final isDefault = _defaultPorts?.contains(f.localPort) ?? false;
    final subtitle = f.error ?? label;
    return ListTile(
      key: Key('forward-row-${f.localPort}'),
      dense: true,
      leading: Icon(glyph, size: 20, color: color),
      title: Text(
        // Compact `L → host:R` mapping (#1054) — same shape as the add-form
        // preview so a saved forward reads identically to its preview.
        '${f.localPort}  →  ${f.remoteHost}:${f.remotePort}',
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: f.status == ForwardStatus.error
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Arm on connect" profile-default star. Hidden for ad-hoc sessions
          // with no saved profile (never materialize one).
          if (_hasProfile)
            IconButton(
              key: Key('forward-default-${f.localPort}'),
              tooltip: isDefault
                  ? 'Profile default (arms on connect)'
                  : 'Save as profile default',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                isDefault ? Icons.star : Icons.star_border,
                color: isDefault ? theme.colorScheme.primary : null,
              ),
              onPressed: () => unawaited(_toggleDefault(f)),
            ),
          IconButton(
            key: Key('forward-remove-${f.localPort}'),
            tooltip: 'Remove forward',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(_remove(f)),
          ),
        ],
      ),
    );
  }

  Widget _addForm(ThemeData theme) {
    final mapping = PortForwardsSheet.previewMapping(
      _localPortCtrl.text,
      _remoteHostCtrl.text,
      _remotePortCtrl.text,
    );
    final semantics = PortForwardsSheet.previewSemantics(
      _localPortCtrl.text,
      _remoteHostCtrl.text,
      _remotePortCtrl.text,
      widget.entry.host,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live effect preview (#1054): the concrete mapping, big + monospace,
          // so the direction and endpoints are unambiguous before Add.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mapping,
                  key: const Key('forward-preview'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  semantics,
                  key: const Key('forward-preview-semantics'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 88,
                child: TextField(
                  key: const Key('forward-local-port'),
                  controller: _localPortCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    // No numeric hint (#1094): a grey `8888` sitting inside an
                    // EMPTY field reads as a committed value. The label +
                    // helper + live preview carry the meaning instead.
                    labelText: 'Local',
                    helperText: 'phone',
                    isDense: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: TextField(
                  key: const Key('forward-remote-host'),
                  controller: _remoteHostCtrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Remote host',
                    hintText: 'hostname',
                    helperText: 'resolved from the SSH server',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 88,
                child: TextField(
                  key: const Key('forward-remote-port'),
                  controller: _remotePortCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    // The #1094 trap itself: this hint was read as an
                    // auto-filled value while the controller was empty.
                    labelText: 'Remote',
                    helperText: 'on server',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          if (_formError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _formError!,
                key: const Key('forward-form-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('forward-add-submit'),
            onPressed: _submitAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add forward'),
          ),
        ],
      ),
    );
  }
}
