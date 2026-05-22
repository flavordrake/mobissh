// MobiSSH native — Flutter port of the PWA (#501).
//
// Phase 1: connect form + SSH lifecycle. No terminal yet (Phase 2).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/connection_providers.dart';
import 'ui/connect_form.dart';

void main() {
  runApp(const ProviderScope(child: MobisshApp()));
}

class MobisshApp extends StatelessWidget {
  const MobisshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MobiSSH',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MobiSSH'),
      ),
      body: SafeArea(
        child: Column(
          children: const [
            ConnectForm(),
            Divider(),
            Expanded(child: _StatusPanel()),
          ],
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Provider error: $e')),
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
            const Spacer(),
            const Text(
              'Terminal view lands in Phase 2.',
              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
