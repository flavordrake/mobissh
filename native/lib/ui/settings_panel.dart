// Settings section on the Connect form (#512, #552).
//
// Exposes the keep-alive-in-background toggle (#512) and the terminal
// font-size slider (#552). The font size persists via `fontSizeProvider`
// (SharedPreferences) and is applied live to the terminal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/keepalive_providers.dart';
import '../state/ui_prefs_providers.dart';

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    final fontSize = ref.watch(fontSizeProvider);
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
          onChanged: (v) => ref.read(keepaliveEnabledProvider.notifier).set(v),
        ),
        ListTile(
          key: const ValueKey('font-size-tile'),
          title: const Text('Terminal font size'),
          subtitle: Text('${fontSize.toStringAsFixed(0)} px'),
          trailing: Text(
            fontSize.toStringAsFixed(0),
            key: const ValueKey('font-size-value'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            key: const ValueKey('font-size-slider'),
            min: kFontSizeMin,
            max: kFontSizeMax,
            divisions: (kFontSizeMax - kFontSizeMin).round(),
            value: fontSize.clamp(kFontSizeMin, kFontSizeMax),
            label: fontSize.toStringAsFixed(0),
            onChanged: (v) => ref.read(fontSizeProvider.notifier).set(v),
          ),
        ),
      ],
    );
  }
}
