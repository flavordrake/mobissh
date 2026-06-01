// Settings view — dedicated full screen reached from the home bottom-nav (#611).
//
// #611 Part A reshape: Settings used to be an inline ExpansionTile disclosure on
// the profile chooser. It now lives in its own bottom-nav destination. This
// screen HOSTS the existing [SettingsPanel] widget unchanged — the panel owns
// the keep-alive toggle (#512) + font-size slider (#552). The screen is a thin
// container so it can grow (more settings) without touching the panel.

import 'package:flutter/material.dart';

import 'settings_panel.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: SettingsPanel(),
      ),
    );
  }
}
