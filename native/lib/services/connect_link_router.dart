// #1141 (PR C of #1117) — `mobissh://` link router.
//
// Pure Dart, seams injected like [AttentionFocusRouter]. Implements
// docs/deep-link-intents.md R12–R19, R26–R29 on top of PR A's parser/matcher:
//
//   deliver(link)   → parse (R1–R7). Rejected → [reject] + ONE redacted log
//                     line and nothing else (R26/R27). Parsed → the VALIDATED
//                     fields are stored as the pending record (never the raw
//                     link) and consumed at once.
//   consumePending → one-shot, safe on init AND resume (R18): match (R8–R11),
//                     confirm (R12–R14), then focus a live session for the
//                     SAME identity (R17) or hand the exact matched profile to
//                     the connect seam (production: ConnectForm's
//                     `_connectFromProfile`, which owns the TOFU listener —
//                     R15 — and the missing-creds → editor fallback — R13a).
//
// The router has no secrets / host-key seam by construction: a link can only
// ever confirm, persist `linkAutoConnect` (from the explicit "Always allow"
// answer), focus, connect-through-the-profile-path, or open the editor.
//
// #1149 (PR E): the `tmux=<name>` verb rides the hand-off as a TYPED
// [LinkVerbCommand] (R22) — a fresh connect arms it on shell-ready in place of
// the profile's initialCommand (R25); a LIVE session of the same identity is
// focused and then ALWAYS asked in the terminal (`confirmSend`, R23 option b,
// regardless of linkAutoConnect) before the verb goes to the send seam.

import 'dart:convert';

import '../storage/profiles_store.dart';
import 'connect_intent.dart';
import 'link_verb.dart';
import 'session_attention_notification.dart';
import 'sftp_intent.dart';

/// The user's answer to the R12 confirmation. `null` = cancelled.
enum LinkConfirmChoice { once, always }

/// A live session as the router sees it: its id and `host:port:username`.
class LiveSessionRef {
  const LiveSessionRef({required this.id, required this.profileKey});
  final String id;
  final String profileKey;
}

/// Process-death-surviving one-shot record of a parsed, validated
/// [ConnectRequest] (R18). Mirrors [PendingFocusBridge]; only validated fields
/// are stored, never the link text.
class PendingLinkBridge {
  PendingLinkBridge(this._store, {this.log});

  final KeyValueStore _store;
  final void Function(String where, String msg)? log;

  static const String _key = 'mobissh.link.pending';
  static int _seq = 0;

  Future<void> setPending(ConnectRequest request) async {
    await _store.setString(
      _key,
      jsonEncode(<String, Object?>{
        'verb': request.verb.name,
        'host': request.host,
        'port': request.port,
        'user': request.user,
        'name': request.name,
        'tmux': request.tmux,
        'window': request.window,
        'path': request.path,
        '_seq': ++_seq,
      }),
    );
    log?.call('ui.link', 'pending set verb=${request.verb.name}');
  }

