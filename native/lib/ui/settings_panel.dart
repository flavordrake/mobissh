// Settings section on the Connect form (#512, #552).
//
// Exposes the keep-alive-in-background toggle (#512) and the terminal
// font-size slider (#552). The font size persists via `fontSizeProvider`
// (SharedPreferences) and is applied live to the terminal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/battery_optimization.dart';
import '../state/detection_providers.dart';
import '../state/keepalive_providers.dart';
import '../state/sessions.dart';
import '../state/terminal_backend.dart';
import '../state/tmux_control_mode_setting.dart';
import '../state/ui_prefs_providers.dart';

class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final backend = ref.watch(terminalBackendProvider);
    final controlMode = ref.watch(tmuxControlModeProvider);
    final detection = ref.watch(detectionSettingsProvider);
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
        // #738: explicit battery-optimization exemption affordance. The
        // one-time auto-prompt fires on first connect, but a user who declined
        // (or wants to re-grant) can request it here. Excluding the app from
        // Doze battery optimization is what lets the keep-alive service hold the
        // connection through an ordinary screen-off sleep.
        ListTile(
          key: const ValueKey('battery-opt-tile'),
          leading: const Icon(Icons.battery_saver_outlined),
          title: const Text('Allow background battery use'),
          subtitle: const Text(
            'Exclude MobiSSH from battery optimization so Android keeps SSH '
            'sessions alive while the screen is off. Without this, the system '
            'may freeze the connection during sleep.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _requestBatteryOptExemption(context, ref),
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
        // #913 Part D: tmux control-mode (`tmux -CC`) opt-in. Default OFF — the
        // proven screen-scrape path stays the default; enabling this drives
        // `SshConnectCommand.controlMode` so NEW sessions enter control mode for
        // authoritative window/size + real switch gestures. Read at connect time
        // (restart-to-apply, like the engine selector). Monochrome outlined icon.
        SwitchListTile(
          key: const ValueKey('tmux-control-mode-toggle'),
          secondary: const Icon(Icons.cable_outlined),
          title: const Text('Terminal: tmux control mode (experimental)'),
          subtitle: const Text(
            'Drive tmux via control mode (-CC): authoritative windows/size + '
            'real switch gestures. Requires tmux on the host. Live sessions '
            'reconnect to apply.',
          ),
          value: controlMode,
          onChanged: (v) async {
            // #913: persist + sync the per-isolate global (read at connect time).
            await ref.read(tmuxControlModeProvider.notifier).set(v);
            // #916: the flag is read ONCE at connect — flipping it on a LIVE
            // session does nothing until a reconnect (the owner's "hadn't
            // reconnected after control mode on": gestures fired into a still-
            // scrape session). Trigger a clean reconnect of every connected
            // session so the new mode actually engages, and surface a hint.
            final reconnected = ref
                .read(sessionsProvider.notifier)
                .reconnectForControlModeChange();
            if (reconnected > 0 && context.mounted) {
              final mode = v ? 'control mode' : 'scrape mode';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Reconnecting $reconnected session'
                    '${reconnected == 1 ? '' : 's'} to apply $mode…',
                  ),
                ),
              );
            }
          },
        ),
        // #888 Part A: in-terminal structured-text DETECTION. Master switch +
        // per-type toggles (URLs, file paths). When a type is off, the flterm
        // controller never registers that pattern (no scan, no decoration);
        // changes re-apply LIVE. Detection is a Ghostty-engine affordance —
        // xterm has no structured detection. Monochrome outlined icons only.
        SwitchListTile(
          key: const ValueKey('detection-master-toggle'),
          secondary: const Icon(Icons.search_outlined),
          title: const Text('Detect links & paths in terminal'),
          subtitle: const Text(
            'Find URLs and file paths in terminal output and make them '
            'tappable. Applies to the Ghostty engine.',
          ),
          value: detection.enabled,
          onChanged: (v) =>
              ref.read(detectionSettingsProvider.notifier).setEnabled(v),
        ),
        SwitchListTile(
          key: const ValueKey('detection-url-toggle'),
          secondary: const Icon(Icons.link_outlined),
          title: const Text('URLs'),
          subtitle: const Text('Detect and tap http/https links.'),
          value: detection.url,
          onChanged: detection.enabled
              ? (v) => ref.read(detectionSettingsProvider.notifier).setUrl(v)
              : null,
        ),
        SwitchListTile(
          key: const ValueKey('detection-path-toggle'),
          secondary: const Icon(Icons.folder_outlined),
          title: const Text('File paths'),
          subtitle: const Text('Detect absolute paths and open them in files.'),
          value: detection.path,
          onChanged: detection.enabled
              ? (v) => ref.read(detectionSettingsProvider.notifier).setPath(v)
              : null,
        ),
      ],
    );
  }

  Future<void> _requestBatteryOptExemption(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(batteryOptimizationProvider);
    final result = await controller.requestNow();
    if (messenger == null) return;
    final String message;
    switch (result.outcome) {
      case BatteryOptPromptOutcome.alreadyExempt:
        message = 'Already excluded from battery optimization.';
        break;
      case BatteryOptPromptOutcome.prompted:
        message = result.granted
            ? 'Excluded from battery optimization.'
            : 'Not excluded — sessions may drop during long sleeps.';
        break;
      case BatteryOptPromptOutcome.alreadyAsked:
      case BatteryOptPromptOutcome.unavailable:
        message = 'Battery optimization settings are unavailable here.';
        break;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
