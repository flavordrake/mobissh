// MobiSSH native — Flutter port of the PWA (#501).
//
// Phase 1: connect form + SSH lifecycle.
// Phase 2.A: route to TerminalScreen when `connected`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics/connect_trace.dart';
import 'diagnostics/crash_reporter.dart';
import 'platform/desktop.dart';
import 'ssh/ssh_session.dart';
import 'state/attention_providers.dart';
import 'state/connection_providers.dart';
import 'state/keepalive_providers.dart';
import 'state/lifecycle_providers.dart';
import 'state/sessions.dart';
import 'state/terminal_providers.dart';
import 'ui/connect_form.dart';
import 'ui/diagnostics_screen.dart';
import 'ui/feedback_overlay.dart';
import 'ui/settings_screen.dart';
import 'ui/terminal_screen.dart';

void main() {
  // CrashReporter.runGuarded wraps the entire app in a zone that captures
  // uncaught Dart errors. It must be the OUTERMOST call so a crash during
  // engine init still flows through the reporter. See lessons-from-pwa.md
  // for the "user installs APK, app crashes silently" failure mode.
  CrashReporter.runGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await CrashReporter.bootstrap();
    // Fire-and-forget — don't block first paint on bridge reachability.
    unawaited(CrashReporter.uploadPending());
    // Open the isolate port so the foreground task isolate can send data
    // back to the UI (#512). Android-only: `flutter_foreground_task` is not
    // available on desktop (macOS / Linux / Windows, #577) where there is no
    // task isolate — calling it would throw `MissingPluginException` at boot.
    if (!kIsDesktop) {
      FlutterForegroundTask.initCommunicationPort();
    }
    runApp(const ProviderScope(child: MobisshApp()));
  });
}

class MobisshApp extends StatelessWidget {
  const MobisshApp({super.key});

  // Created once (static) so they survive rebuilds. The feedback overlay is
  // mounted ABOVE the Navigator via `builder:`, so it can't resolve a
  // Navigator/ScaffoldMessenger from its own context — it shows its sheet +
  // confirmation through these keys instead (the "just blinks" fix).
  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return AppLifecycleObserver(
      child: MaterialApp(
        title: 'MobiSSH',
        navigatorKey: _navigatorKey,
        scaffoldMessengerKey: _messengerKey,
        // Default LIGHT (temporary, this build): an unmistakable visual signal
        // that a fresh APK actually installed/updated, so we can separate
        // "build didn't update" from "feature still broken" while closing the
        // device-bug loop. Terminal palette is independent (terminalThemeProvider).
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        // #661: mount the app-wide in-app feedback affordance via `builder` so
        // it floats over EVERY screen AND every pushed route (file browser,
        // pdf viewer) — the builder wraps the Navigator. One tap captures the
        // current screen + a full multi-line comment and submits to the
        // /api/bug-report pipeline. The RepaintBoundary lives inside
        // FeedbackOverlay so the capture rasterizes the live route.
        builder: (context, child) {
          return FeedbackOverlay(
            navigatorKey: _navigatorKey,
            messengerKey: _messengerKey,
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const RootRouter(),
      ),
    );
  }
}

/// Switches between the connect form and the live terminal based on the
/// session collection. Multi-session (#511): show the terminal screen as
/// soon as any session reaches `connected`. The terminal screen itself
/// handles the tab strip and per-session views.
class RootRouter extends ConsumerStatefulWidget {
  const RootRouter({super.key});

  @override
  ConsumerState<RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends ConsumerState<RootRouter> {
  /// Session ids that have been observed in `connected` at least once (#624).
  /// Lets the router keep the terminal screen mounted for a session that
  /// dropped (→ disconnected/failed) rather than snapping back to the chooser
  /// and hiding the disconnect banner. Pruned to live entries each build.
  final Set<String> _everConnected = <String>{};

  @override
  void initState() {
    super.initState();
    // #840 Slice 2: cold-start consume of a pending attention focus. If the app
    // was launched (process was dead) by tapping an attention notification, the
    // tap recorded a pending focus in process-death-surviving storage. Consume
    // it once the first frame settles so sessions exist to focus. Deferred to a
    // post-frame callback so provider reads happen after the widget mounts.
    //
    // #878: BEFORE that initial consume, register the UI-isolate FLN tap
    // handler + seed any cold-start launch-details payload
    // (attentionUiFlnInitProvider). Without the UI-isolate registration a
    // plain tap delivers to this engine where no handler exists — the payload
    // was silently dropped (the #857/#870 root cause). Ordering matters: the
    // launch-details seed must land before consumePending reads the store.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_initAttentionTapThenConsume());
    });
  }

