// Settings section on the Connect form (#512).
//
// Currently exposes only the keep-alive-in-background toggle. Future
// settings (theme, font, etc.) will land here too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/keepalive_providers.dart';

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    return ExpansionTile(
      key: const ValueKey('settings-section'),
      leading: const Icon(Icons.settings_outlined),
      title: const Text('Settings'),
      subtitle: Text(
        keepalive
            ? 'Keep alive in background: ON'
            : 'Keep alive in background: OFF',
      ),
      children: [
        SwitchListTile(
          key: const ValueKey('keepalive-toggle'),
          title: const Text('Keep alive in background'),
          subtitle: const Text(
            'Show an ongoing notification so Android keeps the SSH '
            'session connected when you swap to another app.',
          ),
          value: keepalive,
          onChanged: (v) =>
              ref.read(keepaliveEnabledProvider.notifier).set(v),
        ),
      ],
    );
  }
}
