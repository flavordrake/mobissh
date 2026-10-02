// Settings panel — the user-facing Settings page body (#512, #552, #897, #1257).
//
// #1257: five non-collapsing sections (Connections / Terminal / Links & paths /
// Background / About & updates). The per-type detection switches and the
// exceptions list live in the Detection lab; experimental items (tmux control
// mode, Force upload, Connection audit) sit behind Settings → Advanced's
// "Show experimental settings" switch (settings_screen.dart). The page bottom
// holds [SettingsResetButton].

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/battery_optimization.dart';
import '../services/clipboard.dart';
import '../state/detection_providers.dart';
import '../state/detection_style_providers.dart';
import '../state/feature_flags_providers.dart';
import '../state/keepalive_providers.dart';
import '../state/sessions.dart';
import '../state/terminal_backend.dart';
import '../state/tmux_control_mode_setting.dart';
import '../state/ui_prefs_providers.dart';
import 'detection_lab_screen.dart';
import 'feedback_overlay.dart' show VersionResolver, resolveBuildVersion;
import 'keys_screen.dart';
import 'link_browser_picker.dart';
import 'settings_subheader.dart';
import 'top_toast.dart';
import 'update_banner.dart';

class SettingsPanel extends ConsumerWidget {
  /// Injectable so widget tests can supply a fixed build string without a
  /// PackageInfo platform channel. Defaults to [resolveBuildVersion] — the SAME
  /// source of truth the bug-report `version` field uses, so the row shows the
  /// owner the exact build string he'd otherwise only see in an upload.
  const SettingsPanel({super.key, this.versionResolver = resolveBuildVersion});