  /// #878 boot ordering: UI-isolate FLN init (+ cold-start launch-details
  /// seed) FIRST, then the initial pending-focus consume. Init failures are
  /// logged but never block the consume — a tap recorded by the background
  /// handler must still route on a degraded boot.
  Future<void> _initAttentionTapThenConsume() async {
    try {
      await ref.read(attentionUiFlnInitProvider.future);
    } catch (e) {
      clifecycle('ui.attention', 'fln: UI-isolate init failed: $e');
    }
    if (!mounted) return;
    await ref.read(attentionFocusRouterProvider).consumePending();
  }

  @override
  Widget build(BuildContext context) {
    // Touch the keepalive controller so it attaches to the SSH session
    // controller at app start; this is what starts/stops the foreground
    // service in response to session lifecycle changes (#512). It watches
    // the active-session shim — multi-session-wide handover is the follow-up
    // tracked in the #512 TODO.
    ref.watch(keepaliveControllerProvider);

    // #738: arm the one-time battery-optimization auto-prompt. Fires the OS
    // exemption dialog the first time a session connects (at most once ever),
    // so Doze stops deferring the app's network / freezing the keepalive timer
    // and ordinary screen-off sleeps don't drop live sessions. Only OBSERVES
    // the sessions list — does not touch the connect/resume state machine
    // (#737). No-op on desktop.
    ref.watch(batteryOptimizationFirstConnectTriggerProvider);

    // #551: keep the always-on resume-rebind listener alive for the lifetime
    // of the app. Unlike the inline `ref.listen` below (which dies when this
    // router unmounts to show TerminalScreen), this provider rebinds every
    // live session on resume even while the user is on the terminal screen.
    ref.watch(resumeRebindListenerProvider);

    // #847: when the front-most session changes while the app is FOREGROUNDED
    // (a tab switch — `sessionsProvider.notifier.setActive`), push the new
    // active session id + HOST to the task isolate so attention suppression
    // follows the user. Without this the task only learned the active session on
    // pause/resume, so switching tabs while foregrounded left a stale activeHost
    // and suppressed/fired against the wrong Claude. Only fires on a real
    // activeId change (not every list mutation) and only while foregrounded
    // (pause/resume already pushes the state on lifecycle edges).
    ref.listen<String?>(activeSessionIdProvider, (prevId, nextId) {
      if (!mounted) return;
      if (prevId == nextId) return;
      final sessions = ref.read(sessionsProvider);
      final entries = sessions.entries;
      if (entries.isEmpty) return;
      // #936: derive id + HOST from the FRONT-MOST tab entry, not
      // `sessions.active`/`activeId`. A disconnected/transitioning front-most
      // session leaves `active` null, which previously propagated
      // activeSessionId=null/activeHost=null and let a same-host bell escape
      // suppression while the user was still on that very tab. The front-most
      // entry's host is always derivable regardless of connection state.
      entries.first.proxy.setActive(
        true,
        activeSessionId: sessions.frontActiveId,
        activeHost: sessions.frontActiveHost,
      );
    });

    // Phase 4 (#524) lifecycle hook: on `resumed`, force a rebuild so
    // session UI repaints from the existing controller state without
    // reconnecting. The SshSessionController instances live in this isolate
    // and keep their `_client` references across pause/resume; the
    // foreground service (started by KeepaliveController on `connected`)
    // keeps the Dart isolate from being frozen during Doze.
    ref.listen<AppLifecycleState>(lifecycleProvider, (prev, next) {
      if (!mounted) return;
      if (next == AppLifecycleState.paused) {
        // #533: drop proxy event subscriptions during pause so the UI
        // doesn't accumulate state events while the foreground service keeps
        // SSH alive. Rebind on resume re-emits the cached snapshot so the
        // first paint is instant.
        final entries = ref.read(sessionsProvider).entries;
        // #806: tell the task we're backgrounded so it STOPS the 2s snapshot
        // push (the UI is about to unbind and discard snapshots — the push,
        // incl. a ~4KB scrollback decode, is wasted battery). Task-global, so
        // one send suffices. Does NOT touch the SSH socket / keepalive / locks.
        if (entries.isNotEmpty) {
          final sessions = ref.read(sessionsProvider);
          entries.first.proxy.setActive(
            false,
            // #936: front-most tab id/host, not `active`/`activeId` (null while
            // disconnected/transitioning).
            activeSessionId: sessions.frontActiveId,
            // #847: carry the active session's HOST so the task suppresses by
            // host (the unit of attention is the Claude/host). On background
            // `active:false` means nothing is suppressed anyway, but we send it
            // so the host's last-known activeHost stays accurate.
            activeHost: sessions.frontActiveHost,
          );
        }
        for (final e in entries) {
          e.proxy.unbind();
        }
      }
      if (next == AppLifecycleState.resumed) {
        // The keepalive controller already kept the SSH socket alive (#517
        // reconnect-on-transient + #512 foreground service). On resume we
        // rebind every proxy so each one re-emits its cached snapshot
        // (#524 500ms rebind budget) and requests a fresh task-side
        // snapshot. The setState forces the router to re-resolve route
        // selection from the now-current session data.
        final entries = ref.read(sessionsProvider).entries;
        // #806: tell the task we're foregrounded again so it RESTORES the 2s
        // snapshot timer and emits one fresh full snapshot per session
        // immediately (instant repaint). Task-global → one send. The per-proxy
        // rebind below still runs the cached-frame repaint + SshRequestSnapshot.
        if (entries.isNotEmpty) {
          final sessions = ref.read(sessionsProvider);
          entries.first.proxy.setActive(
            true,
            // #936: front-most tab id/host, not `active`/`activeId` (null while
            // disconnected/transitioning).
            activeSessionId: sessions.frontActiveId,
            // #847: carry the active session's HOST so the task host-suppresses
            // a bell from any (possibly different) session to the same host.
            activeHost: sessions.frontActiveHost,
          );
        }
        for (final e in entries) {
          e.proxy.rebind();
        }
        // #840 Slice 2: a tapped attention notification recorded a pending focus
        // that survives process death. Consume it on resume (warm) — switch to
        // the originating session and, if it parses a `(win N)` hint and that
        // session is a tmux client, select that window.
        unawaited(ref.read(attentionFocusRouterProvider).consumePending());
        setState(() {});
      }
    });

    final entries = ref.watch(sessionsProvider).entries;
    var showTerminal = false;
    for (final e in entries) {
      // Watch each session's data so we re-route when any of them connects —
      // OR when a previously-live session drops (#624).
      final state =
          ref.watch(sessionDataProvider(e.id)).valueOrNull?.state ??
          SshSessionState.idle;
      if (state == SshSessionState.connected) {
        // A session reached `connected` at least once. Remember it so a later
        // drop (→ disconnected/failed) keeps the terminal mounted instead of
        // snapping back to the chooser (#624 root cause).
        _everConnected.add(e.id);
        showTerminal = true;
        continue;
      }
      // #624: a KEPT-but-dead entry must keep the terminal screen mounted so
      // the disconnect banner shows + the input gate holds, rather than
      // silently navigating to the chooser leaving no indication. We only do
      // this for sessions that were ONCE live:
      //   - softDisconnected / reconnecting are reachable ONLY from `connected`
      //     (see SshSessionController.handleTransportClosed), so they always
      //     mean "was live — now dropped".
      //   - disconnected / failed are ambiguous (a first connect that never
      //     succeeded also fails), so we additionally require that this id was
      //     observed `connected` at some point (_everConnected). A never-live
      //     failed/disconnected entry stays on the chooser so the host-key
      //     prompt + connect error render there (preserves first-connect UX).
      // Pre-first-connect states (idle/connecting/authenticating/
      // awaitingHostKey) NEVER route to the terminal.
      switch (state) {
        case SshSessionState.softDisconnected:
        case SshSessionState.reconnecting:
          showTerminal = true;
        case SshSessionState.disconnected:
        case SshSessionState.failed:
          if (_everConnected.contains(e.id)) showTerminal = true;
        case SshSessionState.idle:
        case SshSessionState.connecting:
        case SshSessionState.awaitingHostKey:
        case SshSessionState.authenticating:
        case SshSessionState.connected:
          break;
      }
    }
    // Drop bookkeeping for ids no longer in the collection (close()d sessions)
    // so the set can't grow unbounded across many connect/close cycles.
    if (_everConnected.isNotEmpty) {
      final live = entries.map((e) => e.id).toSet();
      _everConnected.removeWhere((id) => !live.contains(id));
    }
    if (showTerminal) return const TerminalScreen();
    return const ConnectHomePage();
  }
}

