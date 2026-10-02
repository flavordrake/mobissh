// Settings view — the single Settings page reached from the home bottom-nav
// (#611, #897, #966, #1257).
//
// The user-facing settings ([SettingsPanel], five sections) are top-level. The
// developer-facing [DiagnosticsSection] sits in a COLLAPSED "Advanced"
// expander. #1257: Advanced ends with ONE "Show experimental settings" switch
// that reveals the experimental items (tmux control mode, Force upload,
// Connection audit). Hiding is display-only: when a hidden setting is ON,
// Advanced says so and the note reveals it. Reset sits at the very bottom.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/feature_flags_providers.dart';
import 'diagnostics_section.dart';
import 'settings_panel.dart';
import 'settings_subheader.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showExperimental = ref.watch(featureFlagsProvider).showExperimental;
    // Watched unconditionally: this eager build (the home IndexedStack) is what
    // constructs + hydrates tmuxControlModeProvider before the first connect
    // reads its global. The collapsed tile alone would not build it.
    final onCount = ref.watch(experimentalSettingsOnCountProvider);
    final hiddenOn = showExperimental ? 0 : onCount;
    final hiddenOnLabel = hiddenOn == 1
        ? '1 experimental setting is on'
        : '$hiddenOn experimental settings are on';
    final flags = ref.read(featureFlagsProvider.notifier);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsPanel(),
            const SizedBox(height: 8),
            ExpansionTile(
              key: const ValueKey('settings-advanced-tile'),
              leading: const Icon(Icons.tune_outlined),
              title: const Text('Advanced'),
              // Visible while collapsed, so a hidden setting never changes
              // behaviour unannounced.
              subtitle: hiddenOn > 0 ? Text(hiddenOnLabel) : null,
              childrenPadding: EdgeInsets.zero,
              children: [
                DiagnosticsSection(experimental: showExperimental),
                if (showExperimental) ...const [
                  SettingsSubheader('Experimental'),
                  TmuxControlModeTile(),
                ],
                if (hiddenOn > 0)
                  ListTile(
                    key: const ValueKey('experimental-on-note'),
                    leading: const Icon(Icons.info_outline),
                    title: Text(hiddenOnLabel),
                    subtitle: const Text('Tap to show experimental settings.'),
                    onTap: () => flags.setShowExperimental(true),
                  ),
                SwitchListTile(
                  key: const ValueKey('show-experimental-toggle'),
                  secondary: const Icon(Icons.science_outlined),
                  title: const Text('Show experimental settings'),
                  subtitle: const Text(
                    'tmux control mode, Force upload and Connection audit.',
                  ),
                  value: showExperimental,
                  onChanged: flags.setShowExperimental,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SettingsResetButton(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
