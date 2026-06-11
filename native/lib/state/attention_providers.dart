// Attention focus router provider (#840, Slice 2).
//
// Wires the pure [AttentionFocusRouter] to the live UI: the FFT-backed
// [PendingFocusBridge] (process-death-surviving), `sessionsProvider.setActive`,
// session existence, and PTY input for the guarded tmux select-window.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/connect_trace.dart';
import '../platform/desktop.dart';
import '../services/attention_focus_router.dart';
import '../services/attention_notifier_fln.dart';
import '../services/attention_tap_ui.dart';
import '../services/session_attention_notification.dart';
import '../ssh/ssh_connect_params.dart';
import '../storage/profiles_store.dart';
import 'profiles_providers.dart';
import 'sessions.dart';

/// Builds the [AttentionFocusRouter] bound to the live session collection.
///
/// `isTmux` heuristic: the `(win N)` source-window hint is emitted by the
/// owner's tmux `alert-bell` hook — a non-tmux shell does not produce it — so a
/// parsed hint is itself a strong tmux signal. We therefore treat any session
/// that reached the router with a hint as a tmux client. (A precise per-session
/// tmux flag from the DA2 handshake is a future refinement; the navigation is
/// device-gated + best-effort and skips silently on a miss either way.)
final attentionFocusRouterProvider = Provider<AttentionFocusRouter>((ref) {
  // #870: bind the bridge's pending-WRITE log to `ctrace` so the write lands in
  // the uploaded connect-log (the UI-isolate consume side). The cold/warm
  // consume happens here in the UI isolate; foreground/background tap WRITES
  // happen in the task / background isolate (see attention_notifier_fln.dart),
  // which bind their own ctrace.
  final bridge = PendingFocusBridge(const FftKeyValueStore(), log: ctrace);
  return AttentionFocusRouter(
    bridge: bridge,
    // #870: route the CONSUME focus decision through `ctrace` so the resolved
    // route (setActive / host-fallback / none) is captured in the connect-log.
    log: ctrace,
    setActive: (id) => ref.read(sessionsProvider.notifier).setActive(id),
    sessionExists: (id) =>
        ref.read(sessionsProvider).entries.any((e) => e.id == id),
    sendInput: (id, bytes) {
      for (final e in ref.read(sessionsProvider).entries) {
        if (e.id == id) {
          e.proxy.sendInput(Uint8List.fromList(bytes));
          return;
        }
      }
    },
    // #857: host fallback. When the tapped notification's EXACT sessionId is no
    // longer live (the host reconnected with a new `createdAtMs` nonce), route
    // to the MOST-RECENT live session for that host — never the previously-active
    // session to a different host. Session id format is
    // `host:port:user:createdAtMs`, so "most recent" = the largest trailing
    // createdAt segment among entries whose host matches.
    resolveLiveSessionForHost: (host) {
      String? bestId;
      int bestCreatedAt = -1;
      for (final e in ref.read(sessionsProvider).entries) {
        if (hostOfSessionId(e.id) != host) continue;
        final lastColon = e.id.lastIndexOf(':');
        final createdAt = lastColon < 0
            ? -1
            : (int.tryParse(e.id.substring(lastColon + 1)) ?? -1);
        if (createdAt >= bestCreatedAt) {
          bestCreatedAt = createdAt;
          bestId = e.id;
        }
      }
      return bestId;
    },
    // #885: dead-host tap → reconnect the host's PROFILE through the EXISTING
    // connect flow (the same addOrActivate + proxy.connect path a profile-row
    // tap takes — see connect_form `_connectFromProfile` and
    // `SessionsNotifier._reviveFromProfile`). Resolves to the new session's id
    // once the entry exists so the router can focus it; null when no saved
    // profile matches the host or it has no usable stored credentials (then
    // the router cancels the notification instead).
    reconnectHost: (host) => _reconnectHostFromProfile(ref, host),
    // #885: dead-host tap with no reconnectable profile → cancel the host's
    // notification so it can't dangle. Deliberately a BARE plugin cancel (the
    // shared tag/id helpers guarantee it addresses the posted slot), NOT
    // `FlnAttentionNotifier.cancel` — its lazy `_ensureInit` would re-run
    // `plugin.initialize` in this (UI) isolate and clobber the #878
    // tap-binding registration. By tap time the UI isolate is already
    // initialized via [attentionUiFlnInitProvider].
    cancelHostNotification: (host) async {
      final tag = attentionTagForHost(host);
      await FlutterLocalNotificationsPlugin()
          .cancel(attentionIdForTag(tag), tag: tag);
    },
    // See doc above: a parsed (win N) hint implies the owner's tmux setup.
    isTmux: (_) => true,
    // #710: open an explicitly-signalled URL from the tapped notification in the
    // system browser. Same idiom as url_action_overlay's _defaultOpen. The
    // router guards to well-formed http(s) and swallows launch errors.
    openUrl: (url) async {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    },
  );
});

