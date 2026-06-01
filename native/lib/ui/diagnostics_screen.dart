// Diagnostics view — dedicated full screen reached from the home bottom-nav
// (#611).
//
// #611 Part A reshape: Diagnostics used to be an inline ExpansionTile disclosure
// at the bottom of the profile chooser. It now lives in its own bottom-nav
// destination. This screen HOSTS the existing [DiagnosticsSection] widget
// unchanged — the section owns the share-feedback / crash upload buttons, the
// Connection Audit entry, and the #543 connect-log viewer. The screen is a thin
// container so it can grow without touching the section.

import 'package:flutter/material.dart';

import 'diagnostics_section.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: DiagnosticsSection(),
      ),
    );
  }
}
