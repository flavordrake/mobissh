// MobiSSH native — Flutter port of the PWA (#501).
//
// Phase 1: connect form + SSH lifecycle.
// Phase 2.A: route to TerminalScreen when `connected`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics/crash_reporter.dart';
import 'ssh/ssh_session.dart';
import 'state/connection_providers.dart';
import 'state/keepalive_providers.dart';
import 'state/lifecycle_providers.dart';
import 'state/sessions.dart';
import 'state/terminal_providers.dart';
import 'ui/connect_form.dart';
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
    // back to the UI (#512). Cheap, idempotent — fine to always call.
    FlutterForegroundTask.initCommunicationPort();
    runApp(const ProviderScope(child: MobisshApp()));
  });
}

class MobisshApp extends StatelessWidget {
  const MobisshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppLifecycleObserver(
      child: MaterialApp(
        title: 'MobiSSH',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const RootRouter(),
      ),
    );
  }
}

/// Switches between the connect form and the live terminal based on the
/// session collection. Multi-session (#511): show the terminal screen as
/// soon as any session reaches `connected`. The terminal screen itself
/// handles the tab strip and per-session views.
class RootRouter extends ConsumerWidget {
  const RootRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Touch the keepalive controller so it attaches to the SSH session
    // controller at app start; this is what starts/stops the foreground
    // service in response to session lifecycle changes (#512). It watches
    // the active-session shim — multi-session-wide handover is the follow-up
    // tracked in the #512 TODO.
    ref.watch(keepaliveControllerProvider);
    final entries = ref.watch(sessionsProvider).entries;
    for (final e in entries) {
      // Watch each session's data so we re-route when any of them connects.
      final data = ref.watch(sessionDataProvider(e.id)).valueOrNull;
      if (data?.state == SshSessionState.connected) {
        return const TerminalScreen();
      }
    }
    return const ConnectHomePage();
  }
}

class ConnectHomePage extends ConsumerWidget {
  const ConnectHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MobiSSH'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: const [
              ConnectForm(),
              Divider(),
              _StatusPanel(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPanel extends ConsumerWidget {
  const _StatusPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sshSessionDataProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Provider error: $e'),
      ),
      data: (data) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('State: ${data.state.name}',
                style: Theme.of(context).textTheme.titleMedium),
            if (data.host != null)
              Text('Target: ${data.username}@${data.host}:${data.port}'),
            if (data.remoteVersion != null)
              Text('Server: ${data.remoteVersion}'),
            if (data.banner != null && data.banner!.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Banner:'),
              SelectableText(
                data.banner!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
            if (data.error != null) ...[
              const SizedBox(height: 8),
              Text('Error: ${data.error}',
                  style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }
}