/// Pushes the FULL [ConnectHomePage] (Profiles / Settings / Diagnostics) as a
/// route OVER the live terminal so the user can reach profiles + every setting
/// WITHOUT disconnecting any session (#721). The sessions collection is left
/// untouched — pushing a route doesn't close or pause sessions, so the
/// foreground-service keep-alive and the active-session selection persist
/// underneath. The pushed route can pop (`Navigator.canPop()` is true), so:
///   - [ConnectHomePage]'s AppBar auto-shows a back arrow + system back pops →
///     returns to the previously-active session(s) (the router keeps showing
///     [TerminalScreen] because the sessions are still connected).
///   - The embedded [ConnectForm] pops this route itself once a NEW session
///     CONNECTS (`_popWhenConnected`), so "add connection" flows back to the
///     terminal exactly like the old "New session" route did.
///
/// This is the SAME view shown at first-run / cold start (the router's
/// zero-session branch) — there is no reduced connect form anymore. First-run,
/// "add connection", and "open settings from a session" are one unified view.
///
/// Navigation uses the passed [context]'s Navigator. Callers that live above
/// the Navigator (e.g. a `MaterialApp.builder` overlay) must instead route via
/// the app `navigatorKey` (the #664 "just blinks" trap) — the session menu /
/// session bar that call this sit BELOW the Navigator, so their context is fine.
Future<void> openConnectHome(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const ConnectHomePage(fromSession: true),
    ),
  );
}

