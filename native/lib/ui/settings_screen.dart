// Settings view — the single, flat Settings page reached from the home
// bottom-nav (#611, #897).
//
// #897 reshape: Settings and Diagnostics are now ONE page. The Diagnostics
// bottom-nav tab is gone; this screen renders the flattened [SettingsPanel]
// (all controls top-level, grouped by light subheaders) followed by the
// flattened [DiagnosticsSection] under a divider. Both widgets stay reusable —
// they're just composed here instead of each owning a tab.

import 'package:flutter/material.dart';

import 'diagnostics_section.dart';
import 'settings_panel.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsPanel(),
            SizedBox(height: 8),
            Divider(),
            DiagnosticsSection(),
          ],
        ),
      ),
    );
  }
}