/// Dead-host tap reconnect (#885): resolve [host]'s saved profile + vault
/// credentials and re-connect through the EXISTING connect flow
/// (`sessionsProvider.notifier.addOrActivate` + `proxy.connect` — the same
/// path a profile-row / recent-session tap takes, and the same credential
/// resolution as `SessionsNotifier._reviveFromProfile`). Returns the new
/// session's id once the entry exists (the router focuses it), or null when no
/// profile matches the host / it has no usable stored secret — the router then
/// cancels the dangling notification instead. Best-effort: any failure resolves
/// null (→ cancel), never throws into the tap.
Future<String?> _reconnectHostFromProfile(Ref ref, String host) async {
  try {
    final profiles = await ref.read(profilesStoreProvider).load();
    SavedProfile? match;
    for (final p in profiles) {
      if (p.host == host) {
        match = p;
        break;
      }
    }
    if (match == null) {
      ctrace('ui.attention', 'reconnectHost: no profile for host=$host');
      return null;
    }
    final secrets = ref.read(secretsStoreProvider);
    final creds = await loadProfileCredentials(secrets, match);
    final wantsKey =
        match.authType == 'key' ||
        (match.authType == null &&
            (creds.privateKey != null && creds.privateKey!.isNotEmpty));
    final SshAuth? auth;
    if (wantsKey && creds.privateKey != null && creds.privateKey!.isNotEmpty) {
      auth = SshAuth.key(
        Uint8List.fromList(utf8.encode(creds.privateKey!)),
        passphrase: (creds.passphrase == null || creds.passphrase!.isEmpty)
            ? null
            : creds.passphrase,
      );
    } else if (!wantsKey &&
        creds.password != null &&
        creds.password!.isNotEmpty) {
      auth = SshAuth.password(creds.password!);
    } else {
      auth = null;
    }
    if (auth == null) {
      ctrace(
        'ui.attention',
        'reconnectHost: no stored creds for host=$host — cannot reconnect',
      );
      return null;
    }
    final params = SshConnectParams(
      host: match.host,
      port: match.port,
      username: match.username,
      auth: auth,
    );
    // The existing connect flow: addOrActivate dedupes by host:port:user,
    // starts the keepalive service, creates the per-session proxy + terminal,
    // and makes the new entry active; the connect is dispatched on its proxy.
    final entry = ref
        .read(sessionsProvider.notifier)
        .addOrActivate(params, title: match.title);
    unawaited(entry.proxy.connect(params, title: match.title));
    return entry.id;
  } catch (e) {
    ctrace('ui.attention', 'reconnectHost failed for host=$host: $e');
    return null;
  }
}

/// UI-isolate FLN registration (#878). MUST run at app boot, BEFORE the boot
/// path's initial `consumePending()`.
///
/// Root cause being fixed: `initialize()` was only ever called in the FGS task
/// isolate (for posting). A plain notification tap resumes MainActivity → the
/// UI engine, and the plugin delivers `onDidReceiveNotificationResponse` only
/// to the isolate that initialized it IN THAT ENGINE — so every tap payload
/// was dropped and the pending-focus write never happened (the confirmed root
/// of the #857/#870 wrong-host saga).
///
/// This provider:
///   1. initializes FLN in the UI isolate via the SHARED
///      [initializeAttentionFln] (same settings + idempotent channel creation
///      as the task isolate — no copy-paste drift), with a tap handler that
///      writes pending AND immediately consumes (the tap IS the resume);
///   2. checks `getNotificationAppLaunchDetails()`: a process-death tap seeds
///      pending BEFORE the initial consume runs (`main.dart` awaits this
///      provider's future first).
///
/// Telemetry flows through `clifecycle` (#766): its durable 80-line ring ships
/// in the feedback upload and survives connect-ring churn. Desktop (#577) has
/// no FLN/FGS machinery → no-op.
final attentionUiFlnInitProvider = FutureProvider<void>((ref) async {
  if (ref.watch(isDesktopProvider)) return;
  final binding = AttentionUiTapBinding(
    // clifecycle-bound bridge: the pending WRITE line lands in the uploaded
    // lifecycle ring (the task/background-isolate writes only reach logcat).
    bridge: PendingFocusBridge(const FftKeyValueStore(), log: clifecycle),
    consume: () => ref.read(attentionFocusRouterProvider).consumePending(),
    log: clifecycle,
  );
  final plugin = FlutterLocalNotificationsPlugin();
  await initializeAttentionFln(
    plugin,
    onResponse: (response) => unawaited(binding.handleTap(response.payload)),
  );
  clifecycle('ui.attention', 'fln: UI-isolate tap handler registered');
  // Cold start: a tap on a dead process launches the app with the response in
  // the launch details — seed it as pending so the initial consume routes it.
  final details = await plugin.getNotificationAppLaunchDetails();
  if (details?.didNotificationLaunchApp ?? false) {
    await binding.seedColdStart(details!.notificationResponse?.payload);
  }
});