/// The cold-start / home view (#583, reshaped in #611 Part A).
///
/// #611: the home is JUST the profile CHOOSER — tap = connect, pencil = edit,
/// plus "New connection" + Import. Settings and Diagnostics no longer clutter
/// the profile list as inline disclosures; they're separate destinations on a
/// [BottomNavigationBar] that open their own dedicated views ([SettingsScreen],
/// [DiagnosticsScreen]). The screens host the EXISTING settings/diagnostics
/// widgets unchanged so they can grow later (#611 follow-ups).
///
/// #721: the SAME page is also reachable on demand OVER a live session (pushed
/// by [openConnectHome] from the session menu / session bar) so profiles +
/// every setting are available without tearing down sessions. When pushed that
/// way [fromSession] is true: the route can pop, so the AppBar shows a back
/// arrow back to the active terminal, and the title makes the "over a session"
/// context legible. As the cold-start home (router's zero-session branch) it is
/// the root route — [fromSession] is false, nothing to pop, and the router
/// swaps to the terminal the moment any session connects.
///
/// Out of scope here (Part B, follow-up): PWA-style quick-reconnect / "session
/// set" bundles — that needs a recent-sessions store + PWA spec study.
///
/// Connection status is shown on the terminal screen (the router swaps to it
/// the moment any session connects).
class ConnectHomePage extends StatefulWidget {
  const ConnectHomePage({super.key, this.fromSession = false});

  /// True when pushed OVER a live terminal (#721) rather than shown as the
  /// cold-start root. Drives the back-to-session affordance + title only — the
  /// body (Profiles / Settings / Diagnostics) is identical in both cases.
  final bool fromSession;

  @override
  State<ConnectHomePage> createState() => _ConnectHomePageState();
}

class _ConnectHomePageState extends State<ConnectHomePage> {
  // 0 = Profiles (chooser), 1 = Settings, 2 = Diagnostics.
  int _index = 0;

  static const _titles = <String>['MobiSSH', 'Settings', 'Diagnostics'];

  @override
  Widget build(BuildContext context) {
    // IndexedStack keeps each destination's state alive across tab switches
    // (e.g. the connect-log scroll position, an in-flight diagnostics future)
    // rather than rebuilding from scratch on every tap.
    //
    // #721: when pushed OVER a live session the AppBar auto-shows a back arrow
    // (the route can pop), which returns to the active terminal. A tooltip +
    // key make that back affordance test-addressable. As the cold-start root
    // (fromSession == false) there's nothing to pop, so no back button shows.
    final leading = widget.fromSession
        ? IconButton(
            key: const Key('home-back-to-session'),
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to session',
            onPressed: () => Navigator.of(context).maybePop(),
          )
        : null;
    return Scaffold(
      appBar: AppBar(leading: leading, title: Text(_titles[_index])),
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: const [
            // #643: NO SingleChildScrollView — the chooser fills the body so
            // its profile list expands and scrolls internally. IndexedStack
            // gives ConnectForm a bounded height (its Expanded needs that).
            ConnectForm(),
            SettingsScreen(),
            DiagnosticsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        key: const Key('home-bottom-nav'),
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            key: Key('home-nav-profiles'),
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Profiles',
          ),
          NavigationDestination(
            key: Key('home-nav-settings'),
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
          NavigationDestination(
            key: Key('home-nav-diagnostics'),
            icon: Icon(Icons.bug_report_outlined),
            selectedIcon: Icon(Icons.bug_report),
            label: 'Diagnostics',
          ),
        ],
      ),
    );
  }
}