  Future<ConnectRequest?> readPending() async {
    final raw = await _store.getString(_key);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final verb = ConnectVerb.values.asNameMap()[m['verb']];
      if (verb == null) return null;
      return ConnectRequest(
        verb: verb,
        host: m['host'] as String?,
        port: m['port'] is int ? m['port'] as int : 22,
        user: m['user'] as String?,
        name: m['name'] as String?,
        tmux: m['tmux'] as String?,
        window: m['window'] as String?,
        path: m['path'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// One-shot: returns the pending request and clears it.
  Future<ConnectRequest?> takePending() async {
    final pending = await readPending();
    await _store.remove(_key);
    return pending;
  }
}

class ConnectLinkRouter {
  ConnectLinkRouter({
    required PendingLinkBridge bridge,
    required Future<List<SavedProfile>> Function() loadProfiles,
    required Iterable<LiveSessionRef> Function() liveSessions,
    required void Function(String sessionId) setActive,
    required Future<LinkConfirmChoice?> Function(
            SavedProfile profile, LinkVerbCommand? verb)
        confirm,
    required Future<bool> Function(SavedProfile profile, LinkVerbCommand verb)
        confirmSend,
    required Future<SavedProfile?> Function(List<SavedProfile> candidates) pick,
    required Future<void> Function(SavedProfile profile) persistAutoConnect,
    required Future<void> Function(SavedProfile profile, LinkVerbCommand? verb)
        connectProfile,
    required void Function(String sessionId, LinkVerbCommand verb) sendVerb,
    required bool Function(String sessionId, String tmuxName) isTmuxAttached,
    required Future<void> Function(String sessionId, TmuxAttach verb)
        selectWindow,
    required Future<void> Function(SavedProfile draft) openCreate,
    required void Function() reject,
    void Function(String where, String msg)? log,
  })  : _bridge = bridge,
        _loadProfiles = loadProfiles,
        _liveSessions = liveSessions,
        _setActive = setActive,
        _confirm = confirm,
        _confirmSend = confirmSend,
        _pick = pick,
        _persistAutoConnect = persistAutoConnect,
        _connectProfile = connectProfile,
        _sendVerb = sendVerb,
        _isTmuxAttached = isTmuxAttached,
        _selectWindow = selectWindow,
        _openCreate = openCreate,
        _reject = reject,
        _log = log;

  // ignore_for_file: prefer_initializing_formals
  final PendingLinkBridge _bridge;
  final Future<List<SavedProfile>> Function() _loadProfiles;
  final Iterable<LiveSessionRef> Function() _liveSessions;
  final void Function(String sessionId) _setActive;
  final Future<LinkConfirmChoice?> Function(SavedProfile, LinkVerbCommand?)
      _confirm;
  final Future<bool> Function(SavedProfile, LinkVerbCommand) _confirmSend;
  final Future<SavedProfile?> Function(List<SavedProfile>) _pick;
  final Future<void> Function(SavedProfile) _persistAutoConnect;
  final Future<void> Function(SavedProfile, LinkVerbCommand?) _connectProfile;
  final void Function(String, LinkVerbCommand) _sendVerb;
  final bool Function(String, String) _isTmuxAttached;
  final Future<void> Function(String, TmuxAttach) _selectWindow;
  final Future<void> Function(SavedProfile) _openCreate;
  final void Function() _reject;
  final void Function(String where, String msg)? _log;

  /// #1279 G1 / F8: true from parse until the confirm / picker / editor and
  /// the connect hand-off are done. Only one link is ever in flight.
  bool _inFlight = false;

  /// Cold-start or warm delivery of a raw link.
  ///
  /// #1279 G1 / F8: a link that arrives while another is in flight is
  /// DROPPED — not queued (a burst would stack dialogs) and not swapped in
  /// for the pending one (a swap under the user's tap is the attack). It
  /// leaves no banner and does not touch the pending record.
  Future<void> deliver(String link) async {
    if (_inFlight) {
      _log?.call('ui.link', 'dropped reason=busy');
      return;
    }
    _inFlight = true;
    try {
      switch (parseLink(link)) {
        case ConnectIntentRejected(:final reason, :final key):
          _rejected('reason=${reason.name}${key == null ? '' : ' key=$key'}');
        case ConnectIntentParsed(:final request):
          await _bridge.setPending(request);
          await _consume();
      }
    } finally {
      _inFlight = false;
    }
  }

  /// One-shot consume of the pending record (init + resume, R18).
  Future<void> consumePending() async {
    if (_inFlight) return; // the in-flight link already took the record
    _inFlight = true;
    try {
      await _consume();
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _consume() async {
    final request = await _bridge.takePending();
    if (request == null) return;
    // #1279 S1: sftp links parse, but the browser hand-off is slice S2. A
    // plain connect here would drop the path — the silent "less than asked"
    // R7 forbids — so until S2 the link is rejected.
    if (request.verb == ConnectVerb.sftp) {
      _rejected('reason=notRouted verb=sftp');
      return;
    }
    // R22: the verb is typed here, from the validated token, and nowhere else.
    final verb = LinkVerbCommand.fromRequest(request);
    final profiles = await _loadProfiles();
    final match = matchConnectRequest(
      request,
      profiles,
      alias: (p) => p.linkAlias,
    );
    switch (match) {
      case AliasMiss():
        _rejected('reason=aliasMiss');
      case Ambiguous(:final candidates):
        if (request.name != null) {
          // R10: a duplicated alias never resolves to the first hit.
          _rejected('reason=ambiguousAlias');
          return;
        }
        final picked = await _pick(candidates);
        if (picked == null) {
          _log?.call('ui.link', 'picker cancelled');
          return;
        }
        // R14: a picker result always confirms.
        await _confirmThenProceed(picked, verb: verb, force: true);
      case NoMatch():
        // R9 zero / R14: pre-fill the editor, never persist, never connect.
        await _openCreate(SavedProfile(
          title: request.verb == ConnectVerb.create ? (request.name ?? '') : '',
          host: request.host ?? '',
          port: request.port,
          username: request.user ?? '',
          linkAutoConnect: false,
        ));
        _log?.call('ui.link', 'route=create verb=${request.verb.name}');
      case Matched(:final profile):
        // R11: `create` on an existing identity confirms that profile instead
        // of duplicating it; R13: linkAutoConnect skips the prompt on connect.
        await _confirmThenProceed(
          profile,
          verb: verb,
          force: request.verb == ConnectVerb.create,
        );
    }
  }

  Future<void> _confirmThenProceed(SavedProfile profile,
      {required LinkVerbCommand? verb, required bool force}) async {
    var authorised = profile;
    if (force || !profile.linkAutoConnect) {
      // R16: the confirmation names the command a verb will run.
      final choice = await _confirm(profile, verb);
      if (choice == null) {
        _log?.call('ui.link', 'confirm cancelled');
        return;
      }
      if (choice == LinkConfirmChoice.always) {
        // The ONLY place a link ever sets linkAutoConnect.
        authorised = profile.copyWith(linkAutoConnect: true);
        await _persistAutoConnect(authorised);
      }
    }
    // R17: focus only a live session whose profileKey IS the matched identity.
    for (final s in _liveSessions()) {
      if (s.profileKey == authorised.identityKey) {
        _setActive(s.id);
        _log?.call('ui.link', 'route=focused sid=${s.id}');
        if (verb == null) return;
        // #1211: this shell is already attached (by a link) to the verb's
        // tmux session → only the window changes, over the session's exec
        // channel. Nothing is typed into the PTY, so R23 has nothing to
        // confirm, and a second attach would be a nested-tmux error.
        if (verb is TmuxAttach &&
            verb.window != null &&
            _isTmuxAttached(s.id, verb.name)) {
          _log?.call('ui.link', 'window select sid=${s.id}');
          await _selectWindow(s.id, verb);
          return;
        }
        // R23 option (b): the bytes would land wherever the live PTY's
        // foreground is (an editor, a password prompt, a nested ssh), and
        // linkAutoConnect only vouched for the destination — so the send is
        // ALWAYS confirmed in the terminal, and only the tap sends.
        if (await _confirmSend(authorised, verb)) {
          _log?.call('ui.link', 'verb sent sid=${s.id}');
          _sendVerb(s.id, verb);
          // #1211: the window select follows the attach it was confirmed with.
          if (verb is TmuxAttach && verb.window != null) {
            await _selectWindow(s.id, verb);
          }
        } else {
          _log?.call('ui.link', 'verb cancelled sid=${s.id}');
        }
        return;
      }
    }
    _log?.call('ui.link', 'route=connect${verb == null ? '' : ' verb'}');
    await _connectProfile(authorised, verb);
  }

  /// R26/R27: one neutral banner + one redacted line. Nothing else.
  void _rejected(String detail) {
    _log?.call('ui.link', 'rejected $detail');
    _reject();
  }
}
