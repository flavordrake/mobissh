// Connection Audit debug screen (#524).
//
// Per-session telemetry: state, reconnect count, time since last reconnect,
// host/port/username. The PWA never had this — its only diagnostic was
// connect-log.ts localStorage. The native app's audit screen is the
// production-visible counterpart of the redesign-doc telemetry layer; if
// quick-resume regresses, the audit reveals it before the user does.
//
// Reachable from the Diagnostics expansion in the Connect home (see
// `ui/diagnostics_section.dart`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sessions.dart';
import '../state/terminal_providers.dart';

class ConnectionAuditScreen extends ConsumerWidget {
  const ConnectionAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Audit'),
        leading: const BackButton(),
      ),
      body: SafeArea(
        child: sessions.entries.isEmpty
            ? const _EmptyState()
            : ListView.separated(
                key: const Key('connection-audit-list'),
                itemCount: sessions.entries.length,
                separatorBuilder: (_, _) => const Divider(height: 0),
                itemBuilder: (context, index) {
                  final entry = sessions.entries[index];
                  return _AuditRow(entry: entry);
                },
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No active sessions. Connect to a host and return here to see '
          'per-session telemetry.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _AuditRow extends ConsumerWidget {
  const _AuditRow({required this.entry});

  final SessionEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(sessionDataProvider(entry.id));
    // #533: state + reconnect counters now flow through the proxy's cached
    // snapshot rather than an in-UI controller. The snapshot is refreshed by
    // the task isolate's periodic snapshot tick + by `proxy.rebind()` on
    // `AppLifecycleState.resumed`.
    final snapshot = entry.proxy.snapshot;
    final state = dataAsync.valueOrNull?.state ?? snapshot.state;
    final reconnectCount = snapshot.reconnectCount;
    final lastReconnect = snapshot.lastReconnectAtMs;

    return Padding(
      key: Key('audit-row-${entry.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'State: ${state.name}',
            key: Key('audit-state-${entry.id}'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            'Reconnect attempts: $reconnectCount',
            key: Key('audit-reconnect-count-${entry.id}'),
          ),
          if (lastReconnect != null)
            Text(
              'Last reconnect: ${_formatAge(lastReconnect)}',
              key: Key('audit-last-reconnect-${entry.id}'),
            ),
          Text('Target: ${entry.username}@${entry.host}:${entry.port}'),
        ],
      ),
    );
  }

  static String _formatAge(int ms) {
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (age.inSeconds < 60) return '${age.inSeconds}s ago';
    if (age.inMinutes < 60) return '${age.inMinutes}m ago';
    return '${age.inHours}h ago';
  }
}
