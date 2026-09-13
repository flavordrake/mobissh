// #1141 (PR C of #1117) — `mobissh://` link wiring.
//
// Binds the pure [ConnectLinkRouter] to the live app: the FFT-backed pending
// record (process-death-surviving, R18), the session collection (R17), the
// R12 confirmation / R14 picker dialogs (via [appNavigatorKey]), and the
// hand-off of a matched, authorised profile to ConnectForm's
// `_connectFromProfile` through [pendingLinkConnectProvider] — so the TOFU
// listener (R15), the missing-creds → editor fallback (R13a) and
// `_popWhenConnected` (R21) are all reused instead of a new headless path.

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/connect_trace.dart';
import '../main.dart' show ConnectHomePage;
import '../services/attention_notifier_fln.dart';
import '../services/connect_link_router.dart';
import '../services/link_verb.dart';
import '../services/session_attention_notification.dart';
import '../ssh/ssh_session.dart';
import '../storage/profiles_store.dart';
import '../ui/link_dialogs.dart';
import '../ui/profile_editor.dart';
import 'profiles_providers.dart';
import 'sessions.dart';

/// The app's root Navigator key — shared with `MobisshApp` so link dialogs
/// and the pushed home route work from outside the widget tree.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// The hand-off record: the matched + authorised profile and, for a v1.1 link,
/// the typed verb to arm INSTEAD of the profile's initialCommand (R25).
class PendingLinkConnect {
  const PendingLinkConnect(this.profile, {this.verb});
  final SavedProfile profile;
  final LinkVerbCommand? verb;
}

/// One-shot hand-off: a matched + authorised profile ConnectForm should
/// connect exactly as a profile-row tap would. ConnectForm clears it on read.
final pendingLinkConnectProvider =
    StateProvider<PendingLinkConnect?>((_) => null);

/// Home-screen `Link not recognized` banner (R26). Persistent until dismissed
/// or the next link.
final linkRejectedProvider = StateProvider<bool>((_) => false);

/// Delivery seam wrapping `app_links` so tests never touch the plugin.
///
/// Stream-only on purpose: `stringLinkStream` replays the cold-start link on
/// first listen, so exposing `getInitialLink` here would let a caller deliver
/// it twice. Cold and warm links both arrive through [links].
abstract class LinkIntentSource {
  Stream<String> get links;
}

class AppLinksIntentSource implements LinkIntentSource {
  final AppLinks _links = AppLinks();
  @override
  Stream<String> get links => _links.stringLinkStream;
}

final linkIntentSourceProvider =
    Provider<LinkIntentSource>((_) => AppLinksIntentSource());

/// Process-death-surviving store for the pending record (FFT-backed like the
/// attention bridge). Tests override with a `MapKeyValueStore`.
final linkPendingStoreProvider =
    Provider<KeyValueStore>((_) => const FftKeyValueStore());

final connectLinkRouterProvider = Provider<ConnectLinkRouter>((ref) {
  Future<void> handOff(SavedProfile profile, LinkVerbCommand? verb) async {
    ref.read(linkRejectedProvider.notifier).state = false;
    ref.read(pendingLinkConnectProvider.notifier).state =
        PendingLinkConnect(profile, verb: verb);
    // A mounted ConnectForm consumes the hand-off synchronously via its
    // listener; if nothing took it, a terminal is showing — push the home
    // page over it so ConnectForm mounts and consumes on init.
    if (ref.read(pendingLinkConnectProvider) != null) {
      await appNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => const ConnectHomePage(fromSession: true),
        ),
      );
    }
  }

  return ConnectLinkRouter(
    bridge: PendingLinkBridge(ref.read(linkPendingStoreProvider), log: ctrace),
    log: ctrace,
    loadProfiles: () => ref.read(profilesStoreProvider).load(),
    liveSessions: () => [
      for (final e in ref.read(sessionsProvider).entries)
        if (e.proxy.data.state == SshSessionState.connected)
          LiveSessionRef(id: e.id, profileKey: e.profileKey),
    ],
    setActive: (id) => ref.read(sessionsProvider.notifier).setActive(id),
    confirm: (profile, verb) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return null;
      return showLinkConfirmDialog(ctx, profile, verb: verb);
    },
    confirmSend: (profile, verb) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return false;
      return showLinkVerbRunDialog(ctx, profile, verb);
    },
    sendVerb: (sessionId, verb) {
      for (final e in ref.read(sessionsProvider).entries) {
        if (e.id != sessionId) continue;
        ref.read(initialCommandRunnerProvider).sendNow(
              sessionId: e.id,
              proxy: e.proxy,
              command: verb,
            );
        return;
      }
      ctrace('ui.link', 'sendVerb: session gone sid=$sessionId');
    },
    pick: (candidates) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return null;
      return showLinkPickerDialog(ctx, candidates);
    },
    persistAutoConnect: (profile) async {
      await ref.read(profilesStoreProvider).upsert(profile);
      ref.invalidate(savedProfilesProvider);
    },
    connectProfile: handOff,
    openCreate: (draft) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return;
      // Nothing is persisted until the user saves (R14); "Save & connect" then
      // takes the same hand-off a confirmed link does.
      final result = await showProfileEditor(ctx, draft);
      if (result?.saved ?? false) ref.invalidate(savedProfilesProvider);
      final toConnect = result?.connect;
      // No verb on this path: `create` can't carry one (parser), and for an
      // unmatched `connect` host the editor is the confirmation — it does not
      // name a command (R16), so "Save & connect" is a plain profile connect.
      if (toConnect != null) await handOff(toConnect, null);
    },
    reject: () => ref.read(linkRejectedProvider.notifier).state = true,
  );
});
