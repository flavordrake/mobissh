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

/// One-shot hand-off: a matched + authorised profile ConnectForm should
/// connect exactly as a profile-row tap would. ConnectForm clears it on read.
final pendingLinkConnectProvider = StateProvider<SavedProfile?>((_) => null);

/// Home-screen `Link not recognized` banner (R26). Persistent until dismissed
/// or the next link.
final linkRejectedProvider = StateProvider<bool>((_) => false);

/// Delivery seam wrapping `app_links` so tests never touch the plugin.
abstract class LinkIntentSource {
  Future<String?> initialLink();
  Stream<String> get links;
}

class AppLinksIntentSource implements LinkIntentSource {
  final AppLinks _links = AppLinks();
  @override
  Future<String?> initialLink() => _links.getInitialLinkString();
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
  Future<void> handOff(SavedProfile profile) async {
    ref.read(linkRejectedProvider.notifier).state = false;
    ref.read(pendingLinkConnectProvider.notifier).state = profile;
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
    confirm: (profile) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return null;
      return showLinkConfirmDialog(ctx, profile);
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
      if (toConnect != null) await handOff(toConnect);
    },
    reject: () => ref.read(linkRejectedProvider.notifier).state = true,
  );
});