  final VersionResolver versionResolver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final fontFamily = ref.watch(fontFamilyProvider);
    final detection = ref.watch(detectionSettingsProvider);
    return Column(
      key: const ValueKey('settings-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // #1257: five sections, in the order a user reaches for them.
        const SettingsSubheader('Connections'),
        // #1088: the SSH key library — named, reusable keys managed independently
        // of any profile. Its own route (a manager, not a settings toggle).
        ListTile(
          key: const ValueKey('ssh-keys-tile'),
          leading: const Icon(Icons.vpn_key_outlined),
          title: const Text('SSH keys'),
          subtitle: const Text(
            'Manage named private keys you can attach to profiles.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showKeysScreen(context),
        ),
        const SettingsSubheader('Terminal'),
        ListTile(
          key: const ValueKey('font-size-tile'),
          title: const Text('Text size'),
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
        // The GLOBAL default face a new/un-customized session inherits; a
        // per-session override from the session menu still wins.
        ListTile(
          key: const ValueKey('default-font-tile'),
          leading: const Icon(Icons.font_download_outlined),
          title: const Text('Default font'),
          subtitle: Text(_fontFamilyLabel(fontFamily)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickDefaultFont(context, ref, fontFamily),
        ),
        const SettingsSubheader('Links & paths'),
        // #888 master switch. The per-type switches, colours, My patterns and
        // the exceptions list live in the Detection lab (#1257).
        SwitchListTile(
          key: const ValueKey('detection-master-toggle'),
          secondary: const Icon(Icons.search_outlined),
          title: const Text('Make links and paths tappable'),
          subtitle: const Text(
            'Find URLs, file paths and command lines in terminal output.',
          ),
          value: detection.enabled,
          onChanged: (v) =>
              ref.read(detectionSettingsProvider.notifier).setEnabled(v),
        ),
        // #1197 R6: the GLOBAL default browser for extracted links. A
        // per-profile override wins over it (R8). Hidden entirely when nothing
        // enumerates (A8 — no dead affordance).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: LinkBrowserPicker(
            pickerKey: const ValueKey('settings-link-browser'),
            label: 'Open links in',
            defaultLabel: 'System default',
            value: detection.linkBrowserPackage,
            onChanged: (package) => ref
                .read(detectionSettingsProvider.notifier)
                .setLinkBrowserPackage(package),
          ),
        ),
        ListTile(
          key: const ValueKey('detection-lab-tile'),
          leading: const Icon(Icons.science_outlined),
          title: const Text('Detection lab'),
          subtitle: const Text(
            'Which types to detect, colours, your own patterns and '
            'exceptions.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const DetectionLabScreen(),
            ),
          ),
        ),
        const SettingsSubheader('Background'),
        SwitchListTile(
          key: const ValueKey('keepalive-toggle'),
          title: const Text('Keep sessions alive in background'),
          subtitle: const Text(
            'Show an ongoing notification so Android keeps the SSH '
            'session connected when you swap to another app.',
          ),
          value: keepalive,
          onChanged: (v) => ref.read(keepaliveEnabledProvider.notifier).set(v),
        ),
        // #738: battery-optimization exemption. #1257: only while the app is
        // NOT yet exempt — once granted the row has nothing left to do.
        const _BatteryOptRow(),
        const SettingsSubheader('About & updates'),
        // App-version row: the SAME build string the bug report carries; tap
        // copies it (#897).
        FutureBuilder<String>(
          future: versionResolver(),
          builder: (context, snap) {
            final version = snap.data ?? '…';
            return ListTile(
              key: const ValueKey('app-version-tile'),
              leading: const Icon(Icons.info_outline),
              title: const Text('Version'),
              subtitle: Text(
                version,
                key: const ValueKey('app-version-value'),
              ),
              trailing: const Icon(Icons.copy),
              onTap: snap.hasData
                  ? () => _copyVersion(context, version)
                  : null,
            );
          },
        ),
        // #1216: Installed / Latest / Install. Renders nothing on a build
        // without the updater (Play, desktop — R13).
        const UpdateSettingsSection(),
      ],
    );
  }

  /// The human label for a bundled font-family id, for the default-font row.
  /// Falls back to the raw id for an unknown value (never blank).
  String _fontFamilyLabel(String id) {
    for (final f in terminalFontFamilies) {
      if (f.id == id) return f.label;
    }
    return id;
  }

  /// Bottom-sheet picker for the GLOBAL default terminal font. Lists the bundled
  /// families with the current default checked; tapping one persists it via
  /// [fontFamilyProvider] (new/un-customized sessions then inherit it) and
  /// closes the sheet.
  Future<void> _pickDefaultFont(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in terminalFontFamilies)
                ListTile(
                  key: ValueKey('default-font-option-${f.id}'),
                  title: Text(f.label),
                  trailing: f.id == current
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(f.id),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      await ref.read(fontFamilyProvider.notifier).set(picked);
    }
  }

  Future<void> _copyVersion(BuildContext context, String version) async {
    final ok = await copyToClipboard(version);
    if (!context.mounted) return;
    if (ok) {
      showTopToast(context, 'Copied version');
    }
  }

}

/// #738 battery-optimization exemption row. #1257: renders only while the app
/// is NOT yet exempt (re-checked after a request), so a granted exemption
/// leaves no dead row. Where the concept does not exist the check reports
/// exempt and the row never shows.
class _BatteryOptRow extends ConsumerStatefulWidget {
  const _BatteryOptRow();

  @override
  ConsumerState<_BatteryOptRow> createState() => _BatteryOptRowState();
}

class _BatteryOptRowState extends ConsumerState<_BatteryOptRow> {
  late Future<bool> _exempt = ref.read(batteryOptimizationProvider).isExempt();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _exempt,
      builder: (context, snap) {
        if (snap.data != false) return const SizedBox.shrink();
        return ListTile(
          key: const ValueKey('battery-opt-tile'),
          leading: const Icon(Icons.battery_saver_outlined),
          title: const Text('Allow background battery use'),
          subtitle: const Text(
            'Exclude MobiSSH from battery optimization so Android keeps SSH '
            'sessions alive while the screen is off.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _request,
        );
      },
    );
  }

  Future<void> _request() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(batteryOptimizationProvider);
    final result = await controller.requestNow();
    if (!mounted) return;
    setState(() {
      _exempt = controller.isExempt();
    });
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

