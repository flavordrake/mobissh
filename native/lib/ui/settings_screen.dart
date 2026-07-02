// Settings view — the single Settings page reached from the home bottom-nav
// (#611, #897, #966).
//
// #897 folded Settings + Diagnostics into ONE page. #966 (Play-Store prep):
// the user-facing settings ([SettingsPanel]) stay top-level and clean for the
// store's first-glance; the developer-facing [DiagnosticsSection] (crash share
// / force-upload / connection audit) moves into a COLLAPSED "Advanced"
// expander so it's present-but-subordinate. Both widgets stay reusable.

import 'package:flutter/material.dart';

import 'diagnostics_section.dart';
import 'settings_panel.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsPanel(),
            const SizedBox(height: 8),
            // #966: Advanced — collapsed by default. Keeps the developer/power
            // diagnostics one tap away without cluttering the main page (or the
            // store screenshots). The in-app Feedback button is the primary
            // report path and is unaffected.
            ExpansionTile(
              key: const ValueKey('settings-advanced-tile'),
              leading: const Icon(Icons.tune_outlined),
              title: const Text('Advanced'),
              childrenPadding: EdgeInsets.zero,
              children: const [DiagnosticsSection()],
            ),
          ],
        ),
      ),
    );
  }
}
