// Settings view — the single Settings page reached from the home bottom-nav
// (#611, #897, #966, #1257).
//
// The user-facing settings ([SettingsPanel], five sections) are top-level. The
// developer-facing [DiagnosticsSection] sits in a COLLAPSED "Advanced"
// expander. #1257: Advanced ends with ONE "Show experimental settings" switch
// that reveals the experimental items (Force upload, Connection audit). Reset
// sits at the very bottom.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/feature_flags_providers.dart';
import 'diagnostics_section.dart';
import 'settings_panel.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showExperimental = ref.watch(featureFlagsProvider).showExperimental;
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
              childrenPadding: EdgeInsets.zero,
              children: [
                DiagnosticsSection(experimental: showExperimental),
                SwitchListTile(
                  key: const ValueKey('show-experimental-toggle'),
                  secondary: const Icon(Icons.science_outlined),
                  title: const Text('Show experimental settings'),
                  subtitle: const Text('Force upload and Connection audit.'),
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
