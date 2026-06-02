// Settings section on the Connect form (#512, #552).
//
// Exposes the keep-alive-in-background toggle (#512) and the terminal
// font-size slider (#552). The font size persists via `fontSizeProvider`
// (SharedPreferences) and is applied live to the terminal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/keepalive_providers.dart';
import '../state/terminal_backend.dart';
import '../state/ui_prefs_providers.dart';

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final backend = ref.watch(terminalBackendProvider);
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
        // #684: terminal rendering backend. xterm is the default and only
        // production-proven path; ghostty (flterm) is opt-in for native
        // drag-select (#582). Read at terminal build time -> restart-to-apply.
        ListTile(
          key: const ValueKey('terminal-backend-tile'),
          title: const Text('Terminal engine'),
          subtitle: const Text(
            'xterm is the default. Ghostty (flterm) adds native drag-select '
            'and copy. Switching applies to new sessions / after a restart.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<TerminalBackend>(
            key: const ValueKey('terminal-backend-selector'),
            segments: const [
              ButtonSegment(
                value: TerminalBackend.xterm,
                label: Text('xterm'),
                icon: Icon(Icons.terminal_outlined),
              ),
              ButtonSegment(
                value: TerminalBackend.ghostty,
                label: Text('Ghostty'),
                icon: Icon(Icons.flash_on_outlined),
              ),
            ],
            selected: {backend},
            onSelectionChanged: (sel) =>
                ref.read(terminalBackendProvider.notifier).set(sel.first),
          ),
        ),
      ],
    );
  }
}