/// #913 tmux control-mode (`tmux -CC`) opt-in, default OFF. #1257: an
/// experimental setting, shown in Settings → Advanced only while "Show
/// experimental settings" is on; hiding it never changes its value.
class TmuxControlModeTile extends ConsumerWidget {
  const TmuxControlModeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlMode = ref.watch(tmuxControlModeProvider);
    return SwitchListTile(
      key: const ValueKey('tmux-control-mode-toggle'),
      secondary: const Icon(Icons.cable_outlined),
      title: const Text('tmux control mode'),
      subtitle: const Text(
        'Drive tmux via control mode (-CC): authoritative windows/size + '
        'real switch gestures. Requires tmux on the host. Live sessions '
        'reconnect to apply.',
      ),
      value: controlMode,
      onChanged: (v) async {
        // #913: persist + sync the per-isolate global (read at connect time).
        await ref.read(tmuxControlModeProvider.notifier).set(v);
        // #916: the flag is read ONCE at connect, so reconnect every connected
        // session for the new mode to engage, and say so.
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
    );
  }
}

/// #897 destructive reset, at the very bottom of the Settings page. Confirms,
/// then restores every persisted user pref to its documented default via each
/// provider's own setter (no key wipe, no schema bump), so the UI updates live.
///
/// NOT reset: the battery-optimization exemption (an OS-level setting with no
/// MobiSSH default), saved profiles, credentials and detection exceptions.
class SettingsResetButton extends ConsumerWidget {
  const SettingsResetButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: OutlinedButton.icon(
        key: const ValueKey('settings-reset-button'),
        onPressed: () => _confirmAndReset(context, ref),
        icon: const Icon(Icons.restart_alt),
        style: OutlinedButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        label: const Text('Reset settings'),
      ),
    );
  }

  Future<void> _confirmAndReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('settings-reset-dialog'),
        title: const Text('Reset settings?'),
        content: const Text(
          'Restore all MobiSSH settings — text size, default font, '
          'keep-alive, link/path detection, detection lab tuning, '
          'experimental settings and tmux control mode — to their defaults. '
          'Saved profiles, credentials, and detection exceptions are not '
          'affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('settings-reset-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(fontSizeProvider.notifier).set(fontSizeDefault);
    await ref.read(fontFamilyProvider.notifier).set(fontFamilyDefault);
    await ref.read(terminalBackendProvider.notifier).set(terminalBackendDefault);
    await ref.read(keepaliveEnabledProvider.notifier).set(keepaliveEnabledDefault);
    await ref.read(tmuxControlModeProvider.notifier).set(tmuxControlModeDefault);
    // #1257: the experimental-settings flag resets with the rest.
    await ref.read(featureFlagsProvider.notifier).reset();
    // Detection has no single-shot reset; restore each field to its default
    // (all-true — the documented no-regression default in detection_providers).
    final detectionNotifier = ref.read(detectionSettingsProvider.notifier);
    await detectionNotifier.setEnabled(true);
    await detectionNotifier.setUrl(true);
    await detectionNotifier.setPath(true);
    await detectionNotifier.setCommand(true);
    await detectionNotifier.setRelpath(true);
    // #1154 R9: the link-highlight options reset with the detection fields.
    await detectionNotifier.setIntensity(DetectionIntensity.medium);
    await detectionNotifier.setGutterSide(GutterSide.right);
    await detectionNotifier.setGutterMode(GutterMode.overlay);
    // #1197 R6: the global browser choice is a tuned SETTING → resets with the
    // rest. Per-profile overrides are profile data and survive (same line as
    // saved profiles / detection exceptions below).
    await detectionNotifier.setLinkBrowserPackage(null);
    // #1031 slice 2: lab styles are TUNED settings → reset with the rest.
    // AUTHORED data survives (detection exceptions here; custom pattern
    // definitions in slice 3) — the IA's one-sentence reset rule.
    await ref.read(detectionStylesProvider.notifier).clearAllTuned();

    if (context.mounted) {
      showTopToast(context, 'Settings reset to defaults');
    }
  }
}
